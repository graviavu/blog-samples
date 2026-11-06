"""Prices (USD per million tokens), cost from usage, and the per-request upper bound.

Defaults are the Anthropic list prices read on 2026-11-05 (see DOCS-NOTES.md). Bedrock's own prices are UNKNOWN to this
sample: override them with --prices FILE and/or --price-multiplier (for example 1.1 for a regional endpoint).
"""
import json
import math

FIELDS = ("input", "output", "cache_write", "cache_read")


def _t(upto, i, o, w, r):
    return {"up_to_prompt_tokens": upto, "input": i, "output": o, "cache_write": w, "cache_read": r}


DEFAULT_PRICES = {
    "haiku-5-5": [_t(100000, 0.10, 0.50, 0.125, 0.01), _t(None, 0.50, 2.50, 0.625, 0.05)],
    "sonnet-5-5": [_t(None, 2.00, 10.00, 2.50, 0.10)],
    "opus-5-5": [_t(None, 4.00, 20.00, 5.00, 0.20)],
    "fable-5-1": [_t(None, 10.00, 50.00, 12.50, 0.25)],
}


def model_key(model):
    """'anthropic.claude-sonnet-5-5' / 'claude-sonnet-5-5' / 'sonnet-5-5' -> 'sonnet-5-5'."""
    k = model.split(".", 1)[1] if model.startswith("anthropic.") else model
    return k[len("claude-"):] if k.startswith("claude-") else k


def model_id(name):
    """Short names get the Bedrock provider prefix; anything with a dot is used as given."""
    if "." in name:
        return name
    return "anthropic.%s" % (name if name.startswith("claude-") else "claude-" + name)


def load_overrides(path):
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("prices file: top level must be an object of model -> list of tiers")
    out = {}
    for k, tiers in data.items():
        if not isinstance(tiers, list) or not tiers:
            raise ValueError("prices file: %s must be a non-empty list of tiers" % k)
        norm = []
        for t in tiers:
            for f_ in FIELDS:
                v = t.get(f_)
                if not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v) or v < 0:
                    raise ValueError("prices file: %s.%s must be a number >= 0" % (k, f_))
            up = t.get("up_to_prompt_tokens")
            if up is not None and (not isinstance(up, int) or up <= 0):
                raise ValueError("prices file: %s up_to_prompt_tokens must be a positive integer or null" % k)
            norm.append(_t(up, t["input"], t["output"], t["cache_write"], t["cache_read"]))
        norm.sort(key=lambda t: math.inf if t["up_to_prompt_tokens"] is None else t["up_to_prompt_tokens"])
        if norm[-1]["up_to_prompt_tokens"] is not None:
            raise ValueError("prices file: %s needs a last tier with up_to_prompt_tokens null" % k)
        out[model_key(k)] = norm
    return out


class Prices:
    def __init__(self, overrides=None, multiplier=1.0):
        self.table = dict(DEFAULT_PRICES)
        self.table.update(overrides or {})
        self.multiplier = multiplier

    def tier(self, model, prompt_tokens):
        k = model_key(model)
        if k not in self.table:
            raise ValueError("no price for model %r: add it with --prices FILE (known: %s)" % (model, ", ".join(sorted(self.table))))
        for t in self.table[k]:
            if t["up_to_prompt_tokens"] is None or prompt_tokens <= t["up_to_prompt_tokens"]:
                return t
        return self.table[k][-1]

    def cost(self, model, usage):
        inp = usage.get("input_tokens", 0) or 0
        cw = usage.get("cache_creation_input_tokens", 0) or 0
        cr = usage.get("cache_read_input_tokens", 0) or 0
        out = usage.get("output_tokens", 0) or 0
        t = self.tier(model, inp + cw + cr)
        usd = (inp * t["input"] + cw * t["cache_write"] + cr * t["cache_read"] + out * t["output"]) / 1e6
        return usd * self.multiplier

    def bound(self, model, prompt_tokens_ub, max_out):
        """Dearest possible request: every prompt token at the dearer of input and cache-write price, output at the cap."""
        t = self.tier(model, prompt_tokens_ub)
        usd = (prompt_tokens_ub * max(t["input"], t["cache_write"]) + max_out * t["output"]) / 1e6
        return usd * self.multiplier
