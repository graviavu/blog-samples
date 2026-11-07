import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import unittest

from threads_test import pricing, probe
from tests.helpers import CLI, FAKE_KEY, SMALL, StubCase, env_for, run_cli, spawn_tty


class DryRun(StubCase):
    def test_dry_run_makes_no_connection_and_writes_nothing(self):
        r = run_cli(["--dry-run"] + SMALL + ["--results-dir", self.res], url=self.srv.url, key="")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.st.log), 0)
        self.assertEqual(os.listdir(self.res), [])
        self.assertIn("PLANNED UPPER BOUND", r.stdout)
        self.assertIn("no network call made", r.stdout)

    def test_no_flag_is_a_dry_run(self):
        r = run_cli([], url=self.srv.url, key="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.st.log), 0)
        self.assertIn("PLANNED UPPER BOUND", r.stdout)
        self.assertIn("Next: --probe", r.stdout)

    def test_there_is_no_yes_flag(self):
        r = run_cli(["--run", "--yes"], url=self.srv.url)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(self.st.log), 0)

    def test_dry_run_shows_500k_alongside_the_default_sizes(self):
        r = run_cli(["--dry-run"], key="")
        self.assertIn("--tokens 500000", r.stdout)
        self.assertIn("size 20000 tokens", r.stdout)
        self.assertIn("size 100000 tokens", r.stdout)
        self.assertIn("PLANNED UPPER BOUND", r.stdout)

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
        for bad in ("yes\n", "spend up to $10\n", "SPEND UP TO $5\n", "SPEND UP TO $10 \n", "\n"):
            r = self.go(confirm=bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertEqual(len(self.st.log), 0, bad)
            self.assertIn("Not confirmed", r.stdout)

    def test_piped_stdin_is_refused_even_with_the_right_phrase(self):
        r = run_cli(["--run", "--skip-probe"] + SMALL + ["--max-usd", "10", "--results-dir", self.res], url=self.srv.url,
                    stdin="SPEND UP TO $10\n", pipe_stdin=True)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("Refusing: the phrase must be typed at a terminal.", r.stdout)
        self.assertEqual(len(self.st.log), 0)
        self.assertEqual(os.listdir(self.res), [])

    def test_piped_stdin_is_refused_for_probe_and_before_count_tokens(self):
        r = run_cli(["--probe", "--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $5\n", pipe_stdin=True)
        self.assertEqual(r.returncode, 2)
        r = run_cli(["--run", "--count-tokens"] + SMALL + ["--max-usd", "10", "--results-dir", self.res], url=self.srv.url,
                    stdin="SPEND UP TO $10\n", pipe_stdin=True)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)

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


class Hardening(StubCase):
    """Review fixes M1, M3, L1, L2, L5."""

    def test_m1_margin_and_chars_per_token_are_validated(self):
        for flag, bad in (("--token-margin", "0.99"), ("--token-margin", "0"), ("--token-margin", "nan"), ("--token-margin", "inf"),
                          ("--chars-per-token", "1.9"), ("--chars-per-token", "4.6"), ("--chars-per-token", "9"), ("--chars-per-token", "nan")):
            r = run_cli(["--dry-run", flag, bad], key="")
            self.assertEqual(r.returncode, 2, (flag, bad, r.stdout))
            self.assertIn("error:", r.stdout)
        for flag, ok in (("--token-margin", "1.0"), ("--token-margin", "1.25"), ("--chars-per-token", "2.0"), ("--chars-per-token", "4.5")):
            self.assertEqual(run_cli(["--dry-run", flag, ok], key="").returncode, 0, (flag, ok))

    def runner(self, **over):
        from threads_test import client as C
        from threads_test.runner import Runner
        cfg = {"model": "claude-haiku-5-5", "tokens": 3000, "turns": 1, "reps": 1, "nocache_turns": 1, "nocache_reps": 1, "reload_reps": 1,
               "checks": False, "expiry_test": False, "expiry_wait": 1, "max_usd": 10, "max_tokens": 64, "effort": "low", "seed": 1,
               "margin": 1.25, "chars_per_token": 4.0, "retries": 0, "small_tokens": 2000, "salt_nonce": "t"}
        cfg.update(over)
        return Runner(cfg, C.Client(self.srv.url, FAKE_KEY), self.res, log=lambda m: None)

    def test_m1_guard_uses_the_size_of_the_request_actually_built(self):
        from threads_test.runner import SpendCap
        rn = self.runner(max_usd=0.05)
        big = {"model": "claude-haiku-5-5", "max_tokens": 64, "stream": True, "messages": [{"role": "user", "content": "x" * 2_000_000}]}
        self.assertLess(rn.ub(False), 0.05)          # the configured size alone would pass the guard
        self.assertGreater(rn.body_ub(big), 0.05)    # the real body would not
        with self.assertRaises(SpendCap):
            rn.send(1, 0, 0, "turn", big)
        self.assertEqual(len(self.st.log), 0)

    def test_m3_only_the_official_host_or_loopback(self):
        for url in ("https://example.com", "https://api.anthropic.com.evil.example", "https://api.anthropic.com@evil.example",
                    "http://api.anthropic.com", "https://evil.example:8443"):
            for extra in ([], ["--count-tokens"]):
                r = run_cli(["--dry-run"] + extra, url=url, key="")
                self.assertEqual(r.returncode, 2, (url, r.stdout))
                self.assertIn("ANTHROPIC_BASE_URL", r.stdout)
        r = run_cli(["--run", "--count-tokens"] + SMALL + ["--max-usd", "10", "--results-dir", self.res], url="https://example.com", stdin="SPEND UP TO $10\n")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(os.listdir(self.res), [])

    def test_m3_allowed_hosts_and_the_explicit_flag(self):
        for url in ("https://api.anthropic.com", "http://127.0.0.1:9", "http://localhost:9"):
            self.assertEqual(run_cli(["--dry-run"], url=url, key="").returncode, 0, url)
        self.assertEqual(run_cli(["--dry-run", "--base-url-host", "example.com"], url="https://example.com", key="").returncode, 0)
        self.assertEqual(run_cli(["--dry-run", "--base-url-host", "other.example"], url="https://example.com", key="").returncode, 2)
        self.assertEqual(run_cli(["--dry-run", "--base-url-host", "example.com"], url="http://example.com", key="").returncode, 2)  # still no plain http

    def test_l1_a_complete_200_without_usage_is_charged_the_projected_worst_case(self):
        from threads_test import client as C
        rn = self.runner()

        class NoUsage:
            def post(self, body, thread=False):
                r = C.Result()
                r.status, r.complete, r.text, r.response_id = 200, True, "ok", "msg_x"
                return r

            def close(self):
                pass
        rn.client = NoUsage()
        body = rn.body(list(rn.history), system="s")
        rn.send(1, 0, 0, "turn", body)
        self.assertGreater(rn.records[0]["charged_usd"], 0)
        self.assertAlmostEqual(rn.records[0]["charged_usd"], max(rn.ub(False), rn.body_ub(body)))
        self.assertAlmostEqual(rn.guard.spent, rn.records[0]["charged_usd"])

    def test_l1_probe_charges_a_200_without_usage(self):
        from threads_test import client as C
        from threads_test.runner import Guard

        class NoUsage:
            def post(self, body, thread=False):
                r = C.Result()
                r.status, r.complete, r.text, r.response_id = 200, True, "OK", "msg_x"
                return r
        g = Guard(5)
        probe.run(NoUsage(), g, "claude-haiku-5-5", "low", lambda m: None, {})
        self.assertGreater(g.spent, 0)

    def test_l2_ctrl_c_during_the_probe_prints_spend_and_writes_partial_probe_json(self):
        self.st.base_delay = 1.0
        p, master = spawn_tty(["--probe", "--results-dir", self.res], self.srv.url, text="SPEND UP TO $5\n")
        self.addCleanup(os.close, master)
        deadline = time.time() + 30
        while len(self.st.log) < 1 and time.time() < deadline:
            time.sleep(0.05)
        p.send_signal(signal.SIGINT)
        out, err = p.communicate(timeout=60)
        self.assertEqual(p.returncode, 130, out + err)
        self.assertIn("Probe stopped", out)
        self.assertIn("Spent $", out)
        self.assertIn("on the wire may add up to", out)
        d = os.path.join(self.res, os.listdir(self.res)[0])
        with open(os.path.join(d, "probe.json")) as f:
            rec = json.load(f)
        self.assertEqual(rec["verdict"], "INTERRUPTED")
        self.assertGreater(rec["in_flight_worst_case_usd"], 0)
        self.assertNotIn(FAKE_KEY, out + err + self.all_text())

    def test_l5_results_are_private(self):
        old = os.umask(0)
        try:
            r = self.go(["--results-dir", os.path.join(self.res, "fresh")])
        finally:
            os.umask(old)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        root = os.path.join(self.res, "fresh")
        seen = 0
        for dirpath, dirs, files in os.walk(root):
            self.assertEqual(os.stat(dirpath).st_mode & 0o777, 0o700, dirpath)
            for fn in files:
                self.assertEqual(os.stat(os.path.join(dirpath, fn)).st_mode & 0o777, 0o600, fn)
                seen += 1
        self.assertGreaterEqual(seen, 2)


class Interrupt(StubCase):
    def test_sigint_flushes_partial_results_and_prints_spend(self):
        self.st.base_delay = 0.4
        env = env_for(self.srv.url)
        p, master = spawn_tty(["--run", "--skip-probe"] + SMALL + ["--results-dir", self.res], self.srv.url, text="SPEND UP TO $5\n")   # the default cap
        self.addCleanup(os.close, master)
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
        self.assertIn("on the wire", out)   # the request in flight is reported at its worst case
        self.assertGreater(doc["in_flight_worst_case_usd"], 0)
        self.assertNotIn(FAKE_KEY, out + err + self.all_text())


class BackToBack(StubCase):
    """C1: the real client against an HTTP/1.1 chunked keep-alive server. One server request per client call."""

    def body(self, i):
        return {"model": "claude-haiku-5-5", "max_tokens": 16, "stream": True, "cache_control": {"type": "ephemeral"},
                "system": "s", "tools": [], "messages": [{"role": "user", "content": "q%d" % i}]}

    def test_ten_back_to_back_posts_no_response_not_ready(self):
        from threads_test import client as C
        c = C.Client(self.srv.url, FAKE_KEY)
        for i in range(10):
            r = c.post(self.body(i))
            self.assertIsNone(r.exception, "call %d: %s" % (i, r.exception))
            self.assertTrue(r.ok, i)
            self.assertEqual(len(self.st.log), i + 1)   # exactly one server-side request per client call

    def test_error_then_success_then_truncated_then_success(self):
        from threads_test import client as C
        c = C.Client(self.srv.url, FAKE_KEY)
        self.st.actions[:] = ["500", None, "truncate", None]
        got = [c.post(self.body(i)) for i in range(4)]
        self.assertEqual([r.status for r in got], [500, 200, 200, 200])
        self.assertTrue(got[1].ok)
        self.assertFalse(got[2].complete)
        self.assertTrue(got[3].ok)
        self.assertEqual(len(self.st.log), 4)

    def test_run_has_one_server_request_per_recorded_attempt_and_no_double_billing(self):
        r = self.go()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc, _ = self.results()
        self.assertEqual(len(self.st.log), doc["requests"])
        self.assertEqual(len(doc["records"]), doc["requests"])
        self.assertEqual(doc["summary"]["cache"]["retries"], 0)
        self.assertEqual(doc["summary"]["cache"]["replays_in_thread_arm"], 0)
        self.assertAlmostEqual(doc["spent_usd"], sum(x["charged_usd"] for x in doc["records"]), places=5)


class CapValidation(unittest.TestCase):
    def test_bad_caps_rejected(self):
        for bad in ("nan", "inf", "-inf", "0", "-1", "10.01", "abc", "1e9"):
            r = run_cli(["--dry-run", "--max-usd", bad], key="")
            self.assertEqual(r.returncode, 2, bad)
            self.assertNotIn("PLANNED UPPER BOUND", r.stdout, bad)

    def test_good_caps_accepted(self):
        for ok in ("10", "9.99", "5", "0.5"):
            r = run_cli(["--dry-run", "--max-usd", ok], key="")
            self.assertEqual(r.returncode, 0, ok)

    def test_no_override_flag(self):
        r = run_cli(["--dry-run", "--max-usd", "20", "--force"], key="")
        self.assertEqual(r.returncode, 2)


class DefaultBound(unittest.TestCase):
    """The default plan (20K and 100K tokens, Haiku 5.5) must have a worst case, with retries, replays and the probe, of at most $5."""

    def bound(self, args):
        r = run_cli(["--dry-run"] + args, key="")
        self.assertEqual(r.returncode, 0, r.stdout)
        m = re.search(r"PLANNED UPPER BOUND\s+\$([0-9.]+)\s+\(cap \$([0-9.]+)", r.stdout)
        self.assertTrue(m, r.stdout)
        return float(m.group(1)), float(m.group(2)), r.stdout

    def test_default_worst_case_is_at_most_5_dollars(self):
        total, cap, text = self.bound([])
        self.assertLessEqual(total, 5.0)
        self.assertEqual(cap, 5.0)
        self.assertGreater(total, 3.0)   # the bound is not accidentally tiny
        self.assertNotIn("EXCEEDS THE CAP", text)

    def test_default_covers_the_two_sizes_and_the_probe(self):
        _, _, text = self.bound([])
        self.assertIn("20000, 100000 tokens", text)
        self.assertIn("up to 4 tiny requests", text)
        self.assertIn("includes retries and replays and the probe", text)

    def test_the_bound_sums_the_sizes_and_the_probe(self):
        a = {"turns": 3, "reps": 2, "nocache_turns": 2, "nocache_reps": 1, "reload_reps": 2, "expiry_test": False,
             "margin": 1.25, "max_tokens": 512, "small_tokens": 2000, "checks": True, "retries": 1}
        e = pricing.estimate_sizes("claude-haiku-5-5", a, [20000, 100000])
        self.assertEqual([t for t, _ in e["per_size"]], [20000, 100000])
        self.assertAlmostEqual(e["total"], sum(x["total"] for _, x in e["per_size"]))
        self.assertEqual(e["per_size"][0][1]["counts"]["checks"], 2)   # checks run once, at the first size
        self.assertEqual(e["per_size"][1][1]["counts"]["checks"], 0)
        total = e["total"] + probe.bound("claude-haiku-5-5")
        self.assertLessEqual(total, 5.0)
        self.assertLess(pricing.typical("claude-haiku-5-5", a, [20000, 100000]), total / 4)

    def test_100k_alone_with_old_defaults_is_over_5(self):
        total, cap, text = self.bound(["--tokens", "100000", "--reps", "3", "--turns", "5", "--nocache-reps", "2"])
        self.assertGreater(total, 5.0)
        self.assertIn("EXCEEDS THE CAP", text)

    def test_raising_the_size_needs_the_cap_raised_and_the_phrase(self):
        reduced = ["--tokens", "500000", "--reps", "1", "--turns", "2", "--nocache-reps", "1", "--nocache-turns", "1", "--no-checks"]
        total, cap, text = self.bound(reduced)
        self.assertGreater(total, 5.0)
        self.assertLessEqual(total, 10.0)
        r = run_cli(["--run"] + reduced, key="x", stdin="SPEND UP TO $5\n")
        self.assertEqual(r.returncode, 2)
        self.assertIn("Refusing to start", r.stdout)
        total2, cap2, _ = self.bound(reduced + ["--max-usd", "10"])
        self.assertEqual(cap2, 10.0)
        self.assertNotIn("EXCEEDS", run_cli(["--dry-run", "--max-usd", "10"] + reduced, key="").stdout)

    def test_tokens_and_sizes_together_refused(self):
        r = run_cli(["--dry-run", "--tokens", "5000", "--sizes", "1000,2000"], key="")
        self.assertEqual(r.returncode, 2)

    def test_bad_sizes_refused(self):
        for bad in ("0", "abc", "100,100", "1,2,3,4,5", ""):
            r = run_cli(["--dry-run", "--sizes", bad], key="")
            self.assertEqual(r.returncode, 2, bad)


class MultiSize(StubCase):
    def sizes_run(self, extra=()):
        return run_cli(["--run", "--skip-probe", "--sizes", "2000,4000", "--turns", "2", "--reps", "2", "--nocache-turns", "2",
                        "--nocache-reps", "1", "--max-tokens", "64", "--chars-per-token", "4.0", "--results-dir", self.res] + list(extra),
                       url=self.srv.url, stdin="SPEND UP TO $5\n")

    def test_two_sizes_run_smallest_first_in_their_own_folders(self):
        r = self.sizes_run()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        stamp = os.path.join(self.res, os.listdir(self.res)[0])
        self.assertEqual(sorted(os.listdir(stamp)), ["2000", "4000", "results.md"])
        for sz in ("2000", "4000"):
            self.assertEqual(sorted(os.listdir(os.path.join(stamp, sz))), ["results.json", "results.md"])
        with open(os.path.join(stamp, "results.md")) as f:
            md = f.read()
        self.assertIn("latency versus context size", md)
        self.assertIn("| 2000 |", md)
        self.assertIn("| 4000 |", md)
        with open(os.path.join(stamp, "2000", "results.json")) as f:
            small = json.load(f)
        with open(os.path.join(stamp, "4000", "results.json")) as f:
            big = json.load(f)
        self.assertIn("a_bogus_id_404_and_replay", small["checks"])
        self.assertEqual(big["checks"], {})     # the checks run once, at the first size
        self.assertGreater(big["summary"]["arms"]["2"]["tokens_median"]["cache_read_input_tokens"],
                           small["summary"]["arms"]["2"]["tokens_median"]["cache_read_input_tokens"])

    def test_the_spend_cap_is_shared_across_sizes(self):
        r = self.sizes_run()
        stamp = os.path.join(self.res, os.listdir(self.res)[0])
        with open(os.path.join(stamp, "2000", "results.json")) as f:
            first = json.load(f)["spent_usd"]
        with open(os.path.join(stamp, "4000", "results.json")) as f:
            second = json.load(f)["spent_usd"]
        self.assertGreater(second, first)       # cumulative: one guard for the whole run

    def test_every_size_has_its_own_cold_prefix(self):
        self.sizes_run()
        salts = {}
        for path, hdrs, body in self.st.log:
            sysx = body.get("system") or ""
            if sysx.startswith("[salt "):
                salts.setdefault(sysx[6:30], 0)
                salts[sysx[6:30]] += 1
        first_per_size = [k for k in salts]
        self.assertEqual(len(first_per_size), len(set(first_per_size)))
        # arm 4 reloads at the two sizes use different salts, so the second size never reads the first size's cache
        doc_cold = 0
        for d in os.listdir(os.path.join(self.res, os.listdir(self.res)[0])):
            if d.isdigit():
                with open(os.path.join(self.res, os.listdir(self.res)[0], d, "results.json")) as f:
                    doc_cold += json.load(f)["summary"]["cache"]["cold_prefix_not_cold"]
        self.assertEqual(doc_cold, 0)


class Probe(StubCase):
    def probe(self, extra=(), cap="5", confirm=None, key=FAKE_KEY):
        confirm = "SPEND UP TO $%s\n" % cap if confirm is None else confirm
        return run_cli(["--probe", "--max-usd", cap, "--results-dir", self.res] + list(extra), url=self.srv.url, stdin=confirm, key=key)

    def test_accepted_makes_exactly_three_requests_and_costs_under_a_cent(self):
        r = self.probe()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PROBE VERDICT: ACCEPTED", r.stdout)
        self.assertEqual(len(self.st.log), 3)
        plain, create, cont = [b for _, _, b in self.st.log]
        self.assertNotIn("thread", plain)
        self.assertEqual(create["thread"], {"type": "create"})
        self.assertEqual(cont["thread"]["type"], "continue")
        self.assertNotIn("system", cont)
        self.assertNotIn("tools", cont)
        hdrs = [h for _, h, _ in self.st.log]
        self.assertNotIn("anthropic-beta", hdrs[0])
        self.assertEqual(hdrs[1]["anthropic-beta"], "message-threads-2026-08-12")
        self.assertEqual(hdrs[2]["anthropic-beta"], "message-threads-2026-08-12")
        for b in (plain, create, cont):
            self.assertEqual(b["model"], "claude-haiku-5-5")
            self.assertEqual(b["output_config"], {"effort": "low"})
        with open(os.path.join(self.res, os.listdir(self.res)[0], "probe.json")) as f:
            rec = json.load(f)
        self.assertEqual(rec["verdict"], "ACCEPTED")
        self.assertLess(rec["spent_usd"], 0.01)
        self.assertLess(probe.bound("claude-haiku-5-5"), 0.01)

    def test_the_continue_sends_only_the_question_and_the_codeword_comes_from_the_create(self):
        self.probe()
        _, create, cont = [b for _, _, b in self.st.log]
        word = re.search(r"PELICAN-\d+", json.dumps(create)).group(0)
        self.assertNotIn(word, json.dumps(cont))
        self.assertEqual(len(cont["messages"]), 1)

    def test_needs_the_typed_phrase_and_the_key(self):
        for bad in ("yes\n", "SPEND UP TO $10\n", ""):
            r = self.probe(confirm=bad)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(len(self.st.log), 0)
        r = self.probe(key="")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)

    def test_the_key_is_never_printed_or_written(self):
        r = self.probe()
        self.assertNotIn(FAKE_KEY, r.stdout + r.stderr + self.all_text())

    def test_rejected_when_the_beta_header_is_refused(self):
        self.st.reject_threads = True
        r = self.probe()
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertIn("PROBE VERDICT: REJECTED", r.stdout)
        self.assertIn("HTTP 400", r.stdout)
        self.assertEqual(len(self.st.log), 2)   # plain, then the refused create: no continue

    def test_inconclusive_when_the_plain_request_fails(self):
        self.st.actions = ["401"]
        r = self.probe()
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertIn("PROBE VERDICT: INCONCLUSIVE", r.stdout)
        self.assertEqual(len(self.st.log), 1)   # nothing else is sent

    def test_inconclusive_when_the_continue_names_a_thread_error(self):
        self.st.expire_after = 0.0
        r = self.probe()
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertIn("INCONCLUSIVE", r.stdout)
        self.assertIn("thread_not_found", r.stdout)

    def test_effort_refused_retries_the_plain_request_without_it(self):
        self.st.reject_effort = True
        r = self.probe()
        self.assertEqual(r.returncode, 0, r.stdout)
        bodies = [b for _, _, b in self.st.log]
        self.assertEqual(len(bodies), 4)
        self.assertIn("output_config", bodies[0])
        for b in bodies[1:]:
            self.assertNotIn("output_config", b)

    def test_a_continue_that_ignores_the_thread_is_inconclusive_not_accepted(self):
        self.st.ignore_thread_context = True
        r = self.probe()
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertIn("PROBE VERDICT: INCONCLUSIVE", r.stdout)
        self.assertIn("thread field may have been ignored", r.stdout)

    def test_probe_makes_no_arm_requests_and_writes_only_probe_json(self):
        self.probe()
        self.assertEqual(os.listdir(os.path.join(self.res, os.listdir(self.res)[0])), ["probe.json"])

    def test_run_stops_after_a_rejected_probe_without_spending_on_the_arms(self):
        self.st.reject_threads = True
        r = run_cli(["--run"] + SMALL + ["--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $5\n")
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertIn("Stopping before the paid arms", r.stdout)
        self.assertEqual(len(self.st.log), 2)

    def test_run_probes_first_then_runs_the_arms(self):
        r = run_cli(["--run"] + SMALL + ["--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $5\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PROBE VERDICT: ACCEPTED", r.stdout)
        self.assertGreater(len(self.st.log), 3)
        self.assertEqual(self.st.log[0][2]["max_tokens"], 256)   # the probe came first
        stamp = os.path.join(self.res, os.listdir(self.res)[0])
        self.assertEqual(sorted(os.listdir(stamp)), ["probe.json", "results.json", "results.md"])

    def test_decide_rules(self):
        from threads_test.client import Result

        def res(status, ok=False, code=None):
            x = Result()
            x.status, x.error_code = status, code
            if ok:
                x.complete = True
            return x
        good = res(200, True)
        self.assertEqual(probe.decide(None, None, None, False)[0], "INCONCLUSIVE")
        self.assertEqual(probe.decide(res(401), None, None, False)[0], "INCONCLUSIVE")
        self.assertEqual(probe.decide(good, res(400, code="thread_unsupported_request"), None, False)[0], "REJECTED")
        self.assertEqual(probe.decide(good, res(503), None, False)[0], "INCONCLUSIVE")
        self.assertEqual(probe.decide(good, res(429), None, False)[0], "INCONCLUSIVE")
        self.assertEqual(probe.decide(good, good, res(404, code="thread_not_found"), False)[0], "INCONCLUSIVE")
        self.assertEqual(probe.decide(good, good, res(400), False)[0], "REJECTED")
        self.assertEqual(probe.decide(good, good, good, False)[0], "INCONCLUSIVE")
        self.assertEqual(probe.decide(good, good, good, True)[0], "ACCEPTED")


class CountTokens(StubCase):
    def test_opt_in_counts_once_before_the_prompt(self):
        r = self.go(["--count-tokens"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(getattr(self.st, "count_calls", 0), 1)
        self.assertIn("count_tokens (free", r.stdout)
        first_messages = [i for i, (p, _, _) in enumerate(self.st.log) if p == "/v1/messages"]
        self.assertTrue(first_messages)
        self.assertNotIn("thread", self.st.log[0][2])   # the count request carries no thread

    def test_off_by_default_and_never_in_dry_run(self):
        self.go()
        self.assertEqual(getattr(self.st, "count_calls", 0), 0)
        before = len(self.st.log)
        run_cli(["--dry-run", "--count-tokens"] + SMALL, url=self.srv.url, key="")
        self.assertEqual(len(self.st.log), before)

    def test_over_margin_refuses_before_confirmation_prompt(self):
        self.st.count_scale = 5
        r = self.go(["--count-tokens"])
        self.assertEqual(r.returncode, 2)
        self.assertIn("Refusing to start", r.stdout)
        self.assertNotIn("type exactly", r.stdout)
        self.assertTrue(all(p == "/v1/messages/count_tokens" for p, _, _ in self.st.log))


class TopLevelHandler(StubCase):
    def test_unexpected_exception_is_one_redacted_line_not_a_traceback(self):
        r = self.go(extra=["--results-dir", "/dev/null/nope"])
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertNotIn("Traceback", r.stdout + r.stderr)
        self.assertIn("error:", r.stdout)
        self.assertEqual(len(self.st.log), 0)


class Wrapper(unittest.TestCase):
    def test_run_test_sh_with_no_flag_is_a_dry_run(self):
        sh = os.path.join(os.path.dirname(CLI), "..", "run-test.sh")
        r = subprocess.run([sh], capture_output=True, text=True, env={"PATH": os.environ["PATH"]})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("no network call made", r.stdout)


if __name__ == "__main__":
    unittest.main()
