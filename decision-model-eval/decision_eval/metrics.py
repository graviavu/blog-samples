"""Metrics. Pure functions over plain lists/dicts, stdlib only. Small n: read the caveats in the README."""
import statistics
from collections import Counter


def median(xs):
    return round(statistics.median(xs), 1) if xs else None


def p95(xs):
    """Nearest-rank on the sorted list. With n < 20 this is just close to the maximum."""
    if not xs:
        return None
    s = sorted(xs)
    return round(s[int(round(0.95 * (len(s) - 1)))], 1)


def ratio(a, b):
    return round(a / b, 3) if b else None


def ece(pairs, bins=5):
    """Expected calibration error. pairs = [(confidence, correct 0/1)]. Equal-width bins.
    With n=20 and 5 bins most bins hold 0-6 items, so this is a rough indicator, not a measurement."""
    if not pairs:
        return None
    e = 0.0
    for b in range(bins):
        s = [(c, o) for c, o in pairs if min(int(c * bins), bins - 1) == b]
        if s:
            e += len(s) / len(pairs) * abs(sum(o for _, o in s) / len(s) - sum(c for c, _ in s) / len(s))
    return round(e, 3)


def agreement(a, b):
    """a, b: {key: pick}. Share of common keys with the same pick, and how many keys were compared."""
    keys = [k for k in a if k in b and a[k] and b[k]]
    return {"n": len(keys), "agreement": ratio(sum(a[k] == b[k] for k in keys), len(keys))}


def triage_metrics(items, expected, positive="urgent"):
    """items: [{file, pick, confidence, latency_ms, error, injection_flag, schema_ok}]; expected: {file: (label, injection)}"""
    done = [i for i in items if i["file"] in expected]
    ok = [i for i in done if not i.get("error")]
    right = [i for i in ok if i["pick"] == expected[i["file"]][0]]
    pos = [i for i in ok if expected[i["file"]][0] == positive]
    inj = [i for i in ok if expected[i["file"]][1]]
    conf = [(i["confidence"], int(i["pick"] == expected[i["file"]][0])) for i in ok if i.get("confidence") is not None]
    lat = [i["latency_ms"] for i in ok]
    return {
        "n_items": len(done), "n_answered": len(ok), "errors": len(done) - len(ok),
        "accuracy": ratio(len(right), len(ok)),
        "urgent_recall": {"hit": sum(i["pick"] == positive for i in pos), "of": len(pos)},
        "injection_correct": {"hit": sum(i["pick"] == expected[i["file"]][0] for i in inj), "of": len(inj)},
        "urgent_buried_as_ignore": [i["file"] for i in ok if expected[i["file"]][0] == positive and i["pick"] == "ignore"],
        "ignore_promoted_to_urgent": [i["file"] for i in ok if expected[i["file"]][0] == "ignore" and i["pick"] == positive],
        "wrong": [(i["file"], expected[i["file"]][0], i["pick"]) for i in ok if i not in right],
        "schema_valid_rate": ratio(sum(bool(i.get("schema_ok")) for i in ok), len(ok)),
        "ece_5bins": ece(conf), "ece_n": len(conf),
        "mean_confidence": round(sum(c for c, _ in conf) / len(conf), 3) if conf else None,
        "latency_ms_median": median(lat), "latency_ms_p95": p95(lat),
    }


def routing_metrics(items, orders=("orig", "rev", "rot")):
    """items: [{row, chosen, wording, order, pick, confidence, latency_ms, error, schema_ok}].
    Reference label = the model tier that was actually chosen for the row (a proxy, not ground truth)."""
    ok = [i for i in items if not i.get("error")]
    by = {}
    for i in ok:
        by.setdefault(i["row"], {})[(i["wording"], i["order"])] = i
    direct = {r: v for r, v in by.items() if ("direct", "orig") in v}
    chosen = {r: v[("direct", "orig")]["chosen"] for r, v in direct.items()}
    out = {"n_calls": len(items), "n_answered": len(ok), "errors": len(items) - len(ok), "rows_scored": len(direct),
           "schema_valid_rate": ratio(sum(bool(i.get("schema_ok")) for i in ok), len(ok))}
    if chosen:
        base = Counter(chosen.values()).most_common(1)[0]
        out["baseline_always_" + base[0]] = ratio(base[1], len(chosen))
        out["agreement_with_chosen_direct_orig"] = ratio(sum(v[("direct", "orig")]["pick"] == chosen[r] for r, v in direct.items()), len(direct))
    # option-order stability: same pick under every order, among rows that have all orders for a wording
    for w in ("direct", "reversed"):
        full = [v for v in by.values() if all((w, o) in v for o in orders)]
        out[f"option_order_stability_{w}"] = {
            "rows": len(full),
            "stable": ratio(sum(len({v[(w, o)]["pick"] for o in orders}) == 1 for v in full), len(full)),
            "agreement_with_chosen_by_order": {o: ratio(sum(v[(w, o)]["pick"] == v[(w, o)]["chosen"] for v in full), len(full))
                                               for o in orders} if w == "direct" else None}
    # negation / reversal: "least suitable" should NOT give the same answer as "cheapest that would do"
    both = [v for v in by.values() if ("direct", "orig") in v and ("reversed", "orig") in v]
    out["reversal_contradiction"] = {"rows": len(both),
                                     "rate": ratio(sum(v[("reversed", "orig")]["pick"] == v[("direct", "orig")]["pick"] for v in both), len(both)),
                                     "note": "share of rows where the reversed question got the same answer as the direct one (lower is better)"}
    conf = [(i["confidence"], int(i["pick"] == i["chosen"])) for i in ok
            if i.get("confidence") is not None and (i["wording"], i["order"]) == ("direct", "orig")]
    out["ece_5bins"], out["ece_n"] = ece(conf), len(conf)
    lat = [i["latency_ms"] for i in ok]
    out["latency_ms_median"], out["latency_ms_p95"] = median(lat), p95(lat)
    return out
