"""LLM baseline through a user-supplied command, with a spend guard.

The command gets the prompt on STDIN (never argv) and prints the answer on stdout. If stdout is a JSON object like
`claude -p --output-format json` prints, the answer is its "result" and the cost is its "total_cost_usd".
Spend guard (fail closed): --budget is required, --est-cost-per-call is required (used when the command reports no
cost, and to stop BEFORE a call that could cross the budget), --max-calls caps the number of calls across all runs.
Results are cached in results/data/llm.jsonl by item key + prompt hash, so a re-run does not pay twice.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

from adapters import run_with_timeout
from contract import DecisionModel, DecisionResponse, parse_answer, redact, render_prompt

SYSTEM = "You are a classifier. Reply with exactly one option name and nothing else."
UNPARSEABLE = "unparseable answer"
PERMISSION_MODE = "dontAsk"  # denies anything not pre-approved
# (option name as listed in `claude --help`, argv pieces). All required; no fallback.
ISOLATION = [
    ("--tools", ["--tools="]),                                # no built-in tools at all
    ("--strict-mcp-config", ["--strict-mcp-config"]),         # no MCP servers
    ("--setting-sources", ["--setting-sources", "project"]),  # skip user settings: hooks, plugins, user CLAUDE.md
    ("--disable-slash-commands", ["--disable-slash-commands"]),
    ("--no-session-persistence", ["--no-session-persistence"]),
    ("--permission-mode", ["--permission-mode", PERMISSION_MODE]),
]
PER_CALL_CAP = "0.05"  # --max-budget-usd per call, added when the flag exists


class StopRun(Exception):
    """Budget, call cap or repeated failure: stop calling, report what is done."""


def help_has(h, name):
    return re.search(r"(?m)^\s*(?:-\w,\s*)?(?:--[\w-]+,\s*)*" + re.escape(name) + r"(?=[\s,<=]|$)", h) is not None


def claude_argv(claude_bin, model):
    """`claude -p` with every isolation flag. Exits 1 if this build does not list all of them (no silent fallback)."""
    try:
        h = subprocess.run([claude_bin, "--help"], capture_output=True, text=True, timeout=60).stdout
    except Exception as e:
        raise SystemExit(f"cannot run `{claude_bin} --help`: {type(e).__name__}")
    missing = [n for n, _ in ISOLATION if not help_has(h, n)]
    if help_has(h, "--permission-mode") and PERMISSION_MODE not in h:
        missing.append(f"--permission-mode {PERMISSION_MODE}")
    if missing:
        print("REFUSING: this claude build lacks isolation flags: " + ", ".join(missing) + ". No call made.",
              file=sys.stderr)
        sys.exit(1)
    argv = [claude_bin, "-p", "--model", model, "--output-format", "json", "--system-prompt", SYSTEM]
    argv += [x for _, parts in ISOLATION for x in parts]
    if help_has(h, "--max-budget-usd"):
        argv += ["--max-budget-usd", PER_CALL_CAP]
    return argv


class CommandLLM(DecisionModel):
    def __init__(self, argv, name, log, budget, est_cost, max_calls, timeout=180):
        if budget is None or est_cost is None:
            raise SystemExit("LLM baseline needs --budget and --est-cost-per-call (spend guard fails closed)")
        self.argv, self.name, self.log = argv, name, log
        self.budget, self.est, self.max_calls, self.timeout = budget, est_cost, max_calls, timeout
        self.tmp = tempfile.mkdtemp(prefix="eval-llm-empty-")  # the command runs in an empty directory
        self.done, self.calls, self.spent, self.consec_fail, self.new_calls = {}, 0, 0.0, 0, 0
        self._load()

    def _load(self):
        if not os.path.exists(self.log.path):
            return
        with open(self.log.path) as fh:
            for line in fh:
                if not line.strip():
                    continue
                self.calls += 1  # torn lines still count as a call
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                self.spent += float(r.get("cost_usd") or 0)
                if r.get("cache_key") and (not r.get("error") or r.get("error") == UNPARSEABLE):
                    self.done[r["cache_key"]] = r

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def decide(self, req, key=None, purpose="llm", meta=None):
        prompt = render_prompt(req)
        ck = f"{key}|{hashlib.sha1(prompt.encode()).hexdigest()[:10]}"
        if ck in self.done:
            r = self.done[ck]
            return DecisionResponse(choice=r.get("answer"), latency_ms=r.get("wall_ms", 0), error=r.get("error"),
                                    cost_usd=0.0, source=self.name, schema_ok=r.get("answer") in req.options)
        if self.calls >= self.max_calls:
            raise StopRun(f"max calls {self.max_calls} reached")
        if self.spent + self.est > self.budget:
            raise StopRun(f"budget ${self.budget:.2f} would be crossed (spent ${self.spent:.4f}, next call est ${self.est})")
        t0 = time.perf_counter()
        out, err, rc, timed_out = "", "", None, False
        try:
            out, err, rc, timed_out = run_with_timeout(self.argv, prompt, self.timeout, cwd=self.tmp)
        except OSError as e:
            err = f"{type(e).__name__}: {e}"
        wall = (time.perf_counter() - t0) * 1000
        self.calls += 1
        self.new_calls += 1
        text, cost, error = out, 0.0, None
        try:
            j = json.loads(out)
        except ValueError:
            j = None
        if isinstance(j, dict):
            text = str(j.get("result", ""))
            c = j.get("total_cost_usd")
            cost = float(c) if isinstance(c, (int, float)) and c > 0 else 0.0
            if j.get("is_error"):
                error = f"command reported an error ({j.get('subtype')})"
        if timed_out:
            error = f"timeout after {self.timeout}s"
        elif rc != 0 and not error:
            error = f"exit {rc}: {(err or out)[:150]}"
        if not cost:
            cost = self.est  # unknown cost: charge the estimate, never zero
        answer = None if error else parse_answer(text, req.options)
        if not error and answer is None:
            error = UNPARSEABLE
        self.spent += cost
        rec = {"purpose": purpose, "model": self.name, "key": key, "cache_key": ck, "meta": meta or {},
               "prompt": prompt, "raw_result": text[:500], "answer": answer, "error": redact(error) if error else None,
               "cost_usd": cost, "wall_ms": round(wall, 1)}
        self.log.write(rec)
        self.consec_fail = self.consec_fail + 1 if error else 0
        if error == UNPARSEABLE:
            self.done[ck] = rec
        resp = DecisionResponse(choice=answer, latency_ms=round(wall, 1), error=rec["error"], cost_usd=cost,
                                source=self.name, schema_ok=answer in req.options)
        if self.consec_fail >= 3:
            raise StopRun("3 calls in a row failed")
        return resp
