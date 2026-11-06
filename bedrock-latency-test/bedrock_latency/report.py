"""results.json and results.md. No token, no account id, no request or message ids. Written atomically; temp files removed."""
import json
import os
import time

from . import plan, stats
from . import redact as R


def summarize(records, cells):
    """One row per (model, size, arm). Measured = kind 'turn'. The priming request (kind 'prime') is reported apart."""
    rows = []
    for c in cells:
        sel = [r for r in records if r.get("model") == c["model"] and r.get("size_target") == c["size_target"] and r.get("arm") == c["arm"]]
        turns = [r for r in sel if r["kind"] == "turn"]
        ok = [r for r in turns if r["ok"] and r["ttft_s"] is not None]
        prime = [r for r in sel if r["kind"] == "prime" and r["ok"]]
        reads = sum(r["usage"].get("cache_read_input_tokens", 0) for r in ok)
        writes = sum(r["usage"].get("cache_creation_input_tokens", 0) for r in sel if r["ok"])
        rows.append({
            "model": c["model"], "size_target": c["size_target"], "arm": c["arm"], "real_prompt_tokens": c["real_prompt_tokens"],
            "measured": len(turns), "ok": len(ok), "replays": sum(1 for r in sel if r["kind"] == "replay"),
            "ttft_median_s": stats.median([r["ttft_s"] for r in ok]), "ttft_p90_s": stats.percentile([r["ttft_s"] for r in ok], 90),
            "total_median_s": stats.median([r["total_s"] for r in ok]), "total_p90_s": stats.percentile([r["total_s"] for r in ok], 90),
            "prime_ttft_s": prime[0]["ttft_s"] if prime else None, "prime_total_s": prime[0]["total_s"] if prime else None,
            "cache_read_tokens_measured": reads, "cache_write_tokens": writes,
            "cost_usd": round(sum(r["cost_usd"] for r in sel), 6),
            "cost_per_measured_request_usd": (sum(r["cost_usd"] for r in ok) / len(ok)) if ok else None,
            "first_token_kinds": sorted({r["first_token_kind"] for r in ok if r.get("first_token_kind")}),
        })
    base = {(r["model"], r["size_target"]): r for r in rows if r["arm"] == "A"}
    for r in rows:
        a = base.get((r["model"], r["size_target"]))
        r["ttft_saving_vs_A_pct"] = stats.saving_pct(a["ttft_median_s"], r["ttft_median_s"]) if a and r["arm"] != "A" else None
        r["total_saving_vs_A_pct"] = stats.saving_pct(a["total_median_s"], r["total_median_s"]) if a and r["arm"] != "A" else None
    return rows


def _f(x, nd=2):
    return "-" if x is None else ("%.*f" % (nd, x))


def _pct(x):
    return "-" if x is None else "%+.0f%%" % (-x)   # negative = lower than A, shown as a change


def markdown(doc):
    c = doc["config"]
    L = ["# Bedrock latency test results", "",
         "Status: **%s**%s. Run %s UTC. Spent (estimated usage value, not an invoice): $%.4f of a $%.2f cap." % (
             doc["status"], (" (%s)" % doc["why"]) if doc.get("why") else "", doc["started_utc"], doc["spent_usd"], c["max_usd"]),
         "", "Endpoint host `%s`, region `%s`, auth header `%s`. Models: %s. Price multiplier %g." % (
             c["endpoint_host"], c["region"], c["auth_header"], ", ".join(c["models"]), c["price_multiplier"]), ""]
    p = doc.get("probe")
    if p:
        L += ["## Thread probe", "", "**Verdict: %s.** %s" % (p["verdict"], p["reason"]), "",
              "| Step | HTTP status | error type | error code | message |", "|---|---|---|---|---|"]
        for step in ("baseline", "create", "continue"):
            s = p.get(step)
            if not s:
                continue
            e = s.get("error") or {}
            L.append("| %s | %s | %s | %s | %s |" % (step, s.get("http_status"), e.get("error_type") or "-", e.get("error_code") or e.get("amzn_error_type") or "-",
                                                      (e.get("message") or s.get("exception") or "-").replace("|", "/")))
        L.append("")
    rows = doc["summary"]
    if rows:
        L += ["## Latency (seconds) and cost", "",
              "TTFT is the time from sending the request to the first content token of the stream. Median and p90 are nearest-rank over the "
              "measured turns; with fewer than 10 samples p90 is the maximum. Change is against arm A at the same model and size "
              "(negative is faster). Arms B and C show their cache-priming request apart.", "",
              "| Model | Size target | Prompt tokens (real) | Arm | OK/measured | TTFT median | TTFT p90 | Total median | Total p90 | TTFT vs A | Total vs A | Priming TTFT | Cost/turn USD | Arm cost USD |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for r in rows:
            L.append("| %s | %d | %s | %s | %d/%d | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                r["model"], r["size_target"], r["real_prompt_tokens"] if r["real_prompt_tokens"] is not None else "-", r["arm"],
                r["ok"], r["measured"], _f(r["ttft_median_s"]), _f(r["ttft_p90_s"]), _f(r["total_median_s"]), _f(r["total_p90_s"]),
                _pct(r["ttft_saving_vs_A_pct"]), _pct(r["total_saving_vs_A_pct"]), _f(r["prime_ttft_s"]),
                _f(r["cost_per_measured_request_usd"], 4), _f(r["cost_usd"], 4)))
        L += ["", "Arms: " + "; ".join("%s = %s" % (k, v) for k, v in plan.ARM_NAMES.items()) + ".", ""]
        notes = []
        for r in rows:
            if r["arm"] in ("B", "C") and r["ok"] and r["cache_read_tokens_measured"] == 0:
                notes.append("%s at %d, arm %s: no cache-read tokens appeared in the usage of the measured turns. Either caching did not take effect or the usage fields do not report it." % (r["model"], r["size_target"], r["arm"]))
            if r["replays"]:
                notes.append("%s at %d, arm C: %d thread continue(s) failed and were replayed with a full create." % (r["model"], r["size_target"], r["replays"]))
            if "thinking_delta" in r["first_token_kinds"]:
                notes.append("%s at %d, arm %s: some TTFT values are the first thinking token, not the first text token." % (r["model"], r["size_target"], r["arm"]))
        if notes:
            L += ["## Notes", ""] + ["- " + n for n in notes] + [""]
    L += ["## Limits", "",
          "- One machine, one network, one run. With 3 samples per cell, p90 is the slowest sample. Run it again on another day before quoting a number.",
          "- Prices are the configured table (see results.json config), not a Bedrock invoice.", ""]
    return "\n".join(L)


def write(outdir, runner, elapsed):
    cfg = runner.cfg
    doc = {"status": runner.status, "why": R.redact(runner.why) if runner.why else None, "started_utc": cfg["started_utc"],
           "elapsed_s": round(elapsed, 1), "spent_usd": round(runner.spent, 6), "requests_sent": runner.requests,
           "config": cfg["public"], "probe": runner.probe, "cells": runner.cells,
           "summary": summarize(runner.records, runner.cells), "requests": runner.records}
    doc = R.redact_obj(doc)
    os.makedirs(outdir, exist_ok=True)
    tmps = []
    try:
        for name, content in (("results.json", json.dumps(doc, indent=2, sort_keys=True) + "\n"), ("results.md", markdown(doc))):
            tmp = os.path.join(outdir, "." + name + ".tmp")
            tmps.append(tmp)
            with open(tmp, "w") as f:
                f.write(R.redact(content))
            os.replace(tmp, os.path.join(outdir, name))
    finally:
        for t in tmps:
            if os.path.exists(t):
                os.remove(t)
    return doc
