"""Adapters: a local HTTP decision-model server, and the fallback wrapper. (LLM baseline: see llm.py.)

Every call is appended, redacted, to results/data/<file>.jsonl so a later run can back-test against the exact
requests and responses. Nothing here talks to anything except the URL you give it (loopback only unless
--allow-remote) or the command you give it.
"""
import json
import os
import signal
import subprocess
import time
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlparse

from contract import DecisionModel, DecisionResponse, check_schema, redact


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class DataLog:
    """Append-only jsonl of every request/response. Redacted on write. Never deleted by the harness."""

    def __init__(self, path, run_id):
        self.path, self.run_id = path, run_id
        os.makedirs(os.path.dirname(path), exist_ok=True)

    def write(self, rec):
        rec = dict(rec, ts=now(), run_id=self.run_id)
        with open(self.path, "a") as f:
            f.write(redact(json.dumps(rec)) + "\n")


def check_loopback(url, allow_remote=False):
    host = urlparse(url).hostname
    if host not in ("127.0.0.1", "localhost", "::1") and not allow_remote:
        raise SystemExit(f"refusing non-loopback url (pass --allow-remote if you mean it): host={host}")


SHAPES = ("systemone", "simple")


def build_body(shape, req):
    """systemone: {state, questions:{q:{type:choice,instructions,criteria}}} (the shape the pilot's Kev server takes).
    simple: this sample's own neutral shape {state, instructions, options}; write a thin shim to expose it."""
    if shape == "systemone":
        return {"state": req.state, "questions": {"q": {"type": "choice", "instructions": req.instructions,
                                                         "criteria": req.options}}}
    if shape == "simple":
        return {"state": req.state, "instructions": req.instructions, "options": req.options}
    raise ValueError(f"unknown shape {shape}")


def parse_body(shape, resp):
    a = resp["answers"]["q"] if shape == "systemone" else resp
    probs = a.get("probabilities")
    conf = a.get("confidence")
    return (a["choice"], float(conf) if conf is not None else None,
            {k: float(v) for k, v in probs.items()} if probs else None)


DEFAULT_PATH = {"systemone": "/v1/systemone", "simple": "/v1/decide"}


class HttpDecisionModel(DecisionModel):
    def __init__(self, base_url, label, shape="systemone", path=None, timeout=60, allow_remote=False, log=None):
        check_loopback(base_url, allow_remote)
        if shape not in SHAPES:
            raise SystemExit(f"--shape must be one of {SHAPES}")
        self.base, self.name, self.shape, self.timeout, self.log = base_url.rstrip("/"), label, shape, timeout, log
        self.path = path or DEFAULT_PATH[shape]

    def decide(self, req, key=None, purpose="", meta=None):
        body = build_body(self.shape, req)
        t0 = time.perf_counter()
        resp, err = None, None
        try:
            r = urllib.request.Request(self.base + self.path, json.dumps(body).encode(),
                                       {"Content-Type": "application/json"})
            with urllib.request.urlopen(r, timeout=self.timeout) as f:
                resp = json.loads(f.read())
        except Exception as e:  # the failure is data too
            err = f"{type(e).__name__}: {e}"[:300]
        ms = (time.perf_counter() - t0) * 1000
        out = DecisionResponse(latency_ms=round(ms, 1), error=err, source=self.name, raw=resp)
        if resp is not None:
            try:
                out.choice, out.confidence, out.probabilities = parse_body(self.shape, resp)
                out.schema_ok = check_schema(req, out.choice, out.confidence, out.probabilities)
            except (KeyError, TypeError, ValueError, AttributeError) as e:
                out.error = f"bad response shape: {type(e).__name__}: {e}"[:300]
        if self.log:
            self.log.write({"purpose": purpose, "model": self.name, "endpoint": self.path, "key": key,
                            "meta": meta or {}, "request": body, "response": resp, "error": out.error,
                            "client_ms": out.latency_ms, "schema_ok": out.schema_ok})
        return out


def run_with_timeout(argv, stdin_text, timeout, cwd=None):
    """Run argv, kill its whole process group at `timeout`. Returns (stdout, stderr, returncode, timed_out)."""
    p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         cwd=cwd, start_new_session=True)
    try:
        out, err = p.communicate(stdin_text, timeout=timeout)
        return out, err, p.returncode, False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return "", "", None, True


class Fallback:
    """Backup path: try the primary command with a timeout; if it times out or fails, ask the local model.
    The primary here is only a command to run (a hang for a simulated outage); the harness never uses it to buy answers."""

    def __init__(self, primary_argv, local, timeout):
        self.primary_argv, self.local, self.timeout = primary_argv, local, timeout

    def decide(self, req, key=None, purpose="backup", meta=None):
        t0 = time.perf_counter()
        status = "primary_timeout"
        try:
            out, _, rc, timed_out = run_with_timeout(self.primary_argv, "", self.timeout)
            status = "primary_timeout" if timed_out else ("primary_returned" if rc == 0 else f"primary_failed_rc{rc}")
        except OSError as e:
            status = f"primary_error:{type(e).__name__}"
        t1 = time.perf_counter()
        resp = self.local.decide(req, key=key, purpose=purpose, meta=dict(meta or {}, primary_status=status))
        t2 = time.perf_counter()
        return resp, {"primary_status": status, "detect_ms": round((t1 - t0) * 1000, 1),
                      "local_ms": resp.latency_ms, "switchover_ms": round((t2 - t0) * 1000, 1)}
