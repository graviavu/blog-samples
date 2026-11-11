import json
import os
import subprocess
import sys
import tempfile
import unittest

from tests.fake_bedrock import Server

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "bedrock_latency", "cli.py")
FAKE_TOKEN = "ABSKQmVkcm9ja0FQSUtleS1GQUtFLVRPS0VOLTAxMjM0NTY3ODk"
SMALL = ["--sizes", "3000,6000", "--reps", "2", "--max-tokens", "32", "--models", "sonnet-5-5,haiku-5-5"]


def run_cli(args, stdin="", token=FAKE_TOKEN, timeout=120):
    env = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", "")}
    if token:
        env["AWS_BEARER_TOKEN_BEDROCK"] = token
    return subprocess.run([sys.executable, "-I", CLI] + args, input=stdin, capture_output=True, text=True, env=env, timeout=timeout)


class StubCase(unittest.TestCase):
    def setUp(self):
        self.srv = Server(FAKE_TOKEN).start()
        self.st = self.srv.state
        self.tmp = tempfile.TemporaryDirectory()
        self.res = self.tmp.name

    def tearDown(self):
        self.srv.stop()
        self.tmp.cleanup()

    def go(self, mode="--run", extra=(), cap="5", confirm=None, base=SMALL, **kw):
        confirm = "SPEND UP TO $%s\n" % cap if confirm is None else confirm
        return run_cli([mode, "--endpoint", self.srv.url, "--max-usd", cap, "--results-dir", self.res] + list(base) + list(extra),
                       stdin=confirm, **kw)

    def results(self):
        dirs = sorted(os.listdir(self.res))
        self.assertTrue(dirs, "no results directory")
        d = os.path.join(self.res, dirs[-1])
        with open(os.path.join(d, "results.json")) as f:
            return json.load(f), d

    def all_text(self):
        txt = []
        for root, _, files in os.walk(self.res):
            for fn in files:
                with open(os.path.join(root, fn), errors="replace") as f:
                    txt.append(f.read())
        return "\n".join(txt)
