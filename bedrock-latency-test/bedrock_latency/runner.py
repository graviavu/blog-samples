"""The run: calibration, probe, then arms A/B/C per model and context size. Spend is checked before and after every request."""
import time

from . import client as C
from . import fill, plan, probe, report
from .pricing import model_key as C_key
from . import redact as R


class Stop(Exception):
    def __init__(self, status, why):
        super().__init__(why)
        self.status, self.why = status, why


CONTEXT_FLOOR = 0.9   # a thread continue must report at least this share of the primed prompt's tokens


def prompt_tokens(usage):
    return sum(usage.get(x, 0) or 0 for x in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))


def usage_complete(usage):
    return isinstance(usage.get("input_tokens"), int) and isinstance(usage.get("output_tokens"), int)


def charge(res, model, bound, prices):
    """Spend to count for one request, and whether the usage was missing. When in doubt, count the worst case:
    - ok with input_tokens and output_tokens: the cost from usage;
    - ok without them: the bound (the request ran, its size is unknown);
    - nothing sent (DNS, connection refused, TLS setup): 0;
    - a stream that started, or any exception after the upload began (read timeout, reset): the bound;
    - a complete HTTP error response: 0 for 4xx/429/503/529 (refused before the model ran), the bound for 500/502/504."""
    if res.ok:
        if not usage_complete(res.usage):
            return bound, True
        return prices.cost(model, res.usage), False
    if not getattr(res, "sent", True):
        return 0.0, False
    if res.stream_started or res.exception or res.status is None or res.status in C.MAYBE_BILLED:
        return bound, False
    return 0.0, False


class Runner:
    def __init__(self, cfg, client, prices, outdir, log, sleep=time.sleep):
        self.cfg, self.client, self.prices, self.outdir, self.log, self.sleep = cfg, client, prices, outdir, log, sleep
        self.records = []
        self.cells = []
        self.probe = None
        self.spent = 0.0
        self.status = "running"
        self.why = None
        self.cpt = {}          # measured chars per token, per model
        self.requests = 0

    # ---- one request with the guard ----
    def send(self, body, beta, kind, model, bound, meta=None):
        cap = self.cfg["max_usd"]
        attempt, cost = 0, 0.0
        while True:
            attempt += 1
            if self.spent + bound > cap:
                raise Stop("stopped_cap", "next request could cross the cap (spent $%.4f + worst case $%.4f > $%.2f)" % (self.spent, bound, cap))
            res = self.client.post(body, beta)
            self.requests += 1
            c, usage_missing = charge(res, model, bound, self.prices)
            self.spent += c
            cost += c
            if not res.ok and res.transient and attempt <= self.cfg["retries"] and self.spent < cap:
                self.log("  transient failure (HTTP %s), retrying once" % res.status)
                self.sleep(2.0 * attempt)
                continue
            break
        rec = {"model": C_key(model), "kind": kind, "http_status": res.status, "ok": res.ok, "ttft_s": res.ttft, "total_s": res.total,
               "first_token_kind": res.first_kind, "usage": dict(res.usage), "cost_usd": round(cost, 6), "attempts": attempt}
        if res.error:
            rec["error"] = res.error
        if res.exception:
            rec["exception"] = res.exception
        if usage_missing:
            rec["usage_missing"] = True
            self.log("    the response had no input_tokens/output_tokens usage; charged its worst case $%.4f" % bound)
        rec.update(meta or {})
        self.records.append(rec)
        if self.spent >= cap:
            raise Stop("stopped_cap", "measured spend $%.4f reached the cap $%.2f" % (self.spent, cap))
        return res

    def body(self, model, messages, cache=False, thread=None):
        b = {"model": model, "max_tokens": self.cfg["max_tokens"], "messages": messages}
        if cache:
            b["cache_control"] = {"type": "ephemeral"}
        if self.cfg["effort"] != "none":
            b["output_config"] = {"effort": self.cfg["effort"]}
        if thread:
            b["thread"] = thread
        return b

    # ---- steps ----
    def calibrate(self, model):
        """One small request per model: measures characters per token for the filler, so the history lands near its target."""
        cpt = self.cfg["chars_per_token"]
        n_chars = int(plan.CAL_TOKENS * cpt)
        msgs = [{"role": "user", "content": fill.text("calibration", n_chars)}]
        b = {"model": model, "max_tokens": 8, "messages": msgs}
        bound = self.prices.bound(model, int(plan.CAL_TOKENS * self.cfg["margin"]) + 100, 8)
        res = self.send(b, None, "calibration", model, bound)
        if res.ok:
            n = sum(res.usage.get(k, 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            if n > 50:
                cpt = n_chars / (n - 15)   # about 15 tokens of framing
        self.cpt[model] = min(max(cpt, 1.0), 8.0)
        self.log("  %s: %.2f characters per token (measured)" % (C_key(model), self.cpt[model]))

    def run_probe(self):
        pm = self.cfg["probe_model"]
        bound = self.prices.bound(pm, plan.PROBE_PROMPT_UB, plan.PROBE_MAX_TOKENS)

        def send(body, beta, kind):
            return self.send(body, beta, kind, pm, bound)
        self.probe = probe.run(send, self.cfg, pm, self.log)
        self.log("PROBE VERDICT: %s  (%s)" % (self.probe["verdict"], self.probe["reason"]))
        return self.probe["verdict"]

    def arm(self, name, model, size):
        cfg, mt = self.cfg, self.cfg["max_tokens"]
        cell = {"model": C_key(model), "size_target": size, "arm": name, "real_prompt_tokens": None}
        salt = "%s-%s-%d-%s" % (cfg["nonce"], C_key(model), size, name)
        transcript = fill.build_history(salt, size, self.cpt.get(model, cfg["chars_per_token"]))
        thread_id = None
        n_req = 1 + cfg["reps"] if name != "A" else cfg["reps"]
        self.cells.append(cell)
        self.log("  arm %s (%s): %d requests" % (name, plan.ARM_NAMES[name], n_req))
        for k in range(1, n_req + 1):
            turn = k if name == "A" else k - 1          # B and C: request 1 is the cache-priming request, turn 0
            q = {"role": "user", "content": fill.question(k)}
            ub = plan.request_ub(size, cfg["margin"], mt, k)
            bound = self.prices.bound(model, ub, mt)
            meta = {"arm": name, "size_target": size, "turn": turn}
            kind = "prime" if (name != "A" and k == 1) else "turn"
            if name == "C" and k > 1:
                res = self.send(self.body(model, [q], True, {"type": "continue", "previous_message_id": thread_id}),
                                C.THREADS_BETA, kind, model, bound, meta)
                if not res.ok:
                    self.log("    thread continue failed (HTTP %s %s); replaying with a full create" % (res.status, (res.error or {}).get("error_code")))
                    res = self.send(self.body(model, transcript + [q], True, {"type": "create"}), C.THREADS_BETA, "replay", model, bound, dict(meta))
            elif name == "C":
                res = self.send(self.body(model, transcript + [q], True, {"type": "create"}), C.THREADS_BETA, kind, model, bound, meta)
            else:
                res = self.send(self.body(model, transcript + [q], name == "B"), None, kind, model, bound, meta)
            if not res.ok:
                self.log("    request failed (HTTP %s); arm stopped" % res.status)
                cell["failed"] = True
                return
            thread_id = res.response_id
            reply = res.text.strip() or "OK."
            transcript += [q, {"role": "assistant", "content": reply}]
            real = prompt_tokens(res.usage)
            if k == 1:
                if not usage_complete(res.usage):
                    raise Stop("stopped_size", "the first request of the cell returned no input_tokens/output_tokens usage, so the prompt "
                               "size and the spend cannot be checked; each such request was charged its worst case")
                cell["real_prompt_tokens"] = real
                if real > size * cfg["margin"] + plan.growth(mt):
                    raise Stop("stopped_size", "the prompt is %d tokens, over target %d x margin %.2f: the cost bound no longer holds"
                               % (real, size, cfg["margin"]))
            elif name == "C" and self.records[-1].get("kind") == "turn":
                # A continue that the endpoint silently ignored would answer from the new message alone and look fast.
                # The prompt it was billed for must be at least the primed history.
                floor = int(CONTEXT_FLOOR * (cell["real_prompt_tokens"] or size))
                if real < floor:
                    self.records[-1]["context_mismatch"] = True
                    cell["context_mismatches"] = cell.get("context_mismatches", 0) + 1
                    self.log("    CONTEXT MISMATCH: the continue reported %d prompt tokens, below %d (the primed history); "
                             "the thread may have been ignored, so this turn is left out of the timings" % (real, floor))

    def run(self, thread_ok=False):
        t0 = time.time()
        try:
            verdict = self.run_probe()
            if not self.probe["baseline"]["ok"]:
                raise Stop("failed_baseline", "the plain request failed, so the endpoint, token, model id or access is wrong; no arms were run")
            thread_ok = verdict == probe.ACCEPTED
            if not thread_ok:
                self.log("Thread arm C skipped: the probe verdict is %s." % verdict)
            if not self.cfg["probe_only"]:
                for m in self.cfg["models"]:
                    self.calibrate(m)
                for m in self.cfg["models"]:
                    for size in self.cfg["sizes"]:
                        self.log("%s at about %d tokens" % (C_key(m), size))
                        for name in plan.ARMS:
                            if name == "C" and not thread_ok:
                                continue
                            self.arm(name, m, size)
            self.status = "complete"
        except Stop as s:
            self.status, self.why = s.status, s.why
            self.log("STOPPED: %s" % s.why)
        except KeyboardInterrupt:
            self.status, self.why = "interrupted", "interrupted by the user"
            self.log("Interrupted; writing partial results.")
        finally:
            report.write(self.outdir, self, time.time() - t0)
        return {"complete": 0, "stopped_cap": 3, "stopped_size": 3, "failed_baseline": 4, "interrupted": 130}.get(self.status, 1)
