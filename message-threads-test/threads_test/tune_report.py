"""Analysis and Markdown for --tune. Pure functions of the saved records, so a PARTIAL file renders too. No message ids, request ids or
account ids are ever in the records, so none are in the output."""
from . import stats
from .pricing import prompt_len
from .report import DISCLAIMER, _f

IDLE_LIMIT_NOTE = "documented limit: 5 minutes idle"


def _ok(r):
    return bool(r) and r["status"] == 200 and r["complete"]


def last(records, exp, label):
    rs = [r for r in records if r["exp"] == exp and r["label"] == label]
    return rs[-1] if rs else None


def brief(r):
    if not r:
        return None
    u = r["usage"]
    return {"status": r["status"], "ok": _ok(r), "error_code": r.get("error_code"),
            "ttft_ms": None if r["ttft_ms"] is None else round(r["ttft_ms"], 1),
            "total_ms": None if r["total_ms"] is None else round(r["total_ms"], 1),
            "prompt_tokens": prompt_len(u), "input_tokens": u["input_tokens"], "cache_read_tokens": u["cache_read_input_tokens"],
            "cache_creation_tokens": u["cache_creation_input_tokens"], "cache_creation_1h_reported": r.get("cache_creation_1h_reported"),
            "output_tokens": u["output_tokens"], "cost_usd": round(r["cost"]["total"], 6), "charged_usd": round(r["charged_usd"], 6),
            "attempts": r["attempt"], "t_start_s": r["t_start_s"], "t_end_s": r["t_end_s"]}


def cache_verdict(prime, replay):
    """Did the replay read the 1-hour cache? prime, replay: brief() dicts or None."""
    if not replay or not replay["ok"]:
        return "UNKNOWN: the replay request did not complete, so there is no usage to read."
    if not prime or not prime["ok"]:
        return "UNKNOWN: the priming request did not complete, so it is not known that a 1-hour entry was written."
    wrote = prime["cache_creation_tokens"]
    if wrote <= 0:
        return "UNKNOWN: the priming request reported no cache write (cache_creation_input_tokens 0), so there was nothing to read."
    r, p = replay["cache_read_tokens"], replay["prompt_tokens"]
    split = prime["cache_creation_1h_reported"]
    tail = "" if split is not None else " The response reported no ephemeral_1h split, so it is UNKNOWN whether the entry was written with the 1-hour lifetime."
    if r >= 0.9 * wrote:
        return "YES: the replay read %d of its %d prompt tokens from the cache (%.0f%%); the priming request wrote %d.%s" % (r, p, 100.0 * r / max(p, 1), wrote, tail)
    if r == 0:
        return "NO: the replay read 0 tokens from the cache and wrote %d again; the priming request had written %d.%s" % (replay["cache_creation_tokens"], wrote, tail)
    return "PARTLY: the replay read %d of its %d prompt tokens (%.0f%%); the priming request wrote %d. Reason UNKNOWN.%s" % (r, p, 100.0 * r / max(p, 1), wrote, tail)


def expiry_verdict(create, check):
    if not create or not create["ok"]:
        return "UNKNOWN: the thread create did not complete."
    if not check:
        return "UNKNOWN: the continue check was not reached."
    idle = check["t_start_s"] - create["t_end_s"]
    if check["status"] == 404 and check["error_code"] == "thread_not_found":
        return "EXPIRED (verified): a continue after %.0f s idle returned 404 thread_not_found." % idle
    if check["ok"]:
        return "NOT EXPIRED: the continue after %.0f s idle returned 200 (expiry is best effort). The replay below was not sent to a gone thread." % idle
    return "UNKNOWN: the continue after %.0f s idle returned status %s code %s." % (idle, check["status"], check["error_code"])


def keepalive_verdict(create, ka, real, idle_limit):
    if not create or not create["ok"]:
        return "UNKNOWN: the thread create did not complete."
    if not ka:
        return "UNKNOWN: the keep-alive was not reached."
    if not ka["ok"]:
        if ka["status"] == 404:
            return "UNKNOWN: the keep-alive itself got 404 %s %.0f s after the create, so the thread was already gone and nothing is learned about a reset." % (ka["error_code"], ka["t_start_s"] - create["t_end_s"])
        return "UNKNOWN: the keep-alive failed with status %s code %s." % (ka["status"], ka["error_code"])
    if not real:
        return "UNKNOWN: the real continue was not reached."
    since_create, since_ka = real["t_start_s"] - create["t_end_s"], real["t_start_s"] - ka["t_end_s"]
    gaps = "the real continue came %.0f s after the create and %.0f s after the keep-alive" % (since_create, since_ka)
    if real["ok"]:
        if since_create > idle_limit:
            return "RESET: %s; without a reset the thread would have been idle %.0f s, over the %.0f s limit, and it answered 200." % (gaps, since_create, idle_limit)
        return "UNKNOWN: the real continue answered 200 but %s, inside the %.0f s limit, so it cannot show a reset." % (gaps, idle_limit)
    if real["status"] == 404 and real["error_code"] == "thread_not_found":
        if since_ka >= idle_limit:
            return "UNKNOWN: 404 thread_not_found, but %s, also over the %.0f s limit since the keep-alive." % (gaps, idle_limit)
        return "NOT RESET (or the thread expired anyway): 404 thread_not_found; %s. The keep-alive was within the limit, so a reset would have kept it alive." % gaps
    return "UNKNOWN: the real continue returned status %s code %s; %s." % (real["status"], real["error_code"], gaps)


def growth(create, ka, real):
    """Tokens the keep-alive added to the stored history. The thread stores the keep-alive's user message and its reply:
    added = (keep-alive prompt - create prompt - create reply) + keep-alive reply. Approximate: it assumes the stored reply is as long as
    output_tokens counts it (thinking blocks may differ), UNKNOWN otherwise."""
    if not (create and ka and create["ok"] and ka["ok"]):
        return None
    added = (ka["prompt_tokens"] - create["prompt_tokens"] - create["output_tokens"]) + ka["output_tokens"]
    return {"prompt_tokens_create": create["prompt_tokens"], "prompt_tokens_keepalive": ka["prompt_tokens"],
            "prompt_tokens_real": real["prompt_tokens"] if real and real["ok"] else None,
            "output_tokens_create": create["output_tokens"], "output_tokens_keepalive": ka["output_tokens"],
            "added_by_keepalive_tokens_approx": added}


def exp3_rows(records):
    rows = []
    n = max([r["turn"] for r in records if r["exp"] == "e3"] or [0])
    for k in range(1, n + 1):
        a = brief(last([r for r in records if r["turn"] == k], "e3", "resend"))
        b = brief(last([r for r in records if r["turn"] == k], "e3", "thread"))
        if a and b and a["ok"] and b["ok"] and a["ttft_ms"] is not None and b["ttft_ms"] is not None:
            rows.append({"turn": k, "resend": a, "thread": b, "ratio": stats.ratio(b["ttft_ms"], a["ttft_ms"])})
    return rows


def exp3_summary(rows):
    if not rows:
        return None
    w = min(5, len(rows) // 2) or 1
    out = {"turns_measured": len(rows), "window": w}
    for name, part in (("first", rows[:w]), ("last", rows[-w:])):
        t = stats.median([r["thread"]["ttft_ms"] for r in part])
        s = stats.median([r["resend"]["ttft_ms"] for r in part])
        out[name] = {"turns": [r["turn"] for r in part], "thread_ttft_median_ms": t, "resend_ttft_median_ms": s, "ratio_of_medians": stats.ratio(t, s),
                     "median_of_turn_ratios": stats.median([r["ratio"] for r in part if r["ratio"] is not None]),
                     "thread_cost_median_usd": stats.median([r["thread"]["cost_usd"] for r in part]),
                     "resend_cost_median_usd": stats.median([r["resend"]["cost_usd"] for r in part])}
    for arm in ("thread", "resend"):
        xs = [r[arm]["ttft_ms"] for r in rows]
        out[arm + "_range_ms"] = [min(xs), max(xs)]
        out[arm + "_change_first_to_last_ms"] = out["last"][arm + "_ttft_median_ms"] - out["first"][arm + "_ttft_median_ms"]
    out["turns_thread_lower"] = sum(1 for r in rows if r["ratio"] is not None and r["ratio"] < 1)
    return out


def analyze(doc):
    recs = doc["records"]
    cfg = doc["config"]
    idle_limit = cfg.get("idle_limit", 300.0)
    prime, c1, chk, rep, cold = (brief(last(recs, "e1", x)) for x in ("prime", "thread_create", "continue_check", "replay", "cold_reload"))
    e1 = {"prime": prime, "thread_create": c1, "continue_check": chk, "replay": rep, "cold_reload": cold,
          "thread_expired": expiry_verdict(c1, chk), "replay_read_1h_cache": cache_verdict(prime, rep), "abort": doc["aborts"].get("e1")}
    if rep and cold and rep["ok"] and cold["ok"]:
        e1["replay_vs_cold"] = {"ttft_ratio": stats.ratio(rep["ttft_ms"], cold["ttft_ms"]), "cost_ratio": stats.ratio(rep["cost_usd"], cold["cost_usd"])}
    c2, ka, real = (brief(last(recs, "e2", x)) for x in ("thread_create", "keepalive", "real_continue"))
    e2 = {"thread_create": c2, "keepalive": ka, "real_continue": real, "verdict": keepalive_verdict(c2, ka, real, idle_limit),
          "growth": growth(c2, ka, real), "abort": doc["aborts"].get("e2")}
    rows = exp3_rows(recs)
    e3 = {"setup_resend": brief(next((r for r in recs if r["exp"] == "e3" and r["label"] == "resend" and r["turn"] == 0), None)),
          "setup_thread": brief(next((r for r in recs if r["exp"] == "e3" and r["label"] == "thread" and r["turn"] == 0), None)),
          "rows": [{"turn": r["turn"], "resend_ttft_ms": r["resend"]["ttft_ms"], "thread_ttft_ms": r["thread"]["ttft_ms"], "thread_over_resend": r["ratio"],
                    "resend_cost_usd": r["resend"]["cost_usd"], "thread_cost_usd": r["thread"]["cost_usd"],
                    "resend_prompt_tokens": r["resend"]["prompt_tokens"], "thread_prompt_tokens": r["thread"]["prompt_tokens"],
                    "resend_cache_read_tokens": r["resend"]["cache_read_tokens"], "thread_cache_read_tokens": r["thread"]["cache_read_tokens"]} for r in rows],
          "summary": exp3_summary(rows), "abort": doc["aborts"].get("e3")}
    return {"n": {"e1_requests": 1, "e2_requests": 1, "e3_turns_per_arm": len(rows)}, "e1": e1, "e2": e2, "e3": e3}


def render_md(doc):
    an = doc["analysis"]
    c = doc["config"]
    e1, e2, e3 = an["e1"], an["e2"], an["e3"]
    L = ["# Message threads: tuning experiments", "",
         "Status: **%s**. Model `%s`, spent $%.4f (cap $%.2f, planned upper bound $%.2f)." % (doc["status"], c["model"], doc["spent_usd"], c["max_usd"], doc["planned_upper_bound_usd"]),
         "", "> " + DISCLAIMER, ""]
    if doc.get("partial"):
        p = doc["partial"]
        L += ["**PARTIAL.** The run stopped on a %s error and did not retry: %s. This mode cannot be resumed; the numbers below cover only what was completed. Spend counted: $%.4f." % (p.get("kind"), p.get("reason"), p.get("spent_usd", 0.0)), ""]
    elif doc["status"].startswith("PARTIAL"):
        L += ["**PARTIAL.** %s. This mode cannot be resumed; the numbers below cover only what was completed." % doc["status"], ""]
    L += ["Exact n: experiment 1 is one request per step (n = 1 each, a single replay, not a rate); experiment 2 is one thread (n = 1); experiment 3 has %d measured turns per arm. "
          "Timeline (seconds from t0, planned and actual): %s." % (an["n"]["e3_turns_per_arm"], ", ".join("%s %.0f/%.0f" % (e["name"], e["planned_s"], e["actual_s"]) for e in doc["events"]) or "not reached"), ""]
    L += ["## 1 Warm-cache reload (%d-token history)" % c["big"], ""]
    if e1["abort"]:
        L += ["**Stopped:** %s" % e1["abort"], ""]
    L += ["| Step | status | TTFT ms | prompt tok | cache read tok | cache write tok | output tok | cost |", "|---|---|---|---|---|---|---|---|"]
    for lab, key in (("prime (normal request, 1h cache)", "prime"), ("thread create at t0 (1h)", "thread_create"), ("continue check", "continue_check"),
                     ("replay create (same prefix, 1h)", "replay"), ("cold reload (fresh salt, 5m cache_control)", "cold_reload")):
        b = e1[key]
        if not b:
            L.append("| %s | not reached | | | | | | |" % lab)
        else:
            L.append("| %s | %s | %s | %d | %d | %d | %d | %s |" % (lab, b["status"], _f(b["ttft_ms"]), b["prompt_tokens"], b["cache_read_tokens"], b["cache_creation_tokens"], b["output_tokens"], _f(b["cost_usd"], 4, "$")))
    L += ["", "- Thread gone? %s" % e1["thread_expired"], "- **Did the replay read the 1-hour cache?** %s" % e1["replay_read_1h_cache"]]
    if e1.get("replay_vs_cold"):
        v = e1["replay_vs_cold"]
        L.append("- Replay against the cold reload: TTFT ratio %s, cost ratio %s (n = 1 each; the cold reload writes a 5-minute entry at 1.25x input, the replay's write, if any, would be 1-hour at 2x)." % (_f(v["ttft_ratio"], 2), _f(v["cost_ratio"], 2)))
    L += ["", "## 2 Keep-alive (%d-token history)" % c["small"], ""]
    if e2["abort"]:
        L += ["**Stopped:** %s" % e2["abort"], ""]
    L += ["| Step | status | TTFT ms | prompt tok | cache read tok | cache write tok | output tok | cost |", "|---|---|---|---|---|---|---|---|"]
    for lab, key in (("thread create (t0)", "thread_create"), ("keep-alive continue", "keepalive"), ("real continue", "real_continue")):
        b = e2[key]
        if not b:
            L.append("| %s | not reached | | | | | | |" % lab)
        else:
            L.append("| %s | %s | %s | %d | %d | %d | %d | %s |" % (lab, b["status"], _f(b["ttft_ms"]), b["prompt_tokens"], b["cache_read_tokens"], b["cache_creation_tokens"], b["output_tokens"], _f(b["cost_usd"], 4, "$")))
    L += ["", "- **Idle timer reset by the keep-alive?** %s" % e2["verdict"]]
    g = e2["growth"]
    if g:
        L.append("- The keep-alive added about %d tokens to the stored history (prompt tokens: create %d, keep-alive %d, real continue %s; approximate, it assumes the stored reply is as long as its output token count)." % (
            g["added_by_keepalive_tokens_approx"], g["prompt_tokens_create"], g["prompt_tokens_keepalive"], g["prompt_tokens_real"] if g["prompt_tokens_real"] is not None else "n/a"))
    else:
        L.append("- Token growth from the keep-alive: UNKNOWN (the create or the keep-alive did not complete).")
    L += ["", "## 3 Growth (%d-token history, %d turns, max_tokens %d)" % (c["small"], c["turns"], c["max_tokens"]), ""]
    if e3["abort"]:
        L += ["**Stopped:** %s" % e3["abort"], ""]
    s = e3["summary"]
    L += ["| Turn | resend TTFT ms | thread TTFT ms | thread / resend | resend cost | thread cost | resend prompt tok | thread prompt tok |", "|---|---|---|---|---|---|---|---|"]
    for r in e3["rows"]:
        L.append("| %d | %s | %s | %s | %s | %s | %d | %d |" % (r["turn"], _f(r["resend_ttft_ms"]), _f(r["thread_ttft_ms"]), _f(r["thread_over_resend"], 2),
                                                          _f(r["resend_cost_usd"], 5, "$"), _f(r["thread_cost_usd"], 5, "$"), r["resend_prompt_tokens"], r["thread_prompt_tokens"]))
    if not e3["rows"]:
        L.append("| no turn finished on both arms | | | | | | | |")
    if s:
        L += ["", "| Window | thread median TTFT ms | resend median TTFT ms | ratio of medians | median of turn ratios | thread cost median | resend cost median |", "|---|---|---|---|---|---|---|"]
        for name in ("first", "last"):
            w = s[name]
            L.append("| %s %d turns (%d to %d) | %s | %s | %s | %s | %s | %s |" % (name, s["window"], w["turns"][0], w["turns"][-1], _f(w["thread_ttft_median_ms"]), _f(w["resend_ttft_median_ms"]),
                                                                          _f(w["ratio_of_medians"], 2), _f(w["median_of_turn_ratios"], 2), _f(w["thread_cost_median_usd"], 5, "$"), _f(w["resend_cost_median_usd"], 5, "$")))
        L += ["", "What the data shows (n = %d turns per arm, one thread, one run):" % s["turns_measured"],
              "- Thread TTFT was lower than the cached resend on %d of %d turns." % (s["turns_thread_lower"], s["turns_measured"]),
              "- Median TTFT, first window to last window: thread %+.0f ms, resend %+.0f ms." % (s["thread_change_first_to_last_ms"], s["resend_change_first_to_last_ms"]),
              "- TTFT range over all turns: thread %.0f to %.0f ms, resend %.0f to %.0f ms." % (tuple(s["thread_range_ms"]) + tuple(s["resend_range_ms"])),
              "- The docs say TTFT in a thread \"stays lower and steadier as the conversation grows\". The history grew by only the turns above, so this run says nothing about long conversations. Read the numbers; there is no more to conclude from n = %d." % s["turns_measured"]]
    sr, st = e3["setup_resend"], e3["setup_thread"]
    if sr or st:
        L += ["", "Turn 0 (cold write, not in the windows): resend TTFT %s ms, cost %s; thread create TTFT %s ms, cost %s." % (
            _f(sr and sr["ttft_ms"]), _f(sr and sr["cost_usd"], 5, "$"), _f(st and st["ttft_ms"]), _f(st and st["cost_usd"], 5, "$"))]
    L += ["", "## Reading this", "",
          "- TTFT includes connection setup and the request upload (a fresh connection per request, the same for every arm). Cost is computed from the usage fields at list prices; cache writes with the 1-hour lifetime are priced at 2x the base input price (prompt-caching page, read 2026-11-07).",
          "- Each experiment has its own prefix salt, so none shares cache with another. A failed continue is a result: nothing is replayed automatically.",
          "- %s." % IDLE_LIMIT_NOTE]
    if doc.get("notes"):
        L += ["", "## Notes", ""] + ["- " + n for n in doc["notes"]]
    return "\n".join(L) + "\n"
