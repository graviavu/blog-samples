"""--tune: three experiments on one timeline (waits overlap), Haiku 5.5 by default.

1 WARM-CACHE RELOAD  a 100K-token prefix is written to a 1-hour cache entry by a normal request; a thread is created from the same
                     history at t0; after more than 5 minutes idle a continue must return 404 (the check); then the same prefix is sent
                     as a new thread create with the same cache_control. Did the replay read the 1-hour cache? A cold reload (fresh salt,
                     the arm 4 request) is the comparison.
2 KEEP-ALIVE         a thread is created at t0, a tiny continue goes out at about t0+4 min, a real continue at about t0+8 min.
3 GROWTH             15 turns in one thread against 15 turns of cached full resend, from a 20K history.

Every experiment has its own prefix salt, so none shares cache with another. No automatic replays: a continue that fails is a result.
Not resumable (the timeline is the point); a PARTIAL tune.json / tune.md is written after every request."""
import json
import platform
import sys
import time

from . import convo, pricing, report, tune_report
from .client import FatalApiError
from . import redact as R
from .runner import Guard, SpendCap, RunAbort

KEEPALIVE_TEXT = "ping, reply OK"
COUNTDOWN_EVERY = 10.0


class ExpAbort(Exception):
    """One experiment cannot go on; the others still run."""

    def __init__(self, exp, reason):
        super().__init__(reason)
        self.exp, self.reason = exp, reason


def request_ub(model, tokens, margin, turns, max_tokens, ttl1h=False):
    p = pricing.prompt_upper_bound(tokens, margin, turns, max_tokens)
    return pricing.request_upper_bound(model, p, max_tokens, write_1h=ttl1h), p


def plan(model, big, small, margin, turns, max_tokens, retries):
    """Planned upper bound of the three experiments, without the probe. Every request is bounded at the dearer of input and
    cache-write price (1-hour writes at 2x input) with no cache-read credit, every reply at max_tokens, every request attempted
    1 + retries times. Experiment 1 includes its replay, its 404 check (bounded as if it succeeded) and the cold reload; the
    prompt tier is chosen from the upper-bound prompt, so a 100K history is priced on the dearer side of Haiku's 100,000-token step."""
    att = 1 + retries
    big1h, pb = request_ub(model, big, margin, 1, max_tokens, True)
    bigcold, _ = request_ub(model, big, margin, 1, max_tokens, False)
    smallr, ps = request_ub(model, small, margin, 1, max_tokens, False)
    growth, pg = request_ub(model, small, margin, turns + 1, max_tokens, False)
    e1 = {"requests": ["prime (1h write)", "thread create (1h)", "continue check (bounded as if it succeeded)", "replay create (1h)", "cold reload (5m write)"],
          "bound": att * (4 * big1h + bigcold), "per_request_1h": big1h, "per_request_cold": bigcold, "prompt_tokens_ub": pb}
    e2 = {"requests": ["create", "keep-alive continue", "real continue"], "bound": att * 3 * smallr, "per_request": smallr, "prompt_tokens_ub": ps}
    e3 = {"requests": ["%d resend (1 prime + %d turns)" % (turns + 1, turns), "%d thread (1 create + %d continues)" % (turns + 1, turns)],
          "bound": att * 2 * (turns + 1) * growth, "per_request": growth, "prompt_tokens_ub": pg}
    return {"e1": e1, "e2": e2, "e3": e3, "total": e1["bound"] + e2["bound"] + e3["bound"], "attempts_per_request": att}


class Tune:
    def __init__(self, cfg, client, outdir, log=print, sleep=time.sleep, clock=time.monotonic, guard=None):
        self.cfg, self.client, self.outdir, self._log, self.sleep, self.clock = cfg, client, outdir, log, sleep, clock
        self.guard = guard or Guard(cfg["max_usd"])
        self.records = []
        self.events = []          # {"name", "planned_s", "actual_s"}
        self.aborts = {}          # exp -> reason
        self.notes = []
        self.status = "running"
        self.started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.n_requests = 0
        self.in_flight = 0.0
        self.in_flight_at_stop = 0.0
        self.stage = None
        self.partial = None
        self.t0 = None
        self.clock0 = clock()
        self.big_hist = convo.build_history(cfg["seed"], cfg["big"], cfg["cpt_big"])
        self.small_hist = convo.build_history(cfg["seed"], cfg["small"], cfg["cpt_small"])
        self.state = {}           # response ids and texts of the live threads (memory only, never written)
        self.plan = plan(cfg["model"], cfg["big"], cfg["small"], cfg["margin"], cfg["turns"], cfg["max_tokens"], cfg["retries"])

    def log(self, msg):
        self._log(R.redact(msg))

    # ----- plumbing
    def now(self):
        return self.clock() - self.clock0

    def salt(self, name):
        return convo.system_text(convo.make_salt(self.cfg["seed"], name, 0, self.cfg["salt_nonce"]))

    def body(self, messages, system=None, ttl=None, thread=None, max_tokens=None):
        c = self.cfg
        b = {"model": c["model"], "max_tokens": max_tokens or c["max_tokens"], "stream": True, "messages": messages, "tool_choice": convo.TOOL_CHOICE}
        if c["effort"] != "none":
            b["output_config"] = {"effort": c["effort"]}
        if system is not None:
            b["system"] = system
            b["tools"] = convo.TOOLS
        b["cache_control"] = {"type": "ephemeral", "ttl": "1h"} if ttl == "1h" else {"type": "ephemeral"}
        if thread:
            b["thread"] = thread
        return b

    def send(self, exp, label, turn, body, ub, thread=False, allow=()):
        """One request with the guard, the usage-based charge, a flush, and the retry rule of the main run. Returns (Result, record)."""
        c = self.cfg
        asked_1h = body.get("cache_control", {}).get("ttl") == "1h"
        attempt = 0
        while True:
            attempt += 1
            body_ub = pricing.request_upper_bound(c["model"], len(json.dumps(body)) // 2 + 1000, body["max_tokens"], write_1h=asked_1h)
            projected = max(ub, body_ub)
            self.stage = {"tokens": None, "arm": exp, "rep": label, "turn": turn, "kind": label, "attempt": attempt}
            self.guard.check(projected)
            self.in_flight = projected
            t_start = self.now()
            res = self.client.post(body, thread=thread)
            t_end = self.now()
            self.in_flight = 0.0
            self.n_requests += 1
            cc1h = res.cache_creation.get("ephemeral_1h_input_tokens") if res.cache_creation else None
            parts = pricing.cost_ttl(c["model"], res.usage, cc1h, asked_1h) if res.usage else {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0, "total": 0.0}
            charged = parts["total"]
            if (res.status == 200 and not res.usage) or (res.status == 200 and not res.complete) or (res.status is None and res.exception):
                charged = max(charged, projected)
            rec = {"exp": exp, "label": label, "turn": turn, "attempt": attempt, "status": res.status, "complete": res.complete,
                   "error_code": res.error_code, "ttft_ms": None if res.ttft is None else res.ttft * 1000,
                   "total_ms": None if res.total is None else res.total * 1000, "first_kind": res.first_kind, "stop_reason": res.stop_reason,
                   "usage": {k: res.usage.get(k, 0) for k in pricing.USAGE_KEYS}, "cache_creation_1h_reported": cc1h,
                   "asked_1h": asked_1h, "cost": parts, "charged_usd": charged, "t_start_s": round(t_start, 3), "t_end_s": round(t_end, 3)}
            if res.error:
                rec["error"] = res.error
            if res.exception:
                rec["exception"] = res.exception
            self.records.append(rec)
            self.log("  %s %-18s turn %-2s status %s ttft %s cost $%.4f spent $%.4f" % (
                exp, label, turn, res.status if res.status else "ERR",
                "%.0fms" % rec["ttft_ms"] if rec["ttft_ms"] is not None else "-", charged, self.guard.spent + charged))
            try:
                self.guard.add(charged)
            finally:
                self.flush()
            fatal = res.fatal()
            if fatal:
                raise FatalApiError(*fatal)
            if res.ok or res.status in allow:
                return res, rec
            if res.transient and attempt <= c["retries"]:
                self.sleep(min(2.0, 0.5 * attempt))
                continue
            raise ExpAbort(exp, "request %s failed with %s %s: %s" % (label, res.status, res.error_code or "", res.error or res.exception))

    def ub_for(self, which):
        return self.plan[which]["per_request_1h"] if which == "e1" else self.plan[which]["per_request"]

    # ----- timeline
    def wait_until(self, offset, what):
        """Sleep until t0 + offset with a countdown line every few seconds. Ctrl-C passes through to run()."""
        while True:
            left = self.t0 + offset - self.now()
            if left <= 0:
                return
            self.log("  waiting %.0f s until %s (spent $%.4f of $%.2f; Ctrl-C keeps the results so far)" % (left, what, self.guard.spent, self.guard.cap))
            self.sleep(min(left, COUNTDOWN_EVERY))

    def event(self, name, planned):
        self.events.append({"name": name, "planned_s": planned, "actual_s": round(self.now() - self.t0, 2)})

    def setup(self):
        """Before t0: the experiment 1 prime, a normal request that writes the 1-hour entry."""
        c = self.cfg
        self.log("experiment 1: priming the 1-hour cache entry (a normal request, %d-token history)" % c["big"])
        try:
            res, _ = self.send("e1", "prime", 0, self.body(list(self.big_hist), system=self.salt("tune-e1"), ttl="1h"), self.ub_for("e1"))
        except ExpAbort as e:
            self.aborts["e1"] = e.reason

    def e1_create(self):
        if "e1" in self.aborts:
            return
        res, _ = self.send("e1", "thread_create", 0, self.body(list(self.big_hist), system=self.salt("tune-e1"), ttl="1h", thread={"type": "create"}),
                           self.ub_for("e1"), thread=True)
        self.state["e1_id"] = res.response_id

    def e1_check(self):
        res, _ = self.send("e1", "continue_check", 1, self.body([convo.user_msg(1)], ttl="1h", thread={"type": "continue", "previous_message_id": self.state["e1_id"]}),
                           self.ub_for("e1"), thread=True, allow=(400, 404))

    def e1_replay(self):
        self.send("e1", "replay", 2, self.body(list(self.big_hist), system=self.salt("tune-e1"), ttl="1h", thread={"type": "create"}), self.ub_for("e1"), thread=True)

    def e1_cold(self):
        """The existing cold reload (arm 4 shape): a fresh salt and the default 5-minute cache_control."""
        ub = self.plan["e1"]["per_request_cold"]
        self.send("e1", "cold_reload", 3, self.body(list(self.big_hist), system=self.salt("tune-e1-cold"), thread={"type": "create"}), ub, thread=True)

    def e2_create(self):
        res, _ = self.send("e2", "thread_create", 0, self.body(list(self.small_hist), system=self.salt("tune-e2"), thread={"type": "create"}), self.ub_for("e2"), thread=True)
        self.state["e2_id"] = res.response_id

    def e2_keepalive(self):
        mt = min(32, self.cfg["max_tokens"])
        res, rec = self.send("e2", "keepalive", 1, self.body([{"role": "user", "content": KEEPALIVE_TEXT}], thread={"type": "continue", "previous_message_id": self.state["e2_id"]}, max_tokens=mt),
                             self.ub_for("e2"), thread=True, allow=(400, 404))
        self.state["ka_ok"] = bool(res.ok and res.response_id)
        if self.state["ka_ok"]:
            self.state["e2_id"] = res.response_id

    def e2_real(self):
        if not self.state.get("ka_ok"):
            self.notes.append("Experiment 2: the keep-alive did not succeed, so the real continue was not sent (nothing to learn from it).")
            self.log("experiment 2: the keep-alive did not succeed; the real continue is skipped")
            return
        self.send("e2", "real_continue", 2, self.body([convo.user_msg(2)], thread={"type": "continue", "previous_message_id": self.state["e2_id"]}),
                  self.ub_for("e2"), thread=True, allow=(400, 404))

    def exp3(self):
        """A generator: one request per step, so the timed events of the other experiments can run between its requests."""
        c = self.cfg
        ub = self.ub_for("e3")
        hist = self.small_hist
        sr, st = self.salt("tune-e3-resend"), self.salt("tune-e3-thread")
        msgs = list(hist)
        r0, _ = self.send("e3", "resend", 0, self.body(msgs, system=sr), ub)
        rtext = r0.text
        yield
        t0r, _ = self.send("e3", "thread", 0, self.body(list(hist), system=st, thread={"type": "create"}), ub, thread=True)
        prev, ttext = t0r.response_id, t0r.text
        yield
        for k in range(1, c["turns"] + 1):
            msgs = msgs + [convo.assistant_msg(rtext), convo.user_msg(k)]

            def resend():
                return self.send("e3", "resend", k, self.body(msgs, system=sr), ub)[0]

            def thread():
                return self.send("e3", "thread", k, self.body([convo.user_msg(k)], thread={"type": "continue", "previous_message_id": prev}), ub, thread=True)[0]
            order = ("resend", "thread") if k % 2 else ("thread", "resend")   # alternate who goes first, to spread drift
            for which in order:
                if which == "resend":
                    rtext = resend().text
                else:
                    r = thread()
                    prev, ttext = r.response_id, r.text
                yield

    def timed_events(self):
        c = self.cfg
        ev = []
        if "e1" not in self.aborts:
            ev += [("e1_check", c["expiry_at"], "e1", self.e1_check), ("e1_replay", c["expiry_at"], "e1", self.e1_replay),
                   ("e1_cold", c["expiry_at"], "e1", self.e1_cold)]
        ev += [("e2_keepalive", c["keepalive_at"], "e2", self.e2_keepalive), ("e2_real", c["final_at"], "e2", self.e2_real)]
        return sorted(ev, key=lambda e: e[1])

    def run_step(self, name, planned, exp, fn):
        if exp in self.aborts:
            return
        self.event(name, planned)
        try:
            fn()
        except ExpAbort as e:
            self.aborts[exp] = e.reason
            self.log("experiment %s stopped: %s (the other experiments go on)" % (exp[1], e.reason))

    def timeline(self):
        pending = self.timed_events()
        self.t0 = self.now()
        self.log("t0 reached: the threads of experiments 1 and 2 are created now; experiment 3 runs while they wait")
        self.run_step("e1_create", 0.0, "e1", self.e1_create)
        self.run_step("e2_create", 0.0, "e2", self.e2_create)
        filler = self.exp3()
        while pending or filler is not None:
            if pending and self.now() - self.t0 >= pending[0][1]:
                name, planned, exp, fn = pending.pop(0)
                self.run_step(name, planned, exp, fn)
                continue
            if filler is not None:
                try:
                    next(filler)
                except StopIteration:
                    filler = None
                except ExpAbort as e:
                    self.aborts["e3"] = e.reason
                    self.log("experiment 3 stopped: %s (the others go on)" % e.reason)
                    filler = None
                continue
            self.wait_until(pending[0][1], pending[0][0])

    # ----- output
    def doc(self):
        cfg = {k: v for k, v in self.cfg.items() if k not in ("salt_nonce",)}
        d = {"status": self.status, "started_utc": self.started, "spent_usd": round(self.guard.spent, 6),
             "in_flight_worst_case_usd": round(self.in_flight_at_stop, 6), "requests": self.n_requests,
             "config": cfg, "environment": {"python": platform.python_version(), "os": platform.system()},
             "planned_upper_bound_usd": round(self.plan["total"] + self.cfg.get("probe_bound_usd", 0.0), 4),
             "disclaimer": report.DISCLAIMER, "events": self.events, "aborts": self.aborts, "notes": self.notes, "records": self.records}
        if self.partial:
            d["partial"] = dict(self.partial, spent_usd=round(self.guard.spent, 6))
        d["analysis"] = tune_report.analyze(d)
        return d

    def flush(self):
        doc = R.redact_obj(self.doc())
        report.write_text(self.outdir, "tune.json", json.dumps(doc, indent=2, sort_keys=True) + "\n")
        report.write_text(self.outdir, "tune.md", tune_report.render_md(doc))

    def run(self):
        """Returns an exit code. Always flushes what it has."""
        code = 0
        try:
            self.setup()
            self.timeline()
            if self.aborts:
                self.status, code = "finished, but not every experiment completed: %s" % "; ".join("%s: %s" % (k, v) for k, v in sorted(self.aborts.items())), 4
            else:
                self.status = "complete"
        except SpendCap as e:
            self.status, code = "PARTIAL: spend cap (%s)" % e, 3
        except FatalApiError as e:
            self.partial = {"partial": True, "kind": e.kind, "reason": R.redact(e.reason), "stage": self.stage, "retried": False, "resume_with": "not resumable"}
            self.status, code = "PARTIAL: %s error, stopped at once, no retry (%s)" % (e.kind, R.redact(e.reason)), 5 if e.kind == "billing" else 6
        except RunAbort as e:
            self.status, code = "PARTIAL: aborted: %s" % e, 4
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
