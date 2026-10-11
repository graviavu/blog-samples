"""End to end through run-eval.sh with the fake server and the fake LLM command. No network, no real model."""
import json
import os
import subprocess
import tempfile
import unittest

import helpers
import fake_decision_server as fs

SCRIPT = os.path.join(helpers.ROOT, "run-eval.sh")
PHRASE = "run paid llm calls"


class E2E(unittest.TestCase):
    def setUp(self):
        self.srv, self.url = fs.start()
        self.tmp = tempfile.mkdtemp()
        self.res = os.path.join(self.tmp, "results")
        self.calls = os.path.join(self.tmp, "calls.jsonl")
        self.env = dict(os.environ, FAKE_LLM_LOG=self.calls)

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def run_eval(self, *args, stdin="", env=None):
        return subprocess.run(["bash", SCRIPT, "--url", self.url, "--label", "fake", "--results-dir", self.res,
                               "--backup-timeout", "0.3", "--backup-items", "4", "--backup-primary-cmd", "sleep 30", *args],
                              input=stdin, capture_output=True, text=True, env=env or self.env, timeout=120)

    def llm_calls(self):
        if not os.path.exists(self.calls):
            return 0
        with open(self.calls) as f:
            return len(f.read().splitlines())

    def metrics(self):
        with open(os.path.join(self.res, "metrics.json")) as f:
            return json.load(f)

    def test_dry_run_makes_no_calls_and_writes_nothing(self):
        r = self.run_eval("--dry-run", "--llm-cmd", helpers.FAKE_LLM, "--budget", "1", "--est-cost-per-call", "0.01")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("DRY RUN", r.stdout)
        self.assertIn("20 emails", r.stdout)
        self.assertIn("typed confirmation", r.stdout)
        self.assertEqual(fs.COUNT["n"], 0)
        self.assertEqual(self.llm_calls(), 0)
        self.assertFalse(os.path.exists(self.res))

    def test_local_only_run(self):
        r = self.run_eval()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        met = self.metrics()
        t = met["triage"]["fake"]
        self.assertEqual(t["n_answered"], 20)
        self.assertEqual(t["injection_correct"]["of"], 3)
        self.assertEqual(met["plan"]["local_calls"], 20 + 12 * 6)
        self.assertEqual(met["backup"]["items"], 4)
        self.assertEqual(met["backup"]["taken_over_after_timeout"], 4)
        self.assertGreaterEqual(met["backup"]["median_switchover_ms"], 300)
        self.assertEqual(met["routing"]["fake"]["rows_scored"], 12)
        self.assertEqual(self.llm_calls(), 0)
        d = os.path.join(self.res, "data")
        for f in ("local-fake.jsonl", "backup.jsonl", "inputs/expected.tsv", "inputs/routing_used.tsv"):
            self.assertTrue(os.path.exists(os.path.join(d, f)), f)
        with open(os.path.join(d, "local-fake.jsonl")) as f:
            self.assertEqual(len(f.read().splitlines()), 20 + 12 * 6 + 4)  # backup also asks the local model
        self.assertTrue(os.path.exists(os.path.join(self.res, "REPORT.md")))

    def test_llm_needs_the_typed_phrase(self):
        args = ("--llm-cmd", helpers.FAKE_LLM + " -p", "--budget", "1", "--est-cost-per-call", "0.01", "--skip-backup")
        r = self.run_eval(*args, stdin="yes\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not confirmed", r.stdout)
        self.assertEqual(self.llm_calls(), 0)
        self.assertFalse(os.path.exists(os.path.join(self.res, "metrics.json")))

    def test_cli_refuses_llm_without_the_script_confirmation(self):
        r = subprocess.run(["python3", "-I", os.path.join(helpers.ROOT, "decision_eval", "cli.py"), "--url", self.url,
                            "--results-dir", self.res, "--llm-cmd", helpers.FAKE_LLM, "--budget", "1",
                            "--est-cost-per-call", "0.01"], capture_output=True, text=True, env=self.env)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.llm_calls(), 0)

    def test_llm_requires_budget_and_estimate(self):
        r = self.run_eval("--llm-cmd", helpers.FAKE_LLM, stdin=PHRASE + "\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.llm_calls(), 0)

    def test_full_run_with_llm_baseline(self):
        r = self.run_eval("--llm-cmd", helpers.FAKE_LLM + " -p", "--budget", "1", "--est-cost-per-call", "0.01",
                          "--llm-routing-rows", "5", stdin=PHRASE + "\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.llm_calls(), 25)  # 20 emails + 5 routing rows
        met = self.metrics()
        self.assertIn("llm-cmd", met["triage"])
        self.assertEqual(met["triage"]["llm-cmd"]["n_answered"], 20)
        self.assertEqual(met["triage_agreement"]["n"], 20)
        self.assertEqual(met["routing_agreement"]["n"], 5)
        self.assertIn("agreement_with_llm", met["backup"])
        self.assertIn("est. spend $0.2500", met["llm_run"])
        # re-run: the LLM answers are cached, no new paid call
        r2 = self.run_eval("--llm-cmd", helpers.FAKE_LLM + " -p", "--budget", "1", "--est-cost-per-call", "0.01",
                           "--llm-routing-rows", "5", "--skip-backup", stdin=PHRASE + "\n")
        self.assertEqual(r2.returncode, 0, r2.stdout)
        self.assertEqual(self.llm_calls(), 25)

    def test_budget_guard_stops_the_run_and_reports_partial(self):
        r = self.run_eval("--llm-cmd", helpers.FAKE_LLM + " -p", "--budget", "0.05", "--est-cost-per-call", "0.01",
                          "--skip-backup", stdin=PHRASE + "\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.llm_calls(), 5)
        self.assertIn("STOPPED: budget", self.metrics()["llm_run"])
        self.assertEqual(self.metrics()["triage"]["llm-cmd"]["n_answered"], 5)

    def test_claude_preset_uses_isolation_flags(self):
        r = self.run_eval("--llm-preset", "claude", "--llm-bin", helpers.FAKE_LLM, "--budget", "1",
                          "--est-cost-per-call", "0.01", "--limit", "2", "--skip-backup", "--llm-routing-rows", "2",
                          stdin=PHRASE + "\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.calls) as f:
            argv = json.loads(f.readline())["argv"]
        self.assertIn("--strict-mcp-config", argv)
        self.assertIn("--tools=", argv)

    def test_local_model_down_fails_clearly(self):
        r = subprocess.run(["bash", SCRIPT, "--url", "http://127.0.0.1:1", "--timeout", "2", "--results-dir", self.res,
                            "--skip-backup", "--limit", "2"], capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(r.returncode, 2)
        self.assertIn("answered nothing", r.stdout)

    def test_logs_and_data_are_redacted(self):
        routing = os.path.join(self.tmp, "r.tsv")
        with open(routing, "w") as f:
            f.write("2026-01-01T00:00:00Z\tx\tresearch\tsonnet\tok\tuse sk-abcdefghijklmnop1234 and ghp_abcdefghijkl123456\n")
            f.write("2026-01-01T00:01:00Z\tx\tsummary\thaiku\tok\tdigest\n")
        r = self.run_eval("--routing", routing, "--skip-backup", "--limit", "2")
        self.assertEqual(r.returncode, 0, r.stdout)
        blob = r.stdout
        for root, _, files in os.walk(self.res):
            for fn in files:
                if fn.endswith((".jsonl", ".log", ".md")):
                    with open(os.path.join(root, fn)) as f:
                        blob += f.read()
        self.assertNotIn("sk-abcdefghijklmnop1234", blob)
        self.assertNotIn("ghp_abcdefghijkl123456", blob)

    def test_injection_regex_flags_exactly_the_three_labelled_emails(self):
        import harness as h
        d = os.path.join(helpers.ROOT, "data", "triage")
        flagged = [fn for fn in h.list_emails(os.path.join(d, "emails")) if h.INJECTION.search(h.read_email(os.path.join(d, "emails"), fn))]
        self.assertEqual(flagged, [fn for fn, (_, inj) in sorted(h.load_expected(os.path.join(d, "expected.tsv")).items()) if inj])

    def test_bundled_data_is_synthetic(self):
        import glob
        import re
        files = glob.glob(os.path.join(helpers.ROOT, "data", "triage", "emails", "*.txt"))
        self.assertEqual(len(files), 20)
        for fp in files:
            with open(fp) as f:
                txt = f.read()
            for addr in re.findall(r"[\w.+-]+@([\w.-]+)", txt):
                self.assertTrue(addr.endswith(".example"), (fp, addr))
        with open(os.path.join(helpers.ROOT, "data", "triage", "expected.tsv")) as f:
            self.assertEqual(len(f.read().strip().splitlines()), 21)


if __name__ == "__main__":
    unittest.main()
