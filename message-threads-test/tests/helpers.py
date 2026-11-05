import json
import os
import subprocess
import sys
import tempfile
import unittest

from tests.fake_api import Server

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "threads_test", "cli.py")
FAKE_KEY = "sk-ant-api03-FAKEKEYFORTESTS0123456789abcdef"
SMALL = ["--tokens", "3000", "--turns", "2", "--reps", "2", "--nocache-turns", "2", "--nocache-reps", "1",
         "--max-tokens", "64"]


def env_for(url, key=FAKE_KEY):
    e = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", "")}
    if url:
        e["ANTHROPIC_BASE_URL"] = url
    if key:
        e["ANTHROPIC_API_KEY"] = key
    return e


def run_cli(args, url=None, stdin="", key=FAKE_KEY, timeout=120):
    return subprocess.run([sys.executable, "-I", CLI] + args, input=stdin, capture_output=True, text=True,
                          env=env_for(url, key), timeout=timeout)


class StubCase(unittest.TestCase):
    def setUp(self):
        self.srv = Server().start()
        self.st = self.srv.state
        self.tmp = tempfile.TemporaryDirectory()
        self.res = self.tmp.name

    def tearDown(self):
        self.srv.stop()
        self.tmp.cleanup()

    def go(self, extra=(), cap="10", confirm=None, **kw):
        confirm = "SPEND UP TO $%s\n" % cap if confirm is None else confirm
        return run_cli(["--run"] + SMALL + ["--max-usd", cap, "--results-dir", self.res] + list(extra), url=self.srv.url, stdin=confirm, **kw)

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
