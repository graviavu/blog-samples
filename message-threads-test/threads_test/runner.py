"""The four arms, the behaviour checks, the spend guard. Sequential, interleaved by repetition."""
import platform
import sys
import time

from . import convo, pricing, report
from . import redact as R

BOGUS_ID = "msg_" + "0" * 24
REPLAY_CODES = ("thread_not_found", "thread_already_continued", "thread_continue_in_flight")


class SpendCap(Exception):
    pass


class RunAbort(Exception):
    pass


class Guard:
    def __init__(self, cap):
        self.cap = float(cap)
        self.spent = 0.0

    def check(self, projected):
        if self.spent + projected > self.cap + 1e-12:
            raise SpendCap("next request could cost up to $%.4f; spent $%.4f of the $%.2f cap" % (projected, self.spent, self.cap))

    def add(self, amount):
        self.spent += amount
        if self.spent > self.cap + 1e-12:
            raise SpendCap("spent $%.4f, over the $%.2f cap" % (self.spent, self.cap))


class Runner:
    def __init__(self, cfg, client, outdir, log=print, sleep=time.sleep, guard=None):
        self.cfg, self.client, self.outdir, self._log, self.sleep = cfg, client, outdir, log, sleep
        self.guard = guard or Guard(cfg["max_usd"])   # one guard can be shared by the runs of several sizes
        self.records = []
        self.checks = {}
        self.notes = []
        self.status = "running"
        self.started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.calibrated = False
        self.history = convo.build_history(cfg["seed"], cfg["tokens"], cfg["chars_per_token"])
        self.n_requests = 0
        self.in_flight = 0.0
        self.in_flight_at_stop = 0.0

    def log(self, msg):
        self._log(R.redact(msg))

    # ----- request plumbing
    def body(self, messages, system=None, cache=False, thread=None):
        c = self.cfg
        b = {"model": c["model"], "max_tokens": c["max_tokens"], "stream": True, "messages": messages, "tool_choice": convo.TOOL_CHOICE}
        if c["effort"] != "none":
            b["output_config"] = {"effort": c["effort"]}
        if system is not None:
            b["system"] = system
            b["tools"] = convo.TOOLS
        if cache:
            b["cache_control"] = {"type": "ephemeral"}
        if thread:
            b["thread"] = thread
        return b

    def ub(self, small):
        c = self.cfg
        tokens = c["small_tokens"] if small else c["tokens"]
        p = pricing.prompt_upper_bound(tokens, c["margin"], max(c["turns"], c["nocache_turns"]), c["max_tokens"])
        return pricing.request_upper_bound(c["model"], p, c["max_tokens"])

    def send(self, arm, rep, turn, kind, body, thread=False, allow=(), small=False):
        c = self.cfg
        attempt = 0
        while True:
            attempt += 1
            projected = self.ub(small)
            self.guard.check(projected)
            self.in_flight = projected   # worst case of the request on the wire, known before it is sent
            res = self.client.post(body, thread=thread)
            self.in_flight = 0.0
            self.n_requests += 1
            parts = pricing.cost(c["model"], res.usage) if res.usage else {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0, "total": 0.0}
            charged = parts["total"]
            if (res.status == 200 and not res.complete) or (res.status is None and res.exception):
                charged = max(charged, projected)  # unknown billing for a cut stream: charge the bound
            rec = {"arm": arm, "rep": rep, "turn": turn, "kind": kind, "attempt": attempt, "status": res.status,
                   "complete": res.complete, "error_code": res.error_code,
                   "ttft_ms": None if res.ttft is None else res.ttft * 1000, "total_ms": None if res.total is None else res.total * 1000,
                   "first_kind": res.first_kind, "stop_reason": res.stop_reason,
                   "usage": {k: res.usage.get(k, 0) for k in pricing.USAGE_KEYS}, "cost": parts, "charged_usd": charged}
            if res.error:
                rec["error"] = res.error
            if res.exception:
                rec["exception"] = res.exception
            self.records.append(rec)
            self.log("  arm %s rep %s turn %s %-17s status %s ttft %s total %s cost $%.4f spent $%.4f" % (
                arm, rep, turn, kind, res.status if res.status else "ERR",
                "%.0fms" % rec["ttft_ms"] if rec["ttft_ms"] is not None else "-",
                "%.0fms" % rec["total_ms"] if rec["total_ms"] is not None else "-", charged, self.guard.spent + charged))
            self.guard.add(charged)
            if res.ok and not self.calibrated and not small:
                self.calibrate(res)
            if res.ok or res.status in allow:
                return res
            if res.transient and attempt <= c["retries"]:
                self.sleep(min(2.0, 0.5 * attempt))
                continue
            if res.status in (400, 401, 403, 404, 413, 422) or res.status is None or res.transient:
                raise RunAbort("request failed with %s %s: %s" % (res.status, res.error_code or "", res.error or res.exception))
            raise RunAbort("unexpected result status %s" % res.status)

    def calibrate(self, res):
        self.calibrated = True
        plen = pricing.prompt_len(res.usage)
        want, margin = self.cfg["tokens"], self.cfg.get("calibration_margin", self.cfg["margin"])
        if plen > want * margin:
            raise RunAbort("prompt is %d tokens for --tokens %d (margin %.2f): the cost bound no longer holds. Lower --chars-per-token or --tokens and re-run (dry-run first)." % (plen, want, margin))
        if plen < want * 0.7:
            self.notes.append("Actual prompt was %d tokens against --tokens %d requested; the history is smaller than asked. Lower --chars-per-token to grow it." % (plen, want))
        self.actual_prompt_tokens = plen

    # ----- units
    def system(self, arm, rep):
        return convo.system_text(convo.make_salt(self.cfg["seed"], arm, rep, self.cfg["salt_nonce"]))

    def unit_nocache(self, rep):
        msgs, sys_ = list(self.history), self.system(1, rep)
        for k in range(self.cfg["nocache_turns"]):
            res = self.send(1, rep, k, "turn", self.body(msgs, system=sys_))
            msgs = msgs + [convo.assistant_msg(res.text), convo.user_msg(k + 1)]

    def unit_cache(self, rep):
        msgs, sys_ = list(self.history), self.system(2, rep)
        for k in range(self.cfg["turns"] + 1):
            res = self.send(2, rep, k, "prime" if k == 0 else "turn", self.body(msgs, system=sys_, cache=True))
            msgs = msgs + [convo.assistant_msg(res.text), convo.user_msg(k + 1)]

    def unit_thread(self, rep):
        sys_ = self.system(3, rep)
        local = list(self.history)
        res = self.send(3, rep, 0, "create", self.body(local, system=sys_, cache=True, thread={"type": "create"}), thread=True)
        prev, text = res.response_id, res.text
        for k in range(1, self.cfg["turns"] + 1):
            local = local + [convo.assistant_msg(text), convo.user_msg(k)]
            cont = self.body([convo.user_msg(k)], cache=True, thread={"type": "continue", "previous_message_id": prev})
            res = self.send(3, rep, k, "turn", cont, thread=True, allow=(400, 404))
            if not res.ok:
                if res.status in (400, 404) and res.error_code not in REPLAY_CODES:
                    raise RunAbort("continue rejected with %s %s: %s" % (res.status, res.error_code, res.error))
                self.log("  thread could not continue (%s %s): replaying the full history with a create" % (res.status, res.error_code))
                res = self.send(3, rep, k, "replay", self.body(local, system=sys_, cache=True, thread={"type": "create"}), thread=True)
            prev, text = res.response_id, res.text

    def unit_reload(self, rep):
        self.send(4, rep, 0, "reload", self.body(list(self.history), system=self.system(4, rep), cache=True, thread={"type": "create"}), thread=True)

    def run_units(self):
        c = self.cfg
        arms = {1: (c["nocache_reps"], self.unit_nocache), 2: (c["reps"], self.unit_cache),
                3: (c["reps"], self.unit_thread), 4: (c["reload_reps"], self.unit_reload)}
        for rep in range(max(n for n, _ in arms.values())):
            order = [1, 2, 3, 4]
            order = order[rep % 4:] + order[:rep % 4]  # rotate the order each repetition to spread drift
            for arm in order:
                n, fn = arms[arm]
                if rep < n:
                    self.log("arm %d, repetition %d" % (arm, rep + 1))
                    fn(rep)
                    self.flush()

    # ----- behaviour checks
    def run_checks(self):
        c = self.cfg
        sys_ = self.system("check", 0)
        bogus = self.body([convo.user_msg(1)], cache=True, thread={"type": "continue", "previous_message_id": BOGUS_ID})
        r404 = self.send("check", 0, 0, "bogus_continue", bogus, thread=True, allow=(400, 404))
        self.checks["a_bogus_id_404_and_replay"] = {
            "status": r404.status, "error_code": r404.error_code, "body": r404.error,
            "result": "pending"}
        replay = self.send("check", 0, 0, "reload_after_404", self.body(list(self.history), system=sys_, cache=True, thread={"type": "create"}), thread=True)
        a = self.checks["a_bogus_id_404_and_replay"]
        a["replay_status"], a["replay_has_text"] = replay.status, bool(replay.text.strip())
        a["replay_ttft_ms"] = None if replay.ttft is None else round(replay.ttft * 1000)
        a["result"] = "PASS: 404 thread_not_found, replay create answered" if (r404.status == 404 and r404.error_code == "thread_not_found" and replay.ok and replay.text.strip()) \
            else "DIFFERENT FROM DOCS: see status, error_code and body"
        cont = self.send("check", 0, 1, "check_continue", self.body([convo.user_msg(1)], cache=True, thread={"type": "continue", "previous_message_id": replay.response_id}), thread=True, allow=(400, 404))
        again = self.send("check", 0, 1, "check_double_continue", self.body([convo.user_msg(1)], cache=True, thread={"type": "continue", "previous_message_id": replay.response_id}), thread=True, allow=(400, 404))
        self.checks["b_continue_same_id_twice"] = {
            "first_status": cont.status, "status": again.status, "error_code": again.error_code, "body": again.error,
            "result": "PASS: second continue refused with 400 thread_already_continued" if (cont.ok and again.status == 400 and again.error_code == "thread_already_continued")
            else "DIFFERENT FROM DOCS: see statuses and body"}
        self.flush()
        if c["expiry_test"]:
            self.run_expiry()

    def run_expiry(self):
        c = self.cfg
        small = convo.small_history(c["seed"])
        sys_ = self.system("expiry", 0)
        first = self.send("check", 0, 0, "expiry_create", self.body(small, system=sys_, cache=True, thread={"type": "create"}), thread=True, small=True)
        self.checks["c_expiry_after_idle"] = {"result": "waiting", "idle_seconds": c["expiry_wait"]}
        self.flush()
        self.log("expiry test: idle for %d seconds (Ctrl-C keeps the results so far)" % c["expiry_wait"])
        waited = 0
        while waited < c["expiry_wait"]:
            step = min(30, c["expiry_wait"] - waited)
            self.sleep(step)
            waited += step
        cont = self.send("check", 0, 1, "expiry_continue", self.body([convo.user_msg(1)], cache=True, thread={"type": "continue", "previous_message_id": first.response_id}), thread=True, allow=(400, 404), small=True)
        self.checks["c_expiry_after_idle"].update({
            "status": cont.status, "error_code": cont.error_code, "body": cont.error,
            "result": ("404 thread_not_found: the thread expired after %d s idle" % c["expiry_wait"]) if cont.status == 404
            else ("the thread was still alive after %d s idle (status %s); expiry is best effort" % (c["expiry_wait"], cont.status))})

    # ----- output
    def doc(self):
        cfg = {k: v for k, v in self.cfg.items() if k not in ("salt_nonce",)}
        return {"status": self.status, "started_utc": self.started, "spent_usd": round(self.guard.spent, 6), "in_flight_worst_case_usd": round(self.in_flight_at_stop, 6), "requests": self.n_requests,
                "config": cfg, "environment": {"python": platform.python_version(), "os": platform.system()},
                "disclaimer": report.DISCLAIMER, "summary": report.summarize(self.records), "checks": self.checks,
                "notes": self.notes, "records": self.records}

    def flush(self):
        report.write_outputs(self.outdir, R.redact_obj(self.doc()))

    def run(self):
        """Returns an exit code. Always flushes what it has."""
        code = 0
        try:
            self.run_units()
            if self.cfg["checks"]:
                self.run_checks()
            self.status = "complete"
        except SpendCap as e:
            self.status, code = "aborted: spend cap (%s)" % e, 3
        except RunAbort as e:
            self.status, code = "aborted: %s" % e, 4
        except KeyboardInterrupt:
            self.in_flight_at_stop = self.in_flight
            self.status, code = "interrupted", 130
        finally:
            self.status = R.redact(self.status)
            try:
                self.flush()
            except Exception as e:  # keep going: report the spend even if the write fails
                print("could not write results: %s" % R.redact(e), file=sys.stderr)
            self.client.close()
        extra = " The request on the wire when it stopped may add up to $%.4f." % self.in_flight_at_stop if self.in_flight_at_stop else ""
        self.log("%s. Spent so far $%.4f of a $%.2f cap over %d requests.%s Threads expire on their own (5 minutes idle, 1 hour at most); nothing to clean up in your account." % (
            self.status, self.guard.spent, self.guard.cap, self.n_requests, extra))
        return code
