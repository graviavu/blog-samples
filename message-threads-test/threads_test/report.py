"""Summaries, savings table and the two output files. No message ids, request ids or account ids go in."""
import json
import os

from . import stats
from .pricing import prompt_len

ARM_NAMES = {1: "1 No cache (full resend)", 2: "2 Prompt cache (full resend)", 3: "3 Thread + cache", 4: "4 Reload (cold create)"}
MEASURED_KIND = {1: "turn", 2: "turn", 3: "turn", 4: "reload"}
SETUP_KIND = {2: "prime", 3: "create"}
DISCLAIMER = ("One machine, one network, one day. These numbers say how this run behaved, not how the service behaves for "
              "everyone. Cost is an estimated usage value computed from the usage fields and the list prices in DOCS-NOTES.md, not an invoice.")


def _ok(r):
    return r["status"] == 200 and r["complete"]


def arm_rows(records):
    rows = {}
    for arm in (1, 2, 3, 4):
        rs = [r for r in records if r["arm"] == arm and _ok(r) and r["kind"] == MEASURED_KIND[arm]]
        allr = [r for r in records if r["arm"] == arm and _ok(r) and r["kind"] in (MEASURED_KIND[arm], SETUP_KIND.get(arm))]
        if not rs:
            rows[arm] = {"name": ARM_NAMES[arm], "n": 0}
            continue
        tt = [r["ttft_ms"] for r in rs if r["ttft_ms"] is not None]
        med = lambda key: stats.median([r["usage"].get(key, 0) for r in rs])  # noqa: E731
        rows[arm] = {
            "name": ARM_NAMES[arm], "n": len(rs),
            "ttft_ms_median": stats.median(tt), "ttft_ms_p90": stats.percentile(tt, 90),
            "total_ms_median": stats.median([r["total_ms"] for r in rs]),
            "cost_usd_median": stats.median([r["cost"]["total"] for r in rs]),
            "cost_split_median_usd": {k: stats.median([r["cost"][k] for r in rs]) for k in ("input", "cache_write", "cache_read", "output")},
            "tokens_median": {k: med(k) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")},
            "avg_cost_incl_setup_usd": sum(r["cost"]["total"] for r in allr) / len(allr),
            "setup_cost_usd_median": stats.median([r["cost"]["total"] for r in allr if r["kind"] == SETUP_KIND.get(arm)]) if arm in SETUP_KIND else None,
        }
    base = rows.get(1, {})
    for arm, row in rows.items():
        if not row.get("n"):
            continue
        row["ttft_saving_pct"] = stats.saving_pct(base.get("ttft_ms_median"), row["ttft_ms_median"])
        row["cost_saving_pct"] = stats.saving_pct(base.get("cost_usd_median"), row["cost_usd_median"])
        row["avg_cost_incl_setup_saving_pct"] = stats.saving_pct(base.get("avg_cost_incl_setup_usd"), row["avg_cost_incl_setup_usd"])
    return rows


def parity(records, tol=0.03):
    """Do arms 1-3 send the same number of prompt tokens at the same turn? Compared per turn index on medians."""
    by = {}
    for r in records:
        if r["arm"] in (1, 2, 3) and _ok(r) and r["kind"] in ("turn", "prime", "create"):
            by.setdefault(r["turn"], {}).setdefault(r["arm"], []).append(prompt_len(r["usage"]))
    worst = 0.0
    compared = 0
    for turn, arms in by.items():
        meds = {a: stats.median(v) for a, v in arms.items()}
        if len(meds) < 2:
            continue
        compared += 1
        hi, lo = max(meds.values()), min(meds.values())
        if hi:
            worst = max(worst, (hi - lo) / hi)
    return {"turns_compared": compared, "max_relative_difference": worst, "tolerance": tol,
            "matched": (worst <= tol) if compared else None}


def cache_flags(records):
    def n(pred):
        return sum(1 for r in records if _ok(r) and pred(r))
    return {
        "cold_prefix_confirmed": n(lambda r: r["kind"] in ("reload", "reload_after_404", "prime", "create") and r["usage"].get("cache_read_input_tokens", 0) == 0),
        "cold_prefix_not_cold": n(lambda r: r["kind"] in ("reload", "reload_after_404", "prime", "create") and r["usage"].get("cache_read_input_tokens", 0) > 0),
        "warm_turns_with_cache_read": n(lambda r: r["arm"] in (2, 3) and r["kind"] == "turn" and r["usage"].get("cache_read_input_tokens", 0) > 0),
        "warm_turns_without_cache_read": n(lambda r: r["arm"] in (2, 3) and r["kind"] == "turn" and r["usage"].get("cache_read_input_tokens", 0) == 0),
        "replays_in_thread_arm": sum(1 for r in records if r["arm"] == 3 and r["kind"] == "replay"),
        "retries": sum(1 for r in records if r["attempt"] > 1),
        "failed_requests": sum(1 for r in records if not _ok(r) and r["kind"] not in ("bogus_continue", "check_double_continue")),
    }


def summarize(records):
    rows = arm_rows(records)
    a2, a3, a1 = rows.get(2, {}), rows.get(3, {}), rows.get(1, {})
    claim = None
    if a2.get("n") and a3.get("n"):
        claim = {"thread_vs_cached_resend_ttft_ratio": stats.ratio(a3["ttft_ms_median"], a2["ttft_ms_median"]),
                 "thread_ttft_lower_than_cached_resend_pct": stats.saving_pct(a2["ttft_ms_median"], a3["ttft_ms_median"]),
                 "thread_vs_nocache_ttft_ratio": stats.ratio(a3["ttft_ms_median"], a1.get("ttft_ms_median")),
                 "vendor_claim": "about 35% lower median TTFT at 500K to 1M tokens (source not found in the docs page, see DOCS-NOTES.md)"}
    return {"arms": rows, "thread_vs_resend": claim, "token_parity": parity(records), "cache": cache_flags(records)}


def _f(x, nd=0, pre="", suf=""):
    return "n/a" if x is None else "%s%.*f%s" % (pre, nd, x, suf)


def render_md(doc):
    s = doc["summary"]
    c = doc["config"]
    L = ["# Message threads latency test", "", "Status: **%s**. Model `%s`, about %d tokens of history, spent $%.4f (cap $%.2f)." % (
        doc["status"], c["model"], c["tokens"], doc["spent_usd"], c["max_usd"]), "", "> " + DISCLAIMER, "",
         "## Savings versus arm 1 (no cache)", "",
         "| Arm | n | TTFT median ms | TTFT p90 ms | total median ms | cost/turn | cache write tok | cache read tok | TTFT saving | cost saving |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for arm in (1, 2, 3, 4):
        r = s["arms"].get(arm, {})
        if not r.get("n"):
            L.append("| %s | 0 | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |" % ARM_NAMES[arm])
            continue
        t = r["tokens_median"]
        L.append("| %s | %d | %s | %s | %s | %s | %d | %d | %s | %s |" % (
            r["name"], r["n"], _f(r["ttft_ms_median"]), _f(r["ttft_ms_p90"]), _f(r["total_ms_median"]),
            _f(r["cost_usd_median"], 4, "$"), t["cache_creation_input_tokens"], t["cache_read_input_tokens"],
            "baseline" if arm == 1 else _f(r["ttft_saving_pct"], 1, suf="%"),
            "baseline" if arm == 1 else _f(r["cost_saving_pct"], 1, suf="%")))
    L += ["", "p90 is nearest-rank: with fewer than 10 samples it is the maximum. Arms 2 and 3 count follow-up turns only; their first turn "
          "(cache prime / thread create, a cold write) is listed below.", "",
          "| Arm | first-turn cost (median) | average cost per request incl. first turn | saving vs arm 1 on that average |", "|---|---|---|---|"]
    for arm in (1, 2, 3, 4):
        r = s["arms"].get(arm, {})
        if r.get("n"):
            L.append("| %s | %s | %s | %s |" % (r["name"], _f(r.get("setup_cost_usd_median"), 4, "$"), _f(r["avg_cost_incl_setup_usd"], 4, "$"),
                                                "baseline" if arm == 1 else _f(r.get("avg_cost_incl_setup_saving_pct"), 1, suf="%")))
    t = s["thread_vs_resend"]
    L += ["", "## Thread versus resend", ""]
    if t:
        L += ["- Thread TTFT / cached-resend TTFT (median): %s" % _f(t["thread_vs_cached_resend_ttft_ratio"], 2),
              "- Thread median TTFT is %s lower than cached resend. Vendor claim being checked: about 35%% lower at 500K to 1M tokens." % _f(t["thread_ttft_lower_than_cached_resend_pct"], 1, suf="%"),
              "- Thread TTFT / no-cache TTFT (median): %s" % _f(t["thread_vs_nocache_ttft_ratio"], 2)]
    else:
        L.append("- Not enough data from arms 2 and 3.")
    p = s["token_parity"]
    k = s["cache"]
    L += ["", "## Did the arms send the same tokens?", "",
          "- Prompt tokens matched across arms at the same turn: **%s** (largest relative difference %.2f%% over %d turn indexes, tolerance %.0f%%). Differences come from the model's own replies."
          % ({True: "yes", False: "NO", None: "n/a"}[p["matched"]], p["max_relative_difference"] * 100, p["turns_compared"], p["tolerance"] * 100),
          "- Cold prefix confirmed (cache read 0) on %d first/reload turns; %d were not cold." % (k["cold_prefix_confirmed"], k["cold_prefix_not_cold"]),
          "- Follow-up turns with a cache read: %d; without: %d. Replays in the thread arm: %d. Retries: %d. Failed requests (not counting the two expected check errors): %d." % (
              k["warm_turns_with_cache_read"], k["warm_turns_without_cache_read"], k["replays_in_thread_arm"], k["retries"], k["failed_requests"]),
          "", "## Behaviour checks", ""]
    for name, ch in doc["checks"].items():
        L.append("- **%s**: %s" % (name, ch.get("result", "not run")))
        for key in ("detail", "status", "error_code", "body"):
            if ch.get(key) is not None:
                L.append("  - %s: `%s`" % (key, json.dumps(ch[key])[:600] if not isinstance(ch[key], str) else ch[key][:600]))
    L += ["", "## Reading this", "",
          "- TTFT includes connection setup and the request upload (a fresh connection per request, the same for every arm). Arm 1 has few samples, so its p90 is its maximum.",
          "- Thinking blocks are left out of the history the resend arms send. A thread may keep the thinking blocks of its own earlier turns. Read the token-usage comparison above before you trust a TTFT difference. `effort: low` is on to keep thinking short in every arm.",
          "- Spend is the sum of the usage fields; the request on the wire at an interrupt is not in it (see in_flight_worst_case_usd in results.json)."]
    if doc.get("notes"):
        L += ["", "## Notes", ""] + ["- " + n for n in doc["notes"]]
    return "\n".join(L) + "\n"


def private_dir(path):
    """Create a results directory readable by the owner only (0700)."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)


def _private_write(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        os.fchmod(f.fileno(), 0o600)
        f.write(text)


def write_outputs(outdir, doc):
    """Atomic write so an interrupt never leaves a half file; temp files are removed."""
    tmps = []
    try:
        for name, text in (("results.json", json.dumps(doc, indent=2, sort_keys=True) + "\n"), ("results.md", render_md(doc))):
            tmp = os.path.join(outdir, name + ".tmp")
            tmps.append(tmp)
            _private_write(tmp, text)
            os.replace(tmp, os.path.join(outdir, name))
    finally:
        for t in tmps:
            if os.path.exists(t):
                os.remove(t)


def render_sizes_md(entries, cfg, status, spent):
    """entries: [(tokens, status, summary)] one per history size, in run order. Latency versus context size."""
    L = ["# Message threads: latency versus context size", "",
         "Status: **%s**. Model `%s`, spent $%.4f (cap $%.2f)." % (status, cfg["model"], spent, cfg["max_usd"]), "", "> " + DISCLAIMER, "",
         "| History tokens | Arm | n | TTFT median ms | TTFT p90 ms | cost/turn | TTFT saving vs arm 1 |", "|---|---|---|---|---|---|---|"]
    for tokens, st, summ in entries:
        for arm in (1, 2, 3, 4):
            r = summ["arms"].get(arm, {})
            if not r.get("n"):
                L.append("| %d | %s | 0 | n/a | n/a | n/a | n/a |" % (tokens, ARM_NAMES[arm]))
                continue
            L.append("| %d | %s | %d | %s | %s | %s | %s |" % (tokens, r["name"], r["n"], _f(r["ttft_ms_median"]), _f(r["ttft_ms_p90"]),
                                                              _f(r["cost_usd_median"], 4, "$"), "baseline" if arm == 1 else _f(r["ttft_saving_pct"], 1, suf="%")))
    L += ["", "| History tokens | run status | thread TTFT / cached-resend TTFT |", "|---|---|---|"]
    for tokens, st, summ in entries:
        t = summ.get("thread_vs_resend")
        L.append("| %d | %s | %s |" % (tokens, st, _f(t and t["thread_vs_cached_resend_ttft_ratio"], 2)))
    L += ["", "Per-size detail (checks, token parity, cache flags) is in each size's folder: `<tokens>/results.md`. "
          "With few samples per cell a gap of a few points is noise; the vendor figure (about 35% lower median TTFT at 500K to 1M tokens) "
          "is for sizes this default plan does not reach."]
    return "\n".join(L) + "\n"


def write_text(outdir, name, text):
    tmp = os.path.join(outdir, name + ".tmp")
    try:
        _private_write(tmp, text)
        os.replace(tmp, os.path.join(outdir, name))
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
