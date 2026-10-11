#!/usr/bin/env python3
"""Fake LLM command AND fake `claude` binary. No network. Reads the prompt on stdin, writes one option name.
Appends one line per real call to $FAKE_LLM_LOG so tests can count calls.
  fake_llm.py --help          prints a claude-like option list ($FAKE_LLM_OMIT hides one flag)
  fake_llm.py [-p ...]        JSON like `claude -p --output-format json` when -p or --output-format is given, else plain text
  $FAKE_LLM_COST   cost to report (default 0.01; 'none' = null)   $FAKE_LLM_MODE  ok|garbage|fail"""
import json
import os
import re
import sys

HELP = """Usage: claude [options]
  -p, --print                       Print and exit
  --tools <tools>                   Tools
  --strict-mcp-config               Only MCP from --mcp-config
  --setting-sources <sources>       Setting sources
  --disable-slash-commands          Disable skills
  --no-session-persistence          No sessions
  --permission-mode <mode>          Permission mode (choices: "acceptEdits", "dontAsk", "plan")
  --max-budget-usd <amount>         Max spend
"""
if "--help" in sys.argv:
    omit = os.environ.get("FAKE_LLM_OMIT")
    print("\n".join(ln for ln in HELP.splitlines() if not (omit and omit in ln)))
    sys.exit(0)
prompt = sys.stdin.read()
with open(os.environ.get("FAKE_LLM_LOG", os.devnull), "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "prompt_len": len(prompt)}) + "\n")
mode = os.environ.get("FAKE_LLM_MODE", "ok")
if mode == "fail":
    print("upstream exploded", file=sys.stderr)
    sys.exit(3)
opts = re.findall(r"^- ([a-z0-9_-]+):", prompt, re.M)
low = prompt.lower()
data = low.split("<<<", 1)[-1]
pick = opts[0] if opts else "x"
for o, keys in (("urgent", ["urgent", "suspend", "disk", "alert", "today", "payment"]), ("ignore", ["sale", "prize", "survey", "winner"]),
                ("opus", ["architecture", "security", "payments"]), ("haiku", ["digest", "rename", "boilerplate", "format"])):
    if o in opts and any(k in data for k in keys):
        pick = o
        break
else:
    if "sonnet" in opts:
        pick = "sonnet"
    elif "later" in opts:
        pick = "later"
if mode == "garbage":
    pick = "I cannot decide, honestly"
if "-p" in sys.argv or "--output-format" in sys.argv:
    cost = os.environ.get("FAKE_LLM_COST", "0.01")
    print(json.dumps({"result": pick, "is_error": False, "total_cost_usd": None if cost == "none" else float(cost),
                      "usage": {"input_tokens": 10, "output_tokens": 1}}))
else:
    print(pick)
