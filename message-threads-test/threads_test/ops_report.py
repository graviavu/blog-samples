"""ops.md and ops.json for run-ops-test.sh: tables in the format of the README results section. No message ids, request ids or account ids."""
import json
import os
import re

from . import stats
from .pricing import prompt_len
from .report import DISCLAIMER as BASE_DISCLAIMER, _private_write

DISCLAIMER = BASE_DISCLAIMER + " The send throttle is client-side pacing of the request body: it adds no latency, loss or TLS record effects, so it is a model of a slow uplink, not a measurement of one."
RATES_FOR_PROJECTION = (1, 5, 20, 100)
SIZES_FOR_PROJECTION = (100000, 500000, 1000000)
KNOWN_CODES = ("thread_already_continued", "thread_continue_in_flight", "thread_not_found")


def outcome(status, ok, error_code):
    """What a repeated continue returned: success, one of the three thread codes, or something else."""
    if ok:
        return "success"
    if error_code in KNOWN_CODES:
        return error_code
    if status is None:
        return "no response (network error)"
    return "other (HTTP %s %s)" % (status, error_code or "no code")


def _ok(r):
    return r["status"] == 200 and r["complete"]


def _pl(r):
    return prompt_len(r["usage"])


def _med(xs):
    xs = [x for x in xs if x is not None]
    return stats.median(xs) if xs else None


def _f(x, nd=0, pre="", suf=""):
    return "n/a" if x is None else "{}{:,.{}f}{}".format(pre, x, nd, suf)


# ----- B+

def _upload(r):
    """Upload of one record: from the end of connection setup until the last body byte was handed to the kernel."""
    if r.get("upload_ms") is not None:
        return r["upload_ms"]
    if r.get("body_sent_ms") is not None and r.get("connect_ms") is not None:
        return r["body_sent_ms"] - r["connect_ms"]
    return None


B_LABEL = re.compile(r"^(resend|create|continue) (\S+) r(\d+)$")


def analyze_b(records):
    rows, order = {}, []
    for r in records:
        if r["test"] != "B":
            continue
        m = B_LABEL.match(r["label"])
        if not m or not _ok(r):
            continue
        arm, cond = m.group(1), m.group(2)
        key = (cond, arm)
        if key not in rows:
            rows[key] = []
            order.append(key)
        rows[key].append(r)
    out = []
    for cond, arm in order:
        rs = rows[(cond, arm)]
        up = _med([_upload(r) for r in rs])
        tt = _med([r["ttft_ms"] for r in rs])
        after = _med([None if (r["ttft_ms"] is None or r.get("body_sent_ms") is None) else r["ttft_ms"] - r["body_sent_ms"] for r in rs])
        rate = rs[0].get("rate_mbps")
        nbytes = _med([r["body_bytes"] for r in rs])
        out.append({"cond": cond, "arm": arm, "n": len(rs), "rate_mbps": rate, "body_bytes": nbytes,
                    "connect_ms": _med([r.get("connect_ms") for r in rs]), "upload_ms": up, "ttft_ms": tt, "ttft_after_upload_ms": after,
                    "total_ms": _med([r["total_ms"] for r in rs]),
                    "arithmetic_upload_ms": (nbytes * 8.0 / (rate * 1e6) * 1000) if (rate and nbytes) else None,
                    "prompt_tokens": _med([_pl(r) for r in rs]), "cache_read_tokens": _med([r["usage"].get("cache_read_input_tokens", 0) for r in rs]),
                    "cost_usd": _med([r["cost"]["total"] for r in rs])})
    bpt = {}
    for arm in ("resend", "create"):
        v = [r["body_bytes"] / _pl(r) for rs_key, rs in rows.items() if rs_key[1] == arm for r in rs if _pl(r)]
        bpt[arm] = _med(v)
    res = {"rows": out, "bytes_per_token": bpt}
    if bpt["resend"]:
        res["projection"] = [{"tokens": t, "bytes": t * bpt["resend"],
                              "seconds": {str(rt): t * bpt["resend"] * 8.0 / (rt * 1e6) for rt in RATES_FOR_PROJECTION}}
                             for t in SIZES_FOR_PROJECTION]
    return res


# ----- E

E_LABEL = re.compile(r"^(create|continue cut|same continue|replay create) r(\d+)$")


def analyze_e(records):
    runs = {}
    for r in records:
        if r["test"] != "E":
            continue
        m = E_LABEL.match(r["label"])
        if m:
            runs.setdefault(int(m.group(2)), {})[m.group(1)] = r
    out, counts, by_gap = [], {}, {}
    for n in sorted(runs):
        d = runs[n]
        same = d.get("same continue")
        oc = outcome(same["status"], _ok(same), same["error_code"]) if same else "not sent"
        counts[oc] = counts.get(oc, 0) + 1
        cut, rep = d.get("continue cut"), d.get("replay create")
        gap = (same or cut or {}).get("gap_s")
        if same:
            g = by_gap.setdefault("%g" % (gap or 0), {})
            g[oc] = g.get(oc, 0) + 1
        out.append({"run": n, "outcome": oc, "gap_s": gap,
                    "cut": None if not cut else {"usage_at_abort": cut["usage"], "aborted": cut["aborted"], "status": cut["status"], "utc_start": cut["utc_start"], "utc_end": cut["utc_end"], "ttft_ms": cut["ttft_ms"]},
                    "same_status": same and same["status"], "same_ttft_ms": same and same["ttft_ms"],
                    "replay": None if not rep else {"status": rep["status"], "ok": _ok(rep), "cache_read_tokens": rep["usage"].get("cache_read_input_tokens", 0),
                                                    "cost_usd": rep["cost"]["total"], "ttft_ms": rep["ttft_ms"]}})
    complete = [r for r in records if r["test"] == "E" and _ok(r)]
    cut = [r for r in records if r["test"] == "E" and r["aborted"]]
    billing = {"complete_requests": len(complete), "cut_requests": len(cut),
               "complete_usage": {k: sum(r["usage"].get(k, 0) for r in complete) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")},
               "complete_cost_usd": sum(r["cost"]["total"] for r in complete),
               "cut_usage_at_abort": {k: sum(r["usage"].get(k, 0) for r in cut) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")},
               "window_utc": [min((r["utc_start"] for r in records if r["test"] == "E"), default=None), max((r["utc_end"] for r in records if r["test"] == "E"), default=None)]}
    return {"runs": out, "counts": counts, "counts_by_gap": by_gap, "billing": billing}


# ----- A

A_TURN = re.compile(r"^turn (\d+)$")
A_FORK = re.compile(r"^fork (\S+) at turn (\d+)$")


def analyze_a(records):
    turns, forks = {}, []
    for r in records:
        if r["test"] != "A":
            continue
        m = A_TURN.match(r["label"])
        if m and _ok(r):
            turns[int(m.group(1))] = r
        m = A_FORK.match(r["label"])
        if m:
            forks.append((m.group(1), int(m.group(2)), r))
    if not forks:
        return {"turns": [{"turn": k, "ttft_ms": r["ttft_ms"], "prompt_tokens": _pl(r), "read": r["usage"].get("cache_read_input_tokens", 0),
                           "write": r["usage"].get("cache_creation_input_tokens", 0), "cost_usd": r["cost"]["total"]} for k, r in sorted(turns.items())], "forks": []}
    n = forks[0][1]
    at_n, before_n, after_n = turns.get(n), turns.get(n - 1), turns.get(n + 1)
    out = []
    for tag, _, r in forks:
        read = r["usage"].get("cache_read_input_tokens", 0)
        if not _ok(r):
            verdict = "UNKNOWN: the fork request failed"
        elif not at_n:
            verdict = "UNKNOWN: the turn-%d request is missing" % n
        elif read >= 0.98 * _pl(at_n):
            verdict = "HIT: read the entry written at turn %d" % n
        elif before_n and read >= 0.98 * _pl(before_n):
            verdict = "EARLIER ENTRY ONLY: read the entry of turn %d, not turn %d" % (n - 1, n)
        elif read > 0:
            verdict = "PARTIAL: read %d tokens, less than any later turn's entry" % read
        else:
            verdict = "MISS: no cache read"
        out.append({"fork": tag, "ok": _ok(r), "prompt_tokens": _pl(r), "read": read, "write": r["usage"].get("cache_creation_input_tokens", 0),
                    "input": r["usage"].get("input_tokens", 0), "cost_usd": r["cost"]["total"], "ttft_ms": r["ttft_ms"], "verdict": verdict})
    return {"fork_at": n, "expected_read_tokens": _pl(at_n) if at_n else None, "turn_before_read_limit": _pl(before_n) if before_n else None,
            "next_main_turn": None if not after_n else {"read": after_n["usage"].get("cache_read_input_tokens", 0), "cost_usd": after_n["cost"]["total"], "ttft_ms": after_n["ttft_ms"]},
            "turns": [{"turn": k, "ttft_ms": r["ttft_ms"], "prompt_tokens": _pl(r), "read": r["usage"].get("cache_read_input_tokens", 0),
                       "write": r["usage"].get("cache_creation_input_tokens", 0), "cost_usd": r["cost"]["total"]} for k, r in sorted(turns.items())],
            "forks": out}


def analyze(doc):
    recs = doc["records"]
    return {"B": analyze_b(recs), "E": analyze_e(recs), "A": analyze_a(recs)}


# ----- markdown

def render_md(doc):
    a, cfg = doc["analysis"], doc["config"]
    L = ["# Message threads: operations tests", "",
         "Status: **%s**. Model `%s`, spent $%.4f (cap $%.2f, estimate $%.2f)." % (doc["status"], cfg["model"], doc["spent_usd"], cfg["max_usd"], doc["estimate_usd"]),
         "", "> " + DISCLAIMER, ""]
    p = doc.get("partial")
    if p:
        L += ["**PARTIAL.** The run stopped on a %s error and did not retry: %s. Spend counted: $%.4f. Only the requests recorded below were completed." % (p.get("kind"), p.get("reason"), p.get("spent_usd", 0.0)), ""]
    tests = cfg["tests"]
    if "B" in tests:
        L += _render_b(a["B"], cfg)
    if "E" in tests:
        L += _render_e(a["E"], cfg)
    if "A" in tests:
        L += _render_a(a["A"], cfg)
    L += ["### Reading this", "",
          "- Connect is DNS, TCP and TLS setup, its own column. Upload is from the end of that setup until the last body byte was handed to the kernel. It is when the client finished handing over, not when the server finished receiving.",
          "- The socket uses the OS default send buffers (no SO_SNDBUF). On the no-throttle rows the kernel can still be sending after the last byte was handed over, so those Upload cells are \"handed to the kernel\", a lower bound on the time on the wire. On a throttled row the pacing dominates.",
          "- TTFT runs from the start of the request, so it includes connect and upload. TTFT after body sent is TTFT minus connect minus upload: the server side plus the return trip (plus whatever the kernel still had to send).",
          "- Every cell is the median of the repetitions in the n column; with n = 1 it is a single observation, not a rate. One machine, one network, one day."]
    if doc.get("aborts"):
        L += ["", "### Tests that did not complete", ""] + ["- %s: %s" % (k, v) for k, v in sorted(doc["aborts"].items())]
    if doc.get("notes"):
        L += ["", "### Notes", ""] + ["- " + n for n in doc["notes"]]
    return "\n".join(L) + "\n"


def _render_b(b, cfg):
    L = ["### B+: request body bytes and upload time (%s-token history)" % "{:,}".format(cfg["b_tokens"]), "",
         "| Condition | Arm | n | Body (KB) | Connect (ms) | Upload (ms) | Arithmetic (ms) | TTFT (ms) | TTFT after body sent (ms) | Total (ms) | Prompt tokens | Cost |",
         "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    if not b["rows"]:
        L.append("| n/a | n/a | 0 | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |")
    for r in b["rows"]:
        L.append("| %s | %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            "no throttle" if not r["rate_mbps"] else "%g Mbps" % r["rate_mbps"], {"resend": "Full resend + cache", "create": "Thread create (replay)", "continue": "Thread continue"}[r["arm"]],
            r["n"], _f(None if r["body_bytes"] is None else r["body_bytes"] / 1000.0, 1), _f(r.get("connect_ms")), _f(r["upload_ms"]), _f(r["arithmetic_upload_ms"]), _f(r["ttft_ms"]),
            _f(r["ttft_after_upload_ms"]), _f(r["total_ms"]), _f(r["prompt_tokens"]), _f(r["cost_usd"], 4, "$")))
    bpt = b["bytes_per_token"]
    L += ["", "Arithmetic is body bytes divided by the throttle rate; the upload column should sit at or just above it on a throttled row. "
          "The `Thread create` row is what a replay after an expired thread sends. The no-throttle rows use the OS default send buffers; their Upload is when the body was handed to the kernel.", "",
          "Bytes per token of this synthetic history (request body bytes / prompt tokens from the usage field): full resend **%s**, thread create **%s**. The body includes the tool definitions, the system prompt and the JSON around the text. It is a property of the generated log-and-question history this script sends, not a measurement of Claude Code tool output; other content has a different ratio." % (
              _f(bpt.get("resend"), 2), _f(bpt.get("create"), 2)), ""]
    if b.get("projection"):
        L += ["Arithmetic on the full-resend ratio of this synthetic history (size / rate only; no TLS, slow start or loss):", "",
              "| History | Body (MB) | " + " | ".join("at %d Mbps (s)" % r for r in RATES_FOR_PROJECTION) + " |",
              "| --- | ---: | " + " | ".join("---:" for _ in RATES_FOR_PROJECTION) + " |"]
        for p in b["projection"]:
            L.append("| {:,} tokens | {} | {} |".format(p["tokens"], _f(p["bytes"] / 1e6, 2), " | ".join(_f(p["seconds"][str(r)], 1) for r in RATES_FOR_PROJECTION)))
        L.append("")
    return L


def _render_e(e, cfg):
    gaps = cfg.get("e_gaps", [0.0])
    L = ["### E: dropped-stream retry (%d runs per resend gap, gaps %s s, %s-token history)" % (cfg["e_runs"], " and ".join("%g" % g for g in gaps), "{:,}".format(cfg["e_tokens"])), "",
         "Each run: thread create, a continue whose stream the client closed after the first content delta (before `message_stop`), the same continue sent again after the run's gap (0 s is an immediate resend), then a replay with a create. The gaps take turns from run to run.", "",
         "| Run | Resent after (s) | Same continue returned | Cut stream: input / cache read / cache write tokens at message_start | Cut at (UTC) | Replay | Replay cache read | Replay cost |",
         "| ---: | ---: | --- | --- | --- | --- | ---: | ---: |"]
    if not e["runs"]:
        L.append("| n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |")
    for r in e["runs"]:
        c, rp = r["cut"], r["replay"]
        u = c["usage_at_abort"] if c else {}
        L.append("| %d | %s | %s | %s | %s | %s | %s | %s |" % (
            r["run"], _f(r.get("gap_s"), 0), r["outcome"], "n/a" if not c else "%d / %d / %d" % (u.get("input_tokens", 0), u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0)),
            "n/a" if not c else "%s to %s%s" % (c["utc_start"], c["utc_end"], "" if c["aborted"] else " (NOT cut: status %s)" % c["status"]),
            "n/a" if not rp else ("answered" if rp["ok"] else "failed (HTTP %s)" % rp["status"]), _f(rp and rp["cache_read_tokens"]), _f(rp and rp["cost_usd"], 4, "$")))
    cnt = e["counts"]
    L += ["", "Counts: " + (", ".join("%s %d" % (k, v) for k, v in sorted(cnt.items())) if cnt else "none") + "."]
    for g, c in sorted(e.get("counts_by_gap", {}).items(), key=lambda kv: float(kv[0])):
        L.append("Resent after %s s: %s." % (g, ", ".join("%s %d" % (k, v) for k, v in sorted(c.items()))))
    L.append("")
    b = e["billing"]
    cu, ku = b["complete_usage"], b["cut_usage_at_abort"]
    n_cut = b["cut_requests"]
    full = cfg["e_max_tokens"] * n_cut
    L += ["Billing check for the Console (UNKNOWN until you look). Window: %s to %s UTC. In it, test E made %d complete requests and %d cut ones." % (
              b["window_utc"][0], b["window_utc"][1], b["complete_requests"], n_cut),
          "The complete requests account for %s input, %s cache write, %s cache read and %s output tokens ($%.4f by the list prices). "
          "The cut requests reported %s input and %s cache read tokens at their start; their output is not known to this script." % (
              _f(cu["input_tokens"]), _f(cu["cache_creation_input_tokens"]), _f(cu["cache_read_input_tokens"]), _f(cu["output_tokens"]), b["complete_cost_usd"],
              _f(ku["input_tokens"]), _f(ku["cache_read_input_tokens"])),
          "Every cut stream bills at least the input and the tokens generated before the cut. What matters is the output beyond the complete requests' %s: "
          "about %s (%d x %d, the output cap of each cut) means each orphaned generation ran on to its cap after the client left; "
          "a few tokens per cut means generation stopped at the cut. Other traffic on the key in the window mixes in, so for this check run "
          "`./run-ops-test.sh --run --tests E` on its own." % (_f(cu["output_tokens"]), _f(full), cfg["e_max_tokens"], n_cut), ""]
    return L


def _render_a(a, cfg):
    L = ["### A: client-side savepoint (%s-token history, %d turns, forked twice at turn %s)" % ("{:,}".format(cfg["a_tokens"]), cfg["a_turns"], cfg["a_fork_at"]), ""]
    if a["forks"]:
        L += ["The main line is a cached full resend. Each fork is the prefix up to turn %d, the reply of that turn, and a different new user message." % a["fork_at"],
              "Expected cache read if the entry written at turn %d is hit: %s tokens (the prompt of that turn). The entry of turn %d would give %s." % (
                  a["fork_at"], _f(a["expected_read_tokens"]), a["fork_at"] - 1, _f(a["turn_before_read_limit"])), "",
              "| Request | Prompt tokens | Cache read | Cache write | Uncached input | Cost | TTFT (ms) | Verdict |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
        nm = a.get("next_main_turn")
        if nm:
            L.append("| Main line, turn %d (the request after the savepoint) | n/a | %s | n/a | n/a | %s | %s | reference |" % (a["fork_at"] + 1, _f(nm["read"]), _f(nm["cost_usd"], 4, "$"), _f(nm["ttft_ms"])))
        for f in a["forks"]:
            L.append("| Fork %s | %s | %s | %s | %s | %s | %s | %s |" % (f["fork"], _f(f["prompt_tokens"]), _f(f["read"]), _f(f["write"]), _f(f["input"]), _f(f["cost_usd"], 4, "$"), _f(f["ttft_ms"]), f["verdict"]))
    else:
        L.append("No fork was reached.")
    L += ["", "Main line, per turn:", "", "| Turn | Prompt tokens | Cache read | Cache write | TTFT (ms) | Cost |", "| ---: | ---: | ---: | ---: | ---: | ---: |"]
    for t in a["turns"]:
        L.append("| %d | %s | %s | %s | %s | %s |" % (t["turn"], _f(t["prompt_tokens"]), _f(t["read"]), _f(t["write"]), _f(t["ttft_ms"]), _f(t["cost_usd"], 4, "$")))
    L.append("")
    return L


def write_outputs(outdir, doc):
    """Atomic write of ops.json and ops.md (0600). Temp files are removed."""
    tmps = []
    try:
        for name, text in (("ops.json", json.dumps(doc, indent=2, sort_keys=True) + "\n"), ("ops.md", render_md(doc))):
            tmp = os.path.join(outdir, name + ".tmp")
            tmps.append(tmp)
            _private_write(tmp, text)
            os.replace(tmp, os.path.join(outdir, name))
    finally:
        for t in tmps:
            if os.path.exists(t):
                os.remove(t)
