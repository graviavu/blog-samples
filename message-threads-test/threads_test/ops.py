"""--ops tests (run-ops-test.sh): what a long agent session puts on the wire, what a dropped stream does to a thread, and whether
a client-side savepoint hits the cache. Haiku 5.5 by default. Reuses the client, the guard, the pricing, the history and the probe
of the main harness; nothing here duplicates them.

B+  BODY BYTES AND UPLOAD TIME  a ~100K-token history, three arms per network condition: a cached full resend, a thread create (what a
                                replay sends) and a thread continue. The conditions are no throttle, then a client-side send throttle at
                                1 Mbps and 5 Mbps. Per request: body bytes, time until the last body byte was handed to the socket,
                                TTFT, total time, usage, cost. Measured bytes per token = resend body bytes / prompt tokens.
E   DROPPED-STREAM RETRY        5 runs: create a thread, start a continue, close the stream after the first content delta (before
                                message_stop), send the SAME continue again, record which of success, thread_already_continued,
                                thread_continue_in_flight comes back, then replay with a create. The usage of every request and the UTC
                                window are logged so the orphaned generation can be looked for in the Console.
A   CLIENT-SIDE SAVEPOINT        a cached 10-turn main line, then two forks from the same prefix at turn N (each: the prefix plus a different new
                                user message). Per fork: cache read tokens, cost, TTFT, and whether it read the entry written at turn N.

No automatic retries and no automatic replays: a request that fails is a result. A test that cannot go on is marked, the others still
run. Every test has its own prefix salt, so none shares cache with another. A PARTIAL ops.md / ops.json is written after every request."""
import json
import math
import platform
import random
import sys
import time

from . import convo, pricing, redact as R
from . import ops_report
from .client import FatalApiError
from .runner import Guard, SpendCap

TESTS = ("B", "E", "A")
DELTA_TOKENS = 2000        # tokens a warm request is assumed to add (written, not read) in the estimate
A_GROW_UB = 2000           # worst-case tokens one test A turn adds to the prompt
E_LONG_ASK = ("Ignore the one-sentence rule for this turn: list 40 numbered observations about the incident, one per line, "
              "so that the reply streams for a while.")


class TestAbort(Exception):
    """One test cannot go on; the others still run."""

    def __init__(self, test, reason):
        super().__init__(reason)
        self.test, self.reason = test, reason


# ----- the estimate (before any call)

def ub_tokens(tokens, margin, extra=0):
    return int(math.ceil(tokens * margin)) + 1000 + extra


def req_expected(model, prompt_ub, kind, max_tokens):
    """Expected dollars of one request: 'cold' writes the whole prompt, 'warm' reads it and writes DELTA_TOKENS. Output at max_tokens.
    The tier is taken from the upper-bound prompt, so a 100K history is priced on the dearer side of Haiku's 100,000-token step."""
    p_in, p_out, p_w, p_r = pricing.tier(model, prompt_ub)
    out = max_tokens * p_out / 1e6
    if kind == "cold":
        return prompt_ub * p_w / 1e6 + out
    return prompt_ub * p_r / 1e6 + DELTA_TOKENS * p_w / 1e6 + out


def plan(cfg):
    """Per selected test: request counts, ub prompt, expected dollars (cache behaves as documented) and the worst case (no request reads
    the cache, every prompt token at the dearer of input and write price). The estimate is the sum of the expected figures."""
    m, mt, mg = cfg["model"], cfg["max_tokens"], cfg["margin"]
    out = {}
    if "B" in cfg["tests"]:
        ub = ub_tokens(cfg["b_tokens"], mg, 2 * mt)
        n_conds = 1 + len(cfg["rates"])
        n_warm = cfg["b_reps"] * n_conds * 3
        out["B"] = {"requests": 1 + n_warm, "cold": 1, "warm": n_warm, "prompt_tokens_ub": ub,
                    "expected": req_expected(m, ub, "cold", mt) + n_warm * req_expected(m, ub, "warm", mt),
                    "worst": (1 + n_warm) * pricing.request_upper_bound(m, ub, mt)}
    if "E" in cfg["tests"]:
        ub = ub_tokens(cfg["e_tokens"], mg, 2 * cfg["e_max_tokens"])
        n = cfg["e_runs"] * 4          # create, continue (cut), same continue again, replay create
        out["E"] = {"requests": n, "cold": 1, "warm": n - 1, "prompt_tokens_ub": ub,
                    "expected": req_expected(m, ub, "cold", cfg["e_max_tokens"]) + (n - 1) * req_expected(m, ub, "warm", cfg["e_max_tokens"]),
                    "worst": n * pricing.request_upper_bound(m, ub, cfg["e_max_tokens"])}
    if "A" in cfg["tests"]:
        ub = ub_tokens(cfg["a_tokens"], mg, (cfg["a_turns"] + 2) * (A_GROW_UB + mt))
        n = cfg["a_turns"] + 2         # the main line plus two forks
        out["A"] = {"requests": n, "cold": 1, "warm": n - 1, "prompt_tokens_ub": ub,
                    "expected": req_expected(m, ub, "cold", mt) + (n - 1) * req_expected(m, ub, "warm", mt),
                    "worst": n * pricing.request_upper_bound(m, ub, mt)}
    return {"tests": out, "expected": sum(t["expected"] for t in out.values()), "worst": sum(t["worst"] for t in out.values())}


# ----- messages used by tests A and E

def grow_msg(seed, tag, i):
    """A user message of about 1K tokens (a log excerpt and a question), deterministic per (seed, tag, i)."""
    rng = random.Random("%s|%s|%s" % (seed, tag, i))
    return {"role": "user", "content": [{"type": "text", "text": convo.followup_text(i) + "\n" + convo._log_block(rng)}]}


class Ops:
    def __init__(self, cfg, client, outdir, log=print, sleep=time.sleep, guard=None, flusher=None):
        self.cfg, self.client, self.outdir, self._log, self.sleep = cfg, client, outdir, log, sleep
        self.guard = guard or Guard(cfg["max_usd"])
        self.records = []
        self.notes = []
        self.aborts = {}
        self.status = "running"
        self.started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.n_requests = 0
        self.in_flight = 0.0
        self.in_flight_at_stop = 0.0
        self.stage = None
        self.partial = None
        self.calibrated = set()
        self.plan = plan(cfg)
        self.flusher = flusher or ops_report.write_outputs
        self.hist = {}
        for name, key in (("B", "b_tokens"), ("E", "e_tokens"), ("A", "a_tokens")):
            if name in cfg["tests"]:
                self.hist[name] = convo.build_history(cfg["seed"], cfg[key], cfg["cpt"][cfg[key]])

    def log(self, msg):
        self._log(R.redact(msg))

    # ----- plumbing
    def body(self, messages, system=None, thread=None, max_tokens=None):
        c = self.cfg
        b = {"model": c["model"], "max_tokens": max_tokens or c["max_tokens"], "stream": True, "messages": messages, "tool_choice": convo.TOOL_CHOICE}
        if c["effort"] != "none":
            b["output_config"] = {"effort": c["effort"]}
        if system is not None:
            b["system"] = system
            b["tools"] = convo.TOOLS
        b["cache_control"] = {"type": "ephemeral"}
        if thread:
            b["thread"] = thread
        return b

    def salt(self, name):
        return convo.system_text(convo.make_salt(self.cfg["seed"], name, 0, self.cfg["salt_nonce"]))

    def ub_for(self, test):
        return self.plan["tests"][test]["prompt_tokens_ub"]

    def send(self, test, label, body, thread=False, need_ok=True, allow=(), **post_kw):
        """One request: the guard before, the usage-based charge after, a flush, no retry. Returns (Result, record).
        need_ok: a request that is not a 200 with message_stop (and not an allowed status or a deliberate abort) ends the test."""
        c = self.cfg
        mt = body["max_tokens"]
        projected = max(pricing.request_upper_bound(c["model"], self.ub_for(test), mt),
                        pricing.request_upper_bound(c["model"], len(json.dumps(body)) // 2 + 1000, mt))
        self.stage = {"test": test, "label": label}
        self.guard.check(projected)
        self.in_flight = projected
        t_start = time.gmtime()
        res = self.client.post(body, thread=thread, **post_kw)
        t_end = time.gmtime()
        self.in_flight = 0.0
        self.n_requests += 1
        parts = pricing.cost(c["model"], res.usage) if res.usage else {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0, "total": 0.0}
        charged = parts["total"]
        if res.aborted and res.usage:   # input side known from message_start; the output of a cut stream is unknown: charge max_tokens of it
            charged += mt * pricing.tier(c["model"], pricing.prompt_len(res.usage))[1] / 1e6
        elif (res.status == 200 and not res.usage) or (res.status == 200 and not res.complete and not res.aborted) or (res.status is None and res.exception):
            charged = max(charged, projected)
        rec = {"test": test, "label": label, "status": res.status, "complete": res.complete, "aborted": res.aborted,
               "error_code": res.error_code, "body_bytes": res.body_bytes,
               "body_sent_ms": None if res.body_sent_s is None else res.body_sent_s * 1000,
               "rate_mbps": post_kw.get("rate_bps", 0) / 1e6 if post_kw.get("rate_bps") else None,
               "ttft_ms": None if res.ttft is None else res.ttft * 1000, "total_ms": None if res.total is None else res.total * 1000,
               "first_kind": res.first_kind, "stop_reason": res.stop_reason,
               "usage": {k: res.usage.get(k, 0) for k in pricing.USAGE_KEYS}, "cost": parts, "charged_usd": charged,
               "utc_start": time.strftime("%H:%M:%S", t_start), "utc_end": time.strftime("%H:%M:%S", t_end), "stage": {}}
        if res.error:
            rec["error"] = res.error
        if res.exception:
            rec["exception"] = res.exception
        self.records.append(rec)
        self.log("  %s %-22s status %s%s ttft %s sent %s cost $%.4f spent $%.4f" % (
            test, label, res.status if res.status else "ERR", " (cut by the client)" if res.aborted else "",
            "%.0fms" % rec["ttft_ms"] if rec["ttft_ms"] is not None else "-",
            "%.0fms" % rec["body_sent_ms"] if rec["body_sent_ms"] is not None else "-", charged, self.guard.spent + charged))
        try:
            self.guard.add(charged)
        finally:
            self.flush()
        fatal = res.fatal()
        if fatal:   # credit, billing, quota or auth error: never retried, the run stops
            raise FatalApiError(*fatal)
        if res.ok and test not in self.calibrated:
            self.calibrate(test, res)
        if need_ok and not (res.ok or res.status in allow or res.aborted):
            raise TestAbort(test, "request %s failed with %s %s: %s" % (label, res.status, res.error_code or "", res.error or res.exception))
        return res, rec

    def calibrate(self, test, res):
        self.calibrated.add(test)
        key = {"B": "b_tokens", "E": "e_tokens", "A": "a_tokens"}[test]
        want, plen = self.cfg[key], pricing.prompt_len(res.usage)
        if plen > want * self.cfg["margin"]:
            raise TestAbort(test, "prompt is %d tokens for a %d-token history (margin %.2f): the cost estimate no longer holds. Lower --chars-per-token or the size and run the dry run again." % (plen, want, self.cfg["margin"]))
        if plen < want * 0.7:
            self.notes.append("Test %s: the prompt was %d tokens against %d requested; the history is smaller than asked." % (test, plen, want))

    # ----- B+
    def test_b(self):
        c = self.cfg
        sys_, hist = self.salt("ops-b"), self.hist["B"]
        self.log("test B+: priming the cache with the %d-token history (one cold write, not throttled)" % c["b_tokens"])
        r, _ = self.send("B", "prime", self.body(list(hist), system=sys_))
        text = r.text
        conds = [None] + list(c["rates"])
        for rep in range(c["b_reps"]):
            for rate in conds:
                kw = {"measure_upload": True}
                if rate:
                    kw["rate_bps"] = rate * 1e6
                tag = "%s" % ("%gMbps" % rate if rate else "open")
                local = list(hist) + [convo.assistant_msg(text), convo.user_msg(1)]
                self.send("B", "resend %s r%d" % (tag, rep + 1), self.body(local, system=sys_), **kw)
                cr, _ = self.send("B", "create %s r%d" % (tag, rep + 1), self.body(list(hist), system=sys_, thread={"type": "create"}), thread=True, **kw)
                if not cr.response_id:
                    raise TestAbort("B", "the thread create returned 200 without a response id; no continue sent")
                self.send("B", "continue %s r%d" % (tag, rep + 1), self.body([convo.user_msg(1)], thread={"type": "continue", "previous_message_id": cr.response_id}),
                          thread=True, **kw)

    # ----- E
    def test_e(self):
        c = self.cfg
        sys_, hist = self.salt("ops-e"), self.hist["E"]
        mt = c["e_max_tokens"]
        ask = {"role": "user", "content": [{"type": "text", "text": E_LONG_ASK}]}
        for run in range(1, c["e_runs"] + 1):
            self.log("test E run %d of %d" % (run, c["e_runs"]))
            cr, _ = self.send("E", "create r%d" % run, self.body(list(hist), system=sys_, thread={"type": "create"}, max_tokens=mt), thread=True)
            if not cr.response_id:
                raise TestAbort("E", "the thread create returned 200 without a response id; no continue sent")
            cont = self.body([ask], thread={"type": "continue", "previous_message_id": cr.response_id}, max_tokens=mt)
            self.send("E", "continue cut r%d" % run, cont, thread=True, abort_after_delta=True)
            again, _ = self.send("E", "same continue r%d" % run, cont, thread=True, need_ok=False)
            self.log("    the same continue came back: %s" % ops_report.outcome(again.status, again.ok, again.error_code))
            self.send("E", "replay create r%d" % run, self.body(list(hist) + [convo.assistant_msg(cr.text), ask], system=sys_, thread={"type": "create"}, max_tokens=mt), thread=True)

    # ----- A
    def test_a(self):
        c = self.cfg
        sys_, n = self.salt("ops-a"), c["a_fork_at"]
        msgs = list(self.hist["A"])
        prefix = text_n = None
        for k in range(c["a_turns"]):
            r, _ = self.send("A", "turn %d" % k, self.body(list(msgs), system=sys_))
            if k == n:
                prefix, text_n = list(msgs), r.text
            msgs = msgs + [convo.assistant_msg(r.text), grow_msg(c["seed"], "main", k + 1)]
        for tag in ("A", "B"):
            fork = prefix + [convo.assistant_msg(text_n), grow_msg(c["seed"], "fork" + tag, n + 1)]
            self.send("A", "fork %s at turn %d" % (tag, n), self.body(fork, system=sys_))

    # ----- output
    def doc(self):
        cfg = {k: v for k, v in self.cfg.items() if k not in ("salt_nonce",)}
        d = {"status": self.status, "started_utc": self.started, "spent_usd": round(self.guard.spent, 6),
             "in_flight_worst_case_usd": round(self.in_flight_at_stop, 6), "requests": self.n_requests,
             "config": cfg, "environment": {"python": platform.python_version(), "os": platform.system()},
             "estimate_usd": round(self.plan["expected"] + self.cfg.get("probe_bound_usd", 0.0), 4),
             "disclaimer": ops_report.DISCLAIMER, "aborts": self.aborts, "notes": self.notes, "records": self.records}
        if self.partial:
            d["partial"] = dict(self.partial, spent_usd=round(self.guard.spent, 6))
        d["analysis"] = ops_report.analyze(d)
        return d

    def flush(self):
        self.flusher(self.outdir, R.redact_obj(self.doc()))

    def run(self):
        """Returns an exit code. Always flushes what it has."""
        code = 0
        try:
            for name, fn in (("B", self.test_b), ("E", self.test_e), ("A", self.test_a)):
                if name not in self.cfg["tests"]:
                    continue
                try:
                    fn()
                except TestAbort as e:
                    self.aborts[name] = e.reason
                    self.log("test %s stopped: %s (the other tests go on)" % (name, e.reason))
            if self.aborts:
                self.status, code = "finished, but not every test completed: %s" % "; ".join("%s: %s" % (k, v) for k, v in sorted(self.aborts.items())), 4
            else:
                self.status = "complete"
        except SpendCap as e:
            self.status, code = "PARTIAL: spend cap (%s)" % e, 3
        except FatalApiError as e:
            self.partial = {"partial": True, "kind": e.kind, "reason": R.redact(e.reason), "stage": self.stage, "retried": False, "resume_with": "not resumable"}
            self.status, code = "PARTIAL: %s error, stopped at once, no retry (%s)" % (e.kind, R.redact(e.reason)), 5 if e.kind == "billing" else 6
        except KeyboardInterrupt:
            self.in_flight_at_stop = self.in_flight
            self.status, code = "PARTIAL: interrupted", 130
        finally:
            self.status = R.redact(self.status)
            try:
                self.flush()
            except Exception as e:
                print("could not write results: %s" % R.redact(e), file=sys.stderr)
            self.client.close()
        extra = " The request on the wire when it stopped may add up to $%.4f." % self.in_flight_at_stop if self.in_flight_at_stop else ""
        self.log("%s. Spent so far $%.4f of a $%.2f cap over %d requests.%s Threads expire on their own; nothing to clean up in your account. This mode cannot be resumed." % (
            self.status, self.guard.spent, self.guard.cap, self.n_requests, extra))
        return code
