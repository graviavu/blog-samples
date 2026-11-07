"""Step 1: does this key accept the message-threads beta? One plain request, one thread create, one thread continue.

Verdicts: ACCEPTED, REJECTED (with the HTTP status and error code), INCONCLUSIVE (with the reason). The probe sends no history,
no cache_control and no tools: four tiny requests at most, well under one cent on the small model."""
import random

from . import client as C
from . import pricing

ACCEPTED, REJECTED, INCONCLUSIVE = "ACCEPTED", "REJECTED", "INCONCLUSIVE"
PROBE_REQUESTS = 4        # plain, plain again without effort if refused, create, continue
PROBE_PROMPT_UB = 400
PROBE_MAX_TOKENS = 256    # thinking counts toward this, so leave room for the codeword after a short thought


def bound(model):
    """Worst-case dollars for the whole probe (every request at the bound, no cache credit)."""
    return PROBE_REQUESTS * pricing.request_upper_bound(model, PROBE_PROMPT_UB, PROBE_MAX_TOKENS)


def _brief(res):
    d = {"http_status": res.status, "ok": res.ok, "error_code": res.error_code}
    if res.error:
        d["error"] = res.error
    if res.exception:
        d["exception"] = res.exception
    if res.ttft is not None:
        d["ttft_ms"] = round(res.ttft * 1000)
    if res.usage:
        d["usage"] = {k: res.usage.get(k, 0) for k in pricing.USAGE_KEYS}
    return d


def _code(res):
    e = res.error.get("error", res.error) if isinstance(res.error, dict) else {}
    etype = e.get("type") if isinstance(e, dict) else None
    return "HTTP %s, type %s, code %s" % (res.status, etype, res.error_code)


def _client_error(res):
    return res.status is not None and 400 <= res.status < 500 and res.status not in (408, 409, 429)


def decide(baseline, create, cont, evidenced):
    """Pure rule set (unit tested). Arguments are Result objects, or None when a step was not reached."""
    if baseline is None or not baseline.ok:
        return INCONCLUSIVE, "the plain request failed (HTTP %s), so the key, the model id or your access has to be fixed first" % (getattr(baseline, "status", None),)
    if create is None:
        return INCONCLUSIVE, "thread create was not sent"
    if not create.ok:
        if _client_error(create):
            return REJECTED, "thread create refused: %s" % _code(create)
        return INCONCLUSIVE, "thread create did not complete (HTTP %s); a transient or network failure says nothing about access" % create.status
    if cont is None:
        return INCONCLUSIVE, "create returned 200 but gave no response id to continue from"
    if not cont.ok:
        if _client_error(cont):
            if str(cont.error_code or "").startswith("thread_"):
                return INCONCLUSIVE, "continue got a thread-specific error (%s): threads are recognized but the continue was not usable" % cont.error_code
            return REJECTED, "thread continue refused: %s" % _code(cont)
        return INCONCLUSIVE, "thread continue did not complete (HTTP %s)" % cont.status
    if not evidenced:
        return INCONCLUSIVE, "continue returned 200 but the reply did not show the context sent only in the create (the thread field may have been ignored, or the reply was cut before the codeword)"
    return ACCEPTED, "create and continue returned 200 and the continue reply used context sent only in the create"


def _body(model, text, effort, thread=None):
    b = {"model": model, "max_tokens": PROBE_MAX_TOKENS, "stream": True, "messages": [{"role": "user", "content": text}]}
    if effort != "none":
        b["output_config"] = {"effort": effort}
    if thread:
        b["thread"] = thread
    return b


def run(client, guard, model, effort, log, rec=None):
    """Returns the probe record (also what goes to probe.json). guard: a runner.Guard shared with the run.
    rec: optional dict filled in place, so the caller can write the partial record if this is interrupted."""
    if rec is None:
        rec = {}
    per_request = pricing.request_upper_bound(model, PROBE_PROMPT_UB, PROBE_MAX_TOKENS)

    def send(body, thread, label):
        guard.check(per_request)
        rec["in_flight_worst_case_usd"] = round(per_request, 6)   # on the wire until the response is charged
        res = client.post(body, thread=thread)
        rec["in_flight_worst_case_usd"] = 0.0
        parts = pricing.cost(model, res.usage) if res.usage else {"total": 0.0}
        charged = parts["total"]
        if (res.status == 200 and not res.usage) or (res.status == 200 and not res.complete) or (res.status is None and res.exception):
            charged = max(charged, per_request)   # unknown billing for a cut stream: charge the bound
        guard.add(charged)
        log("  probe %-9s status %s%s cost $%.5f" % (label, res.status if res.status else "ERR",
                                                     (" " + str(res.error_code)) if res.error_code else "", charged))
        return res

    word = "PELICAN-%d" % random.SystemRandom().randint(1000, 9999)
    rec.update({"model": model, "effort_used": effort, "verdict": "INTERRUPTED", "reason": "stopped before the probe finished"})
    baseline = send(_body(model, "Reply with the single word OK.", effort), False, "plain")
    if not baseline.ok and effort != "none" and _client_error(baseline) and baseline.status not in (401, 403):
        rec["effort_rejected"] = _brief(baseline)
        log("probe: the plain request was refused with output_config.effort=%s (%s); retrying without it" % (effort, _code(baseline)))
        effort = "none"
        rec["effort_used"] = "none"
        baseline = send(_body(model, "Reply with the single word OK.", effort), False, "plain")
    rec["baseline"] = _brief(baseline)
    create = cont = None
    evidenced = False
    if baseline.ok:
        create = send(_body(model, "Remember this codeword: %s. Reply with the single word OK." % word, effort, {"type": "create"}), True, "create")
        rec["create"] = _brief(create)
        if create.ok and create.response_id:
            cont = send(_body(model, "What is the codeword? Reply with the codeword only.", effort,
                              {"type": "continue", "previous_message_id": create.response_id}), True, "continue")
            rec["continue"] = _brief(cont)
            evidenced = bool(cont.ok and word.lower() in cont.text.lower())
    rec["verdict"], rec["reason"] = decide(baseline, create, cont, evidenced)
    rec["spent_usd"] = round(guard.spent, 6)
    return rec
