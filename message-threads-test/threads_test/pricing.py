"""Prices from DOCS-NOTES.md (USD per million tokens). Read the pricing page again before you rely on them."""
import math

# model -> tiers of (max prompt tokens or None, input, output, 5m cache write, cache read)
PRICES = {
    "claude-haiku-5-5": [(100000, 0.10, 0.50, 0.125, 0.01), (None, 0.50, 2.50, 0.625, 0.05)],
    "claude-sonnet-5-5": [(None, 2.00, 10.00, 2.50, 0.10)],
    "claude-opus-5-5": [(None, 4.00, 20.00, 5.00, 0.20)],
    "claude-fable-5-1": [(None, 10.00, 50.00, 12.50, 0.25)],
}
USAGE_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def tier(model, prompt_tokens):
    if model not in PRICES:
        raise ValueError("no price for model %r; known: %s" % (model, ", ".join(sorted(PRICES))))
    for limit, *rest in PRICES[model]:
        if limit is None or prompt_tokens <= limit:
            return tuple(rest)
    raise AssertionError("unreachable")


def prompt_len(usage):
    return (usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0))


def cost(model, usage):
    """Dollar cost of one request from its usage, split into parts."""
    p_in, p_out, p_w, p_r = tier(model, prompt_len(usage))
    parts = {
        "input": usage.get("input_tokens", 0) * p_in / 1e6,
        "cache_write": usage.get("cache_creation_input_tokens", 0) * p_w / 1e6,
        "cache_read": usage.get("cache_read_input_tokens", 0) * p_r / 1e6,
        "output": usage.get("output_tokens", 0) * p_out / 1e6,
    }
    parts["total"] = sum(parts.values())
    return parts


def request_upper_bound(model, prompt_tokens_ub, max_tokens):
    """Conservative dollar bound for one request: every prompt token at the dearer of input and cache-write
    price (no cache-read credit), every output token up to max_tokens."""
    p_in, p_out, p_w, _ = tier(model, prompt_tokens_ub)
    return prompt_tokens_ub * max(p_in, p_w) / 1e6 + max_tokens * p_out / 1e6


def plan_counts(a):
    """Request counts for the plan. a: dict with turns, reps, nocache_turns, nocache_reps, reload_reps, expiry_test,
    optional checks (default True) and retries (default 1)."""
    c = {
        "arm1": a["nocache_reps"] * a["nocache_turns"],
        "arm2": a["reps"] * (1 + a["turns"]),
        "arm3": a["reps"] * (1 + a["turns"]),
        "arm4": a["reload_reps"],
        "checks": 2 if a.get("checks", True) else 0,  # cold replay create after the 404, then one continue
        "small": 2 if a.get("expiry_test") else 0,
        "replays": a["reps"] * a["turns"],            # worst case: every arm 3 continue falls back to a full create
        "retries": a.get("retries", 1),
    }
    c["sized"] = c["arm1"] + c["arm2"] + c["arm3"] + c["arm4"] + c["checks"]
    c["sized_with_replays"] = c["sized"] + c["replays"]
    c["attempts"] = c["sized_with_replays"] * (1 + c["retries"])   # worst case: every request is attempted 1 + retries times
    return c


def prompt_upper_bound(tokens, margin, turns, max_tokens):
    return int(math.ceil(tokens * margin)) + 1000 + turns * (max_tokens + 200)


def estimate(model, a):
    """Planned upper bound in USD: every planned request, plus one replay per arm 3 continue, each attempted
    1 + retries times, each at the per-request bound (no cache-read credit)."""
    c = plan_counts(a)
    grow_turns = max(a["turns"], a["nocache_turns"])
    ub = prompt_upper_bound(a["tokens"], a["margin"], grow_turns, a["max_tokens"])
    per = request_upper_bound(model, ub, a["max_tokens"])
    small_ub = prompt_upper_bound(a.get("small_tokens", 2000), a["margin"], 1, a["max_tokens"])
    small = c["small"] * (1 + c["retries"]) * request_upper_bound(model, small_ub, a["max_tokens"])
    return {"total": c["attempts"] * per + small, "counts": c, "prompt_tokens_ub": ub, "per_request_ub": per}


def estimate_sizes(model, a, sizes):
    """Planned upper bound over several history sizes. The behaviour checks and the expiry test run once, at the first size.
    Returns {"total", "per_size": [(tokens, estimate)]}."""
    per, total = [], 0.0
    for i, t in enumerate(sizes):
        ai = dict(a, tokens=t, checks=bool(a.get("checks", True)) and i == 0, expiry_test=bool(a.get("expiry_test")) and i == 0)
        e = estimate(model, ai)
        per.append((t, e))
        total += e["total"]
    return {"total": total, "per_size": per}


def typical(model, a, sizes, new_tokens=300, out_tokens=150):
    """MODELLED typical cost, not a bound: the cache works as documented, the prompt is the size asked for plus 1,500 tokens
    of system and tools, each follow-up adds new_tokens, each reply is out_tokens long, nothing is retried or replayed."""
    total = 0.0
    for i, t in enumerate(sizes):
        p = t + 1500
        p_in, p_out, p_w, p_r = tier(model, p)
        o = out_tokens * p_out / 1e6
        full_in = p * p_in / 1e6 + o
        cold = p * p_w / 1e6 + o
        warm = p * p_r / 1e6 + new_tokens * p_w / 1e6 + o
        total += a["nocache_reps"] * a["nocache_turns"] * full_in
        total += 2 * a["reps"] * (cold + a["turns"] * warm)       # arms 2 and 3
        total += a["reload_reps"] * cold                          # arm 4
        if i == 0 and a.get("checks", True):
            total += cold + warm                                  # replay after the 404, one continue
    return total
