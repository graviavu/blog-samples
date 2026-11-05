"""Deterministic synthetic agent transcript. Seeded, no real data: every host, id and path is invented."""
import hashlib
import json
import random

WORDS = ("cache queue worker retry timeout upstream gateway shard replica index vacuum lease token budget limit "
         "region batch schema column latency backlog payload handler session window segment buffer socket cursor "
         "snapshot rollback commit lock stale fresh drift skew quota burst steady spike drain flush merge split "
         "route probe health canary deploy revert flag config secret rotate expire renew parse encode decode "
         "checksum offset partition leader follower quorum election heartbeat lag throttle admit reject accept").split()
SERVICES = ["svc-orders", "svc-billing", "svc-catalog", "svc-auth", "svc-search", "svc-notify", "svc-ledger"]
LEVELS = ["INFO", "INFO", "INFO", "WARN", "ERROR", "DEBUG"]

SYSTEM_BASE = ("You are an incident-triage agent for a fictional shop called Example Mart. You read log excerpts returned by "
               "tools and answer the operator's questions. Answer in one short sentence. Do not call tools.")
TOOLS = [
    {"name": "search_logs", "description": "Search the log store and return matching lines.",
     "input_schema": {"type": "object", "properties": {"service": {"type": "string"}, "query": {"type": "string"}},
                      "required": ["service", "query"]}},
    {"name": "read_file", "description": "Read a file from the deploy repository.",
     "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}},
]
TOOL_CHOICE = {"type": "none"}


def make_salt(seed, arm, rep, nonce):
    """Unique per (arm, rep, run). Placed at the very start of the system prompt so the whole prefix is cold."""
    h = hashlib.sha256(("%s|%s|%s|%s" % (seed, arm, rep, nonce)).encode()).hexdigest()
    return h[:24]


def system_text(salt):
    return "[salt %s] %s" % (salt, SYSTEM_BASE)


def _log_block(rng, lines=18):
    out = []
    for _ in range(lines):
        svc = rng.choice(SERVICES)
        msg = " ".join(rng.choice(WORDS) for _ in range(rng.randint(5, 11)))
        out.append("2026-03-%02dT%02d:%02d:%02dZ %s %s[%d] req=%s latency_ms=%d %s" % (
            rng.randint(1, 28), rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59), rng.choice(LEVELS), svc,
            rng.randint(100, 9999), "%08x" % rng.getrandbits(32), rng.randint(2, 2400), msg))
    return "\n".join(out)


def build_history(seed, tokens, chars_per_token=3.2):
    """Messages ending with a user message (tool_result + the turn 0 question). Size is about tokens."""
    rng = random.Random(seed)
    target = int(tokens * chars_per_token)
    msgs = [{"role": "user", "content": "Example Mart checkout is slow since the last deploy. Investigate with the log tools and report."}]
    size = len(SYSTEM_BASE) + len(json.dumps(TOOLS)) + 120
    i = 0
    while True:
        i += 1
        svc = rng.choice(SERVICES)
        tid = "toolu_%06d" % i
        asst = {"role": "assistant", "content": [
            {"type": "text", "text": "Checking %s for %s." % (svc, " ".join(rng.choice(WORDS) for _ in range(4)))},
            {"type": "tool_use", "id": tid, "name": "search_logs", "input": {"service": svc, "query": rng.choice(WORDS)}}]}
        res = {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": _log_block(rng)}]}
        add = len(json.dumps(asst)) + len(json.dumps(res))
        msgs += [asst, res]
        size += add
        if size >= target:
            break
    msgs[-1]["content"].append({"type": "text", "text": followup_text(0)})
    return msgs


def followup_text(i):
    qs = ["Which service looks worst so far?", "What changed in the last hour?", "Is the error rate rising or flat?",
          "Which request id should we trace first?", "Is a rollback justified?", "What is the single next step?",
          "Summarise the evidence in one sentence.", "Does the latency come from the cache or the database?"]
    return "Turn %d: %s" % (i, qs[i % len(qs)])


def user_msg(i):
    return {"role": "user", "content": [{"type": "text", "text": followup_text(i)}]}


def assistant_msg(text):
    t = (text or "").strip() or "(no text)"
    return {"role": "assistant", "content": [{"type": "text", "text": t}]}


def small_history(seed):
    return [{"role": "user", "content": "Say OK."}]
