import json
import os
import signal
import subprocess
import sys
import threading
import time
import unittest

from tests.helpers import CLI, FAKE_TOKEN, SMALL, StubCase, run_cli


class DryRun(StubCase):
    def test_default_is_a_dry_run_with_no_call_and_no_files(self):
        r = run_cli(["--endpoint", self.srv.url, "--results-dir", self.res] + SMALL, token="")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.st.log), 0)
        self.assertEqual(os.listdir(self.res), [])
        self.assertIn("PLANNED WORST CASE", r.stdout)
        self.assertIn("no network call made", r.stdout)

    def test_explicit_dry_run_same(self):
        r = run_cli(["--dry-run", "--endpoint", self.srv.url, "--results-dir", self.res] + SMALL)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(len(self.st.log), 0)

    def test_dry_run_prints_counts_and_tokens(self):
        r = run_cli(["--dry-run"], token="")
        self.assertIn("arm A", r.stdout)
        self.assertIn("20000, 100000, 200000", r.stdout)
        self.assertIn("UNKNOWN", r.stdout)

    def test_default_plan_is_over_the_default_cap_and_refuses(self):
        r = run_cli(["--run", "--endpoint", self.srv.url, "--results-dir", self.res], stdin="SPEND UP TO $5\n")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)
        self.assertIn("Refusing to start", r.stdout)

    def test_there_is_no_yes_flag(self):
        r = run_cli(["--run", "--yes"])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(self.st.log), 0)

    def test_plain_http_to_remote_host_refused(self):
        r = run_cli(["--dry-run", "--endpoint", "http://example.com/anthropic"], token="")
        self.assertEqual(r.returncode, 2)

    def test_modes_are_exclusive(self):
        self.assertNotEqual(run_cli(["--run", "--probe"]).returncode, 0)

    def test_bad_cap_values(self):
        for bad in ("0", "-1", "nan", "inf", "x"):
            self.assertNotEqual(run_cli(["--dry-run", "--max-usd", bad], token="").returncode, 0, bad)


class Gate(StubCase):
    def test_wrong_phrase_no_calls(self):
        for bad in ("yes\n", "spend up to $5\n", "SPEND UP TO $4\n", "SPEND UP TO $5 \n", "\n", ""):
            r = self.go(confirm=bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertEqual(len(self.st.log), 0, bad)
            self.assertIn("Not confirmed", r.stdout)

    def test_probe_also_needs_the_phrase(self):
        r = self.go("--probe", confirm="go\n")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)

    def test_missing_token_stops_before_the_prompt(self):
        r = self.go(token="")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)
        self.assertNotIn("type exactly", r.stdout)

    def test_fractional_cap_phrase(self):
        r = self.go(cap="2.5", confirm="SPEND UP TO $2.5\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class Probe(StubCase):
    def verdict(self, mode, **kw):
        self.st.thread_mode = mode
        r = self.go("--probe", **kw)
        doc, _ = self.results()
        return r, doc

    def test_accepted(self):
        r, doc = self.verdict("accept")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(doc["probe"]["verdict"], "ACCEPTED")
        self.assertIn("PROBE VERDICT: ACCEPTED", r.stdout)
        self.assertEqual(doc["summary"], [])
        beta = [h.get("anthropic-beta") for _, h, b in self.st.log if b.get("thread")]
        self.assertEqual(beta, ["message-threads-2026-08-12"] * 2)
        types = [b["thread"]["type"] for _, h, b in self.st.log if b.get("thread")]
        self.assertEqual(types, ["create", "continue"])
        self.assertLessEqual(len(self.st.log), 4)

    def test_rejected_with_code_verbatim(self):
        r, doc = self.verdict("reject")
        self.assertEqual(doc["probe"]["verdict"], "REJECTED")
        self.assertEqual(doc["probe"]["create"]["error"]["error_code"], "unsupported_parameter")
        self.assertEqual(doc["probe"]["create"]["error"]["error_type"], "invalid_request_error")
        self.assertEqual(doc["probe"]["create"]["http_status"], 400)
        self.assertIn("PROBE VERDICT: REJECTED", r.stdout)
        self.assertIn("unsupported_parameter", r.stdout)

    def test_inconclusive_on_server_error(self):
        r, doc = self.verdict("err500", extra=["--retries", "0"])
        self.assertEqual(doc["probe"]["verdict"], "INCONCLUSIVE")

    def test_inconclusive_when_thread_field_is_ignored(self):
        r, doc = self.verdict("ignore")
        self.assertEqual(doc["probe"]["verdict"], "INCONCLUSIVE")
        self.assertIn("ignored", doc["probe"]["reason"])

    def test_inconclusive_when_create_gives_no_id(self):
        r, doc = self.verdict("no_id")
        self.assertEqual(doc["probe"]["verdict"], "INCONCLUSIVE")

    def test_baseline_failure_is_inconclusive_and_stops_the_run(self):
        self.st.baseline_status = 403
        r = self.go("--run")
        doc, _ = self.results()
        self.assertEqual(doc["probe"]["verdict"], "INCONCLUSIVE")
        self.assertEqual(doc["status"], "failed_baseline")
        self.assertEqual(r.returncode, 4)
        self.assertEqual(len(self.st.log), 1)   # nothing after the plain request

    def test_wrong_token_is_inconclusive(self):
        r = self.go("--probe", token="ABSKwrongwrongwrong1234")
        doc, _ = self.results()
        self.assertEqual(doc["probe"]["verdict"], "INCONCLUSIVE")
        self.assertEqual(doc["probe"]["baseline"]["http_status"], 401)

    def test_effort_refusal_falls_back_for_the_probe(self):
        self.st.effort_status = 400
        r = self.go("--probe")
        doc, _ = self.results()
        self.assertEqual(doc["probe"]["verdict"], "ACCEPTED")
        self.assertEqual(doc["probe"]["effort_used"], "none")
        self.assertIn("effort_rejected", doc["probe"])


class Arms(StubCase):
    def test_full_run_with_threads_accepted(self):
        r = self.go()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc, d = self.results()
        self.assertEqual(doc["status"], "complete")
        rows = doc["summary"]
        self.assertEqual(len(rows), 2 * 2 * 3)   # models x sizes x arms
        for row in rows:
            self.assertEqual(row["ok"], 2, row)
            self.assertIsNotNone(row["ttft_median_s"])
            self.assertIsNotNone(row["ttft_p90_s"])
            self.assertGreater(row["real_prompt_tokens"], 0)
        b = [x for x in rows if x["arm"] == "B"]
        self.assertTrue(all(x["cache_read_tokens_measured"] > 0 for x in b))
        a = [x for x in rows if x["arm"] == "A"]
        self.assertTrue(all(x["cache_read_tokens_measured"] == 0 for x in a))
        self.assertTrue(os.path.exists(os.path.join(d, "results.md")))
        # models sent as the Bedrock ids
        models = {b_["model"] for _, _, b_ in self.st.log}
        self.assertEqual(models, {"anthropic.claude-sonnet-5-5", "anthropic.claude-haiku-5-5"})

    def test_arm_c_sends_only_new_messages_with_fixed_fields(self):
        self.go()
        cont = [b for _, _, b in self.st.log if b.get("thread", {}).get("type") == "continue" and len(b["messages"]) == 1
                and "Question" in str(b["messages"][0])]
        self.assertTrue(cont)
        for b in cont:
            self.assertEqual(len(b["messages"]), 1)
            self.assertNotIn("system", b)
            self.assertEqual(b["cache_control"], {"type": "ephemeral"})

    def test_a_has_no_cache_control_and_b_has(self):
        self.go()
        big = [b for _, _, b in self.st.log if len(b["messages"]) > 2 and not b.get("thread")]
        self.assertTrue([b for b in big if "cache_control" in b])
        self.assertTrue([b for b in big if "cache_control" not in b])

    def test_thread_arm_skipped_when_rejected(self):
        self.st.thread_mode = "reject"
        r = self.go()
        doc, _ = self.results()
        self.assertEqual(doc["probe"]["verdict"], "REJECTED")
        self.assertEqual(sorted({x["arm"] for x in doc["summary"]}), ["A", "B"])
        self.assertIn("Thread arm C skipped", r.stdout)
        self.assertEqual([1 for _, _, b in self.st.log if b.get("thread") and "Question" in str(b["messages"])], [])

    def test_no_cache_read_is_reported(self):
        self.st.no_cache = True
        self.go()
        doc, d = self.results()
        md = open(os.path.join(d, "results.md")).read()
        self.assertIn("no cache-read tokens appeared", md)

    def test_transient_error_is_retried_once(self):
        self.st.actions = ["503"]
        r = self.go("--probe")
        doc, _ = self.results()
        self.assertEqual(doc["probe"]["verdict"], "ACCEPTED")
        self.assertEqual(doc["requests"][0]["attempts"], 2)

    def test_client_error_is_not_retried(self):
        self.st.baseline_status = 400
        self.go("--probe", extra=["--effort", "none"])
        doc, _ = self.results()
        self.assertEqual(doc["requests"][0]["attempts"], 1)

    def test_thinking_first_token_is_flagged(self):
        self.st.think = True
        self.go()
        doc, d = self.results()
        self.assertIn("first thinking token", open(os.path.join(d, "results.md")).read())

    def test_continue_failure_is_replayed_with_create(self):
        # a thread that vanishes: wipe the server's thread store before each continue by making ids unknown
        orig = self.st.threads

        class Forgetful(dict):
            def get(self, k, d=None):
                return None
        self.st.threads = Forgetful()
        self.go()
        doc, _ = self.results()
        c = [x for x in doc["summary"] if x["arm"] == "C"]
        self.assertTrue(all(x["replays"] > 0 for x in c), c)
        self.st.threads = orig


class CapGuard(StubCase):
    def test_stops_when_measured_spend_reaches_the_cap(self):
        self.st.usage_scale = 30   # the stub reports 30x the tokens; the plan's bound does not know
        r = self.go(cap="0.3")
        doc, _ = self.results()
        self.assertEqual(doc["status"], "stopped_cap")
        self.assertEqual(r.returncode, 3)
        self.assertIn("STOPPED", r.stdout)
        self.assertLess(doc["requests_sent"], 20)
        self.assertGreaterEqual(doc["spent_usd"], 0.3)
        n = len(self.st.log)
        self.assertEqual(n, doc["requests_sent"])

    def test_pre_request_check_blocks_a_request_that_could_cross(self):
        # cap just above the plan: with the bound summed over a real run this must never be exceeded by the stub's honest usage
        r = self.go(cap="0.5")
        doc, _ = self.results()
        self.assertEqual(doc["status"], "complete")
        self.assertLessEqual(doc["spent_usd"], 0.5)

    def test_prompt_larger_than_target_stops_the_run(self):
        self.st.usage_scale, self.st.scale_after = 2, 6    # after the probe and the calibration, the stub reports double
        r = self.go()
        doc, _ = self.results()
        self.assertEqual(doc["status"], "stopped_size")
        self.assertIn("cost bound no longer holds", r.stdout)


class Leaks(StubCase):
    def test_token_never_in_output_files_or_argv(self):
        self.st.leak_token = True          # the stub echoes the token and an account id inside error bodies
        self.st.thread_mode = "reject"
        r = self.go()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        everything = r.stdout + r.stderr + self.all_text()
        for secret in (FAKE_TOKEN, "123456789012", "arn:aws", "msg_0", "req_011", "7f1c2d3e"):
            self.assertNotIn(secret, everything, secret)
        self.assertIn("<key>", everything)    # the echoed token was redacted, not dropped silently
        self.assertTrue(all(FAKE_TOKEN not in a for a in [CLI]))

    def test_bearer_auth_header_option(self):
        r = self.go("--probe", extra=["--auth-header", "bearer"])
        self.assertEqual(r.returncode, 0, r.stdout)
        _, h, _ = self.st.log[0]
        self.assertTrue(h["authorization"].startswith("Bearer "))
        self.assertNotIn("x-api-key", h)

    def test_default_auth_header_is_x_api_key(self):
        self.go("--probe")
        _, h, _ = self.st.log[0]
        self.assertEqual(h["x-api-key"], FAKE_TOKEN)

    def test_no_files_outside_results_and_no_temp_files_left(self):
        self.go()
        _, d = self.results()
        self.assertEqual(sorted(os.listdir(d)), ["results.json", "results.md"])


class Results(StubCase):
    def test_json_and_markdown_format(self):
        self.go()
        doc, d = self.results()
        for k in ("status", "spent_usd", "config", "probe", "summary", "requests", "cells", "started_utc"):
            self.assertIn(k, doc)
        row = doc["summary"][0]
        for k in ("model", "size_target", "arm", "ttft_median_s", "ttft_p90_s", "total_median_s", "total_p90_s", "cost_usd",
                  "real_prompt_tokens", "ttft_saving_vs_A_pct", "prime_ttft_s"):
            self.assertIn(k, row)
        md = open(os.path.join(d, "results.md")).read()
        self.assertIn("| Model | Size target |", md)
        self.assertIn("Verdict: ACCEPTED", md)
        self.assertIn("TTFT median", md)
        self.assertEqual(doc["config"]["models"], ["anthropic.claude-sonnet-5-5", "anthropic.claude-haiku-5-5"])
        self.assertNotIn(FAKE_TOKEN, json.dumps(doc))

    def test_no_ids_in_results(self):
        self.go()
        txt = self.all_text()
        import re
        self.assertIsNone(re.search(r"msg_[A-Za-z0-9]{6,}", txt))
        self.assertIsNone(re.search(r"\b\d{12}\b", txt))
        self.assertNotIn("request_id", txt)

    def test_faster_with_cache_in_stub_shows_a_saving(self):
        self.st.delay_per_token = 0.0003
        self.go(base=["--sizes", "6000", "--reps", "2", "--max-tokens", "32", "--models", "haiku-5-5"])
        doc, _ = self.results()
        b = [x for x in doc["summary"] if x["arm"] == "B"][0]
        self.assertGreater(b["ttft_saving_vs_A_pct"], 0)

    def test_price_override_changes_cost(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            f = os.path.join(t, "p.json")
            with open(f, "w") as fh:
                json.dump({"haiku-5-5": [{"up_to_prompt_tokens": None, "input": 100, "output": 100, "cache_write": 100, "cache_read": 100}]}, fh)
            r = run_cli(["--dry-run", "--prices", f, "--models", "haiku-5-5", "--sizes", "20000"])
            self.assertIn("EXCEEDS THE CAP", r.stdout)


class Interrupt(StubCase):
    def test_sigint_writes_partial_results_and_cleans_up(self):
        self.st.base_delay = 0.4
        env = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", ""), "AWS_BEARER_TOKEN_BEDROCK": FAKE_TOKEN}
        p = subprocess.Popen([sys.executable, "-I", CLI, "--run", "--endpoint", self.srv.url, "--max-usd", "5", "--results-dir", self.res] + SMALL,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        p.stdin.write("SPEND UP TO $5\n")
        p.stdin.flush()
        deadline = time.time() + 20
        while len(self.st.log) < 3 and time.time() < deadline:
            time.sleep(0.05)
        p.send_signal(signal.SIGINT)
        out, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 130, out + err)
        doc, d = self.results()
        self.assertEqual(doc["status"], "interrupted")
        self.assertEqual(sorted(os.listdir(d)), ["results.json", "results.md"])
        self.assertNotIn(FAKE_TOKEN, out + err + self.all_text())


if __name__ == "__main__":
    unittest.main()
