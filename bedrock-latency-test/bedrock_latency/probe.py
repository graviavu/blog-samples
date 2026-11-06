"""Step 1: does this endpoint accept Anthropic message threads? One plain request, one create, one continue.

Verdicts: ACCEPTED, REJECTED (with the code), INCONCLUSIVE (with the reason). Support for threads on Bedrock is UNKNOWN to this
sample until the verdict says otherwise."""
import random

from . import client as C
from . import plan

ACCEPTED, REJECTED, INCONCLUSIVE = "ACCEPTED", "REJECTED", "INCONCLUSIVE"


def _brief(res):
    """Sanitized outcome of one request: status plus the error code/type verbatim. No ids, no bodies beyond a short message."""
    d = {"http_status": res.status, "ok": res.ok}
    if res.error:
        d["error"] = res.error
    if res.exception:
        d["exception"] = res.exception
    if res.ok:
        d["usage"] = dict(res.usage)
    return d


def _body(model, text, cfg, thread=None):
    b = {"model": model, "max_tokens": plan.PROBE_MAX_TOKENS, "messages": [{"role": "user", "content": text}]}
    if cfg.get("effort") not in (None, "none"):
        b["output_config"] = {"effort": cfg["effort"]}
    if thread:
        b["thread"] = thread
    return b


def decide(baseline, create, cont, evidenced):
    """Pure rule set, tested on its own. Arguments are Result-like objects (or None when a step was not reached)."""
    if baseline is None or not baseline.ok:
        why = "the plain request failed (HTTP %s), so auth, endpoint, model id or access has to be fixed first" % (getattr(baseline, "status", None),)
        return INCONCLUSIVE, why
    if create is None:
        return INCONCLUSIVE, "thread create was not sent"
    if not create.ok:
        if create.status is not None and 400 <= create.status < 500 and create.status not in (408, 429):
            return REJECTED, "thread create refused: %s" % _code(create)
        return INCONCLUSIVE, "thread create did not complete (HTTP %s); a transient or network failure says nothing about support" % create.status
    if cont is None:
        return INCONCLUSIVE, "create returned 200 but gave no response id to continue from"
    if not cont.ok:
        code = (cont.error or {}).get("error_code") or ""
        if cont.status is not None and 400 <= cont.status < 500 and cont.status not in (408, 429):
            if str(code).startswith("thread_"):
                return INCONCLUSIVE, "continue got a thread-specific error (%s), so threads are recognized but the continue was not usable" % code
            return REJECTED, "thread continue refused: %s" % _code(cont)
        return INCONCLUSIVE, "thread continue did not complete (HTTP %s)" % cont.status
    if not evidenced:
        return INCONCLUSIVE, "continue returned 200 but the reply did not show the create-request context (the thread field may have been ignored)"
    return ACCEPTED, "create and continue returned 200 and the continue reply used context sent only in the create"


def _code(res):
    e = res.error or {}
    return "HTTP %s, type %s, code %s" % (res.status, e.get("error_type"), e.get("error_code"))


def run(send, cfg, model, log):
    """send(body, beta, kind) -> Result. Returns the probe record (also what goes to results.json)."""
    word = "PELICAN-%d" % random.SystemRandom().randint(1000, 9999)
    rec = {"model": model, "effort_used": cfg.get("effort")}
    baseline = send(_body(model, "Reply with the single word OK.", cfg), None, "probe-baseline")
    if not baseline.ok and cfg.get("effort") not in (None, "none") and baseline.status is not None and 400 <= baseline.status < 500 \
            and baseline.status not in (401, 403, 408, 429):
        rec["effort_rejected"] = _brief(baseline)
        log("probe: the plain request was refused with output_config.effort=%s (%s); retrying without it" % (cfg["effort"], _code(baseline)))
        cfg["effort"] = "none"
        rec["effort_used"] = "none"
        baseline = send(_body(model, "Reply with the single word OK.", cfg), None, "probe-baseline")
    rec["baseline"] = _brief(baseline)
    create = cont = None
    evidenced = False
    if baseline.ok:
        create = send(_body(model, "Remember this codeword: %s. Reply with the single word OK." % word, cfg, {"type": "create"}),
                      C.THREADS_BETA, "probe-create")
        rec["create"] = _brief(create)
        if create.ok and create.response_id:
            cont = send(_body(model, "What is the codeword? Reply with the codeword only.", cfg,
                              {"type": "continue", "previous_message_id": create.response_id}), C.THREADS_BETA, "probe-continue")
            rec["continue"] = _brief(cont)
            evidenced = bool(cont.ok and word.lower() in cont.text.lower())
    verdict, why = decide(baseline, create, cont, evidenced)
    rec["verdict"], rec["reason"] = verdict, why
    return rec
