"""The plan: request counts per arm and the cost bound. Used by the dry run and by the real run (same numbers)."""
from . import fill

ARMS = ("A", "B", "C")
ARM_NAMES = {"A": "full resend, no cache", "B": "full resend + prompt cache", "C": "thread + prompt cache"}
CAL_TOKENS = 4000
PROBE_REQUESTS = 4          # baseline (+1 if the effort fallback is needed), create, continue
PROBE_PROMPT_UB = 400
PROBE_MAX_TOKENS = 64


def growth(max_tokens):
    """Per-turn growth of a conversation: the question, the reply (up to the cap) and framing."""
    return fill.QUESTION_TOKENS + max_tokens + 60


def request_ub(size, margin, max_tokens, turn):
    return int(size * margin) + turn * growth(max_tokens)


def counts(reps, thread_arm=True):
    return {"A": reps, "B": 1 + reps, "C": (1 + reps) if thread_arm else 0}


def build(cfg, prices):
    """cfg: models (ids), sizes, reps, max_tokens, margin, probe_model, thread_arm."""
    cells, total = [], 0.0
    n_req = 0
    for m in cfg["models"]:
        for size in cfg["sizes"]:
            per_arm = {}
            for arm in ARMS:
                cnt = counts(cfg["reps"], cfg["thread_arm"])[arm]
                b = sum(prices.bound(m, request_ub(size, cfg["margin"], cfg["max_tokens"], k), cfg["max_tokens"]) for k in range(1, cnt + 1))
                per_arm[arm] = {"requests": cnt, "bound_usd": b}
                total += b
                n_req += cnt
            cells.append({"model": m, "size": size, "arms": per_arm})
    cal = sum(prices.bound(m, int(CAL_TOKENS * cfg["margin"]) + 100, 8) for m in cfg["models"])
    probe = PROBE_REQUESTS * prices.bound(cfg["probe_model"], PROBE_PROMPT_UB, PROBE_MAX_TOKENS)
    return {"cells": cells, "arms_bound": total, "calibration_bound": cal, "probe_bound": probe,
            "total": total + cal + probe, "requests": n_req + len(cfg["models"]) + PROBE_REQUESTS}


def typical(cfg, prices):
    """Informational only: cache hits credited, replies of 20 tokens. Not a bound."""
    tot = 0.0
    g = growth(cfg["max_tokens"])
    for m in cfg["models"]:
        for size in cfg["sizes"]:
            for k in range(1, cfg["reps"] + 1):
                tot += prices.cost(m, {"input_tokens": size + k * g, "output_tokens": 20})
            for arm in ("B", "C") if cfg["thread_arm"] else ("B",):
                tot += prices.cost(m, {"cache_creation_input_tokens": size + g, "output_tokens": 20})
                for k in range(2, cfg["reps"] + 2):
                    tot += prices.cost(m, {"cache_read_input_tokens": size + (k - 1) * g, "input_tokens": g, "output_tokens": 20})
    return tot
