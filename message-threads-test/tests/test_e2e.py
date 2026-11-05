import json
import os
import signal
import subprocess
import sys
import threading
import time
import unittest

from tests.helpers import CLI, FAKE_KEY, SMALL, StubCase, env_for, run_cli


class DryRun(StubCase):
    def test_dry_run_makes_no_connection_and_writes_nothing(self):
        r = run_cli(["--dry-run"] + SMALL + ["--results-dir", self.res], url=self.srv.url, key="")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.st.log), 0)
        self.assertEqual(os.listdir(self.res), [])
        self.assertIn("ESTIMATED WORST-CASE COST", r.stdout)
        self.assertIn("no network call made", r.stdout)

    def test_no_flag_does_nothing(self):
        r = run_cli([], url=self.srv.url)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)

    def test_there_is_no_yes_flag(self):
        r = run_cli(["--run", "--yes"], url=self.srv.url)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(self.st.log), 0)

    def test_dry_run_shows_500k_alongside_100k(self):
        r = run_cli(["--dry-run"], key="")
        self.assertIn("--tokens 500000", r.stdout)
        self.assertIn("ESTIMATED WORST-CASE COST", r.stdout)

    def test_estimate_over_cap_refuses_real_run(self):
        r = run_cli(["--run"] + SMALL + ["--max-usd", "0.0001", "--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $0.0001\n")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)
        self.assertIn("Refusing to start", r.stdout)

    def test_plain_http_to_remote_host_refused(self):
        r = run_cli(["--dry-run"], url="http://example.com", key="")
        self.assertEqual(r.returncode, 2)


class Confirmation(StubCase):
    def test_wrong_phrase_no_calls(self):
        for bad in ("yes\n", "spend up to $10\n", "SPEND UP TO $5\n", "SPEND UP TO $10 \n", "\n", ""):
            r = self.go(confirm=bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertEqual(len(self.st.log), 0, bad)
            self.assertIn("Not confirmed", r.stdout)

    def test_missing_key_stops_before_the_prompt(self):
        r = self.go(key="")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)
        self.assertNotIn("type exactly", r.stdout)

    def test_phrase_for_fractional_cap(self):
        r = self.go(cap="2.5", confirm="SPEND UP TO $2.5\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class FullRun(StubCase):
    def test_complete_run_all_arms_and_checks(self):
        r = self.go()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc, d = self.results()
        self.assertEqual(doc["status"], "complete")
        arms = doc["summary"]["arms"]
        for k in ("1", "2", "3", "4"):
            self.assertGreater(arms[k]["n"], 0, k)
        self.assertEqual(arms["2"]["n"], 2 * 2)   # reps x turns
        self.assertEqual(arms["3"]["n"], 2 * 2)
        self.assertEqual(arms["4"]["n"], 2)
        self.assertIsNotNone(arms["3"]["ttft_saving_pct"])
        self.assertTrue(os.path.exists(os.path.join(d, "results.md")))
        self.assertEqual(sorted(os.listdir(d)), ["results.json", "results.md"])   # no temp files left
        with open(os.path.join(d, "results.md")) as f:
            md = f.read()
        self.assertIn("Savings versus arm 1", md)
        self.assertIn("One machine, one network, one day", md)

    def test_token_usage_matched_between_arms(self):
        self.go()
        doc, _ = self.results()
        p = doc["summary"]["token_parity"]
        self.assertTrue(p["matched"], p)

    def test_cold_prefix_and_warm_turns(self):
        self.go()
        doc, _ = self.results()
        c = doc["summary"]["cache"]
        self.assertEqual(c["cold_prefix_not_cold"], 0)
        self.assertGreater(c["cold_prefix_confirmed"], 0)
        self.assertEqual(c["warm_turns_without_cache_read"], 0)
        for r in doc["records"]:
            if r["kind"] in ("reload", "reload_after_404"):
                self.assertEqual(r["usage"]["cache_read_input_tokens"], 0)
                self.assertGreater(r["usage"]["cache_creation_input_tokens"], 0)

    def test_system_prompt_salt_is_unique_and_first_on_the_wire(self):
        self.go()
        salts = []
        for _, _, body in self.st.log:
            if "system" in body:
                self.assertTrue(body["system"].startswith("[salt "))
                salts.append(body["system"].split("]")[0])
        # arm1 x1, arm2 x2, arm3 x2, arm4 x2, check x1 = 8 units, one salt each
        self.assertEqual(len(set(salts)), 8)

    def test_thread_requests_follow_the_docs(self):
        self.go()
        for _, h, b in self.st.log:
            th = b.get("thread")
            if th:
                self.assertEqual(h["anthropic-beta"], "message-threads-2026-08-12")
                self.assertEqual(b["cache_control"], {"type": "ephemeral"})
                if th["type"] == "continue":
                    self.assertNotIn("system", b)
                    self.assertNotIn("tools", b)
                    self.assertEqual(len(b["messages"]), 1)
            else:
                self.assertNotIn("anthropic-beta", h)

    def test_arm1_sends_no_cache_control_and_is_uncached(self):
        self.go()
        doc, _ = self.results()
        for r in doc["records"]:
            if r["arm"] == 1:
                self.assertEqual(r["usage"]["cache_creation_input_tokens"], 0)
                self.assertEqual(r["usage"]["cache_read_input_tokens"], 0)
        for _, _, b in self.st.log:
            if "system" in b and "thread" not in b and "cache_control" not in b:
                return
        self.fail("no uncached resend request seen")

    def test_checks_404_replay_and_single_continue(self):
        self.go()
        doc, _ = self.results()
        a, b = doc["checks"]["a_bogus_id_404_and_replay"], doc["checks"]["b_continue_same_id_twice"]
        self.assertEqual((a["status"], a["error_code"]), (404, "thread_not_found"))
        self.assertTrue(a["result"].startswith("PASS"), a)
        self.assertEqual((b["status"], b["error_code"]), (400, "thread_already_continued"))
        self.assertTrue(b["result"].startswith("PASS"), b)

    def test_expiry_check_records_the_404(self):
        self.st.expire_after = 0.3
        r = self.go(["--expiry-test", "--expiry-wait", "1"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc, _ = self.results()
        c = doc["checks"]["c_expiry_after_idle"]
        self.assertEqual(c["status"], 404)
        self.assertEqual(c["error_code"], "thread_not_found")

    def test_estimate_is_an_upper_bound_on_stub_spend(self):
        r = self.go()
        doc, _ = self.results()
        est = doc["config"]["estimated_worst_case_usd"]
        self.assertGreater(doc["spent_usd"], 0)
        self.assertLessEqual(doc["spent_usd"], est)
        self.assertLess(doc["spent_usd"], est / 2)   # the bound is loose on purpose: no cache-read credit

    def test_key_never_in_output_or_files(self):
        r = self.go(["--expiry-test", "--expiry-wait", "1"])
        blob = r.stdout + r.stderr + self.all_text()
        self.assertNotIn(FAKE_KEY, blob)
        self.assertNotIn("FAKEKEYFORTESTS", blob)
        self.assertNotRegex(blob, r"\bmsg_[0-9a-f]{12,}")
        self.assertNotRegex(blob, r"req_011CSH")
        self.assertNotIn("request_id", blob)

    def test_key_not_in_argv_and_sent_only_as_header(self):
        self.go()
        self.assertTrue(all(h.get("x-api-key") == FAKE_KEY for _, h, _ in self.st.log))
        for _, _, b in self.st.log:
            self.assertNotIn(FAKE_KEY, json.dumps(b))

    def test_ttft_ordering_with_prefill_delay(self):
        self.st.delay_per_token = 0.0004     # 0.4 ms per uncached token
        self.go()
        doc, _ = self.results()
        a = doc["summary"]["arms"]
        self.assertLess(a["3"]["ttft_ms_median"], a["1"]["ttft_ms_median"])
        self.assertLess(a["2"]["ttft_ms_median"], a["1"]["ttft_ms_median"])
        self.assertGreater(a["3"]["ttft_saving_pct"], 20)


class Failures(StubCase):
    def test_500_and_truncated_stream_are_retried(self):
        self.st.actions[:] = ["500", None, "truncate"]
        r = self.go()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc, _ = self.results()
        self.assertGreaterEqual(doc["summary"]["cache"]["retries"], 2)
        self.assertEqual(doc["status"], "complete")

    def test_cut_streams_and_a_500_mid_run_still_complete(self):
        self.st.actions[:] = [None] * 5 + ["truncate", None, None, "truncate", None, "500"]
        r = self.go()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc, _ = self.results()
        self.assertEqual(doc["status"], "complete")
        self.assertGreater(doc["summary"]["cache"]["retries"], 0)
        self.assertGreater(doc["summary"]["cache"]["failed_requests"], 0)

    def test_second_continue_after_a_cut_stream_replays_the_thread(self):
        """A cut continue stream is retried; the server never stored that turn, so the retry gets 404; the arm replays with a create."""
        # arm order is 1,2,3,4 on rep 0: arm 1 has 2 requests, arm 2 has 3, arm 3 starts at request 6 (create), then continue at 7
        self.st.actions[:] = [None] * 6 + ["truncate"]
        r = self.go()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc, _ = self.results()
        self.assertEqual(doc["status"], "complete")
        kinds = [x["kind"] for x in doc["records"] if x["arm"] == 3]
        self.assertIn("replay", kinds)

    def test_persistent_500_aborts_cleanly_with_partial_results(self):
        self.st.actions[:] = ["500"] * 50
        r = self.go()
        self.assertEqual(r.returncode, 4)
        doc, _ = self.results()
        self.assertTrue(doc["status"].startswith("aborted"))
        self.assertIn("Spent so far", r.stdout)


class SpendGuard(StubCase):
    def test_guard_class(self):
        from threads_test.runner import Guard, SpendCap
        g = Guard(1.0)
        g.check(0.5)
        g.add(0.9)
        with self.assertRaises(SpendCap):
            g.check(0.2)
        with self.assertRaises(SpendCap):
            g.add(0.2)
        self.assertAlmostEqual(g.spent, 1.1)

    def test_cap_stops_mid_run_when_usage_is_inflated(self):
        """The stub reports 400x the tokens, so running spend passes the cap after a few requests."""
        from threads_test import client as C
        from threads_test.runner import Runner
        self.st.usage_scale = 400
        cfg = {"model": "claude-haiku-5-5", "tokens": 3000, "turns": 2, "reps": 2, "nocache_turns": 2, "nocache_reps": 1, "reload_reps": 2,
               "checks": True, "expiry_test": False, "expiry_wait": 1, "max_usd": 0.02, "max_tokens": 64, "effort": "low", "seed": 1,
               "margin": 1.25, "calibration_margin": 1e9, "chars_per_token": 4.0, "retries": 1, "small_tokens": 2000, "salt_nonce": "t"}
        lines = []
        rn = Runner(cfg, C.Client(self.srv.url, FAKE_KEY), self.res, log=lines.append)
        code = rn.run()
        self.assertEqual(code, 3)
        self.assertIn("spend cap", rn.status)
        self.assertGreater(rn.n_requests, 0)
        self.assertLess(rn.n_requests, 10)
        self.assertTrue(os.path.exists(os.path.join(self.res, "results.json")))
        self.assertTrue(any("Spent so far" in x for x in lines))

    def test_cap_refuses_before_a_request_that_could_cross_it(self):
        from threads_test import client as C
        from threads_test.runner import Runner
        cfg = {"model": "claude-haiku-5-5", "tokens": 3000, "turns": 1, "reps": 1, "nocache_turns": 1, "nocache_reps": 1, "reload_reps": 1,
               "checks": False, "expiry_test": False, "expiry_wait": 1, "max_usd": 0.0001, "max_tokens": 64, "effort": "low", "seed": 1,
               "margin": 1.25, "chars_per_token": 4.0, "retries": 1, "small_tokens": 2000, "salt_nonce": "t"}
        rn = Runner(cfg, C.Client(self.srv.url, FAKE_KEY), self.res, log=lambda m: None)
        self.assertEqual(rn.run(), 3)
        self.assertEqual(len(self.st.log), 0)


class Interrupt(StubCase):
    def test_sigint_flushes_partial_results_and_prints_spend(self):
        self.st.base_delay = 0.4
        env = env_for(self.srv.url)
        p = subprocess.Popen([sys.executable, "-I", CLI, "--run"] + SMALL + ["--results-dir", self.res], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        p.stdin.write("SPEND UP TO $10\n")
        p.stdin.flush()
        deadline = time.time() + 30
        while len(self.st.log) < 3 and time.time() < deadline:
            time.sleep(0.05)
        p.send_signal(signal.SIGINT)
        out, err = p.communicate(timeout=60)
        self.assertEqual(p.returncode, 130, out + err)
        doc, d = self.results()
        self.assertEqual(doc["status"], "interrupted")
        self.assertGreaterEqual(len(doc["records"]), 2)
        self.assertEqual(sorted(os.listdir(d)), ["results.json", "results.md"])
        self.assertIn("Spent so far", out)
        self.assertNotIn(FAKE_KEY, out + err + self.all_text())


class Wrapper(unittest.TestCase):
    def test_run_test_sh_refuses_without_flag(self):
        sh = os.path.join(os.path.dirname(CLI), "..", "run-test.sh")
        r = subprocess.run([sh], capture_output=True, text=True, env={"PATH": os.environ["PATH"]})
        self.assertEqual(r.returncode, 2)
        self.assertIn("Nothing done", r.stdout)


if __name__ == "__main__":
    unittest.main()
