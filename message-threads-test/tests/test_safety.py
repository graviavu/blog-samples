"""Credit/billing/auth stops, --all, --resume. Stub only: no key, no network beyond 127.0.0.1."""
import json
import math
import os
import re
import stat
import unittest

from threads_test import client as C
from threads_test import pricing, resume
from tests.helpers import FAKE_KEY, SMALL, StubCase, run_cli

LEAK = " key %s id msg_0123456789abcdef0123 req_011CSHoEeqs5C35K2UUqR7Fy" % FAKE_KEY
BILLING = [
    (402, "billing_error", "There is an issue with your billing or payment information.", {}),
    (400, "invalid_request_error", "Your credit balance is too low to access the Anthropic API.", {}),
    (400, "invalid_request_error", "You have reached your workspace API usage limit: spend limit.", {}),
    (429, "rate_limit_error", "Your organization reached its monthly spend cap for this usage tier.", {"retry-after": "60"}),
    (429, "rate_limit_error", "Rate limited.", {}),   # no retry-after: the docs say a tier spend-cap 429 has none, so stop (conservative)
    (403, "permission_error", "Quota exceeded for this account.", {}),
]
AUTH = [
    (401, "authentication_error", "invalid x-api-key", {}),
    (403, "permission_error", "Your API key does not have permission to use the specified resource.", {}),
]
FULL_PLAN = 20   # SMALL: arm 1 = 2, arm 2 = 6, arm 3 = 6, arm 4 = 2, checks = 4 (bogus continue, replay, continue, double continue); no retries or replays


def shape(s):
    return (s[0], s[1], s[2] + LEAK, s[3])


class Base(StubCase):
    def run_all(self, extra=(), cap="4.5", confirm=None, **kw):
        confirm = "SPEND UP TO $%s\n" % cap if confirm is None else confirm
        return run_cli(["--all"] + SMALL + ["--max-usd", cap, "--results-dir", self.res] + list(extra), url=self.srv.url, stdin=confirm, **kw)

    def run_resume(self, d, extra=(), cap="4.5", confirm=None, **kw):
        confirm = "SPEND UP TO $%s\n" % cap if confirm is None else confirm
        return run_cli(["--resume", d] + SMALL + ["--max-usd", cap, "--results-dir", self.res] + list(extra), url=self.srv.url, stdin=confirm, **kw)

    def folder(self):
        return os.path.join(self.res, sorted(os.listdir(self.res))[-1])

    def only_private(self, root):
        n = 0
        for dirpath, _, files in os.walk(root):
            self.assertEqual(stat.S_IMODE(os.stat(dirpath).st_mode), 0o700, dirpath)
            for fn in files:
                self.assertEqual(stat.S_IMODE(os.stat(os.path.join(dirpath, fn)).st_mode), 0o600, fn)
                n += 1
        self.assertGreater(n, 0)

    def no_secrets(self, out, root):
        txt = out + "\n".join(open(os.path.join(d, f), errors="replace").read() for d, _, fs in os.walk(root) for f in fs)
        self.assertNotIn(FAKE_KEY, txt)
        self.assertNotIn("msg_0123456789abcdef0123", txt)
        self.assertNotIn("req_011CSHoEeqs5C35K2UUqR7Fy", txt)


class Classify(unittest.TestCase):
    def test_docs_shapes(self):
        self.assertEqual(C.classify(402, "billing_error", ""), "billing")
        self.assertEqual(C.classify(200, "billing_error", ""), "billing")      # an error event inside a stream
        self.assertEqual(C.classify(401, "authentication_error", ""), "auth")
        self.assertEqual(C.classify(403, "permission_error", "no access"), "auth")
        self.assertEqual(C.classify(400, "invalid_request_error", "Your credit balance is too low"), "billing")
        self.assertEqual(C.classify(429, "rate_limit_error", "spend cap", "30"), "billing")
        self.assertEqual(C.classify(429, "rate_limit_error", "slow down"), "billing")        # no retry-after
        self.assertIsNone(C.classify(429, "rate_limit_error", "slow down", "5"))             # plain rate limit stays transient
        self.assertIsNone(C.classify(400, "invalid_request_error", "thread: Extra inputs are not permitted"))
        self.assertIsNone(C.classify(404, "not_found_error", "thread not found"))
        self.assertIsNone(C.classify(500, "api_error", "boom"))
        self.assertIsNone(C.classify(529, "overloaded_error", "busy", None))

    def test_result_fatal_reason_is_redacted_and_short(self):
        C.R.add_secret(FAKE_KEY)
        r = C.Result()
        r.status, r.error_type = 402, "billing_error"
        r.error = {"type": "error", "error": {"type": "billing_error", "message": "x" * 500 + LEAK}}
        kind, reason = r.fatal()
        self.assertEqual(kind, "billing")
        self.assertLess(len(reason), 260)
        self.assertNotIn(FAKE_KEY, reason)


class StopOnMoney(Base):
    def stop_run(self, shp, after):
        self.st.error_after, self.st.error_shape = after, shape(shp)
        return self.go()

    def check_partial(self, r, shp, after, code):
        self.assertEqual(r.returncode, code, r.stdout + r.stderr)
        self.assertEqual(self.st.msg_requests, after + 1, "exactly one request after the threshold: no retry, no replay")
        doc, d = self.results()
        self.assertTrue(doc["status"].startswith("PARTIAL"), doc["status"])
        p = doc["partial"]
        self.assertTrue(p["partial"])
        self.assertEqual(p["kind"], "billing" if code == 5 else "auth")
        self.assertEqual(p["retried"], False)
        self.assertEqual(p["stage"]["tokens"], 3000)
        self.assertIn(str(shp[0]), p["reason"])
        self.assertEqual(len(doc["records"]), after + 1)
        last = doc["records"][-1]
        self.assertEqual(last["status"], shp[0])
        self.assertEqual(last["charged_usd"], 0)            # the refused request is charged nothing
        self.assertAlmostEqual(doc["spent_usd"], sum(x["charged_usd"] for x in doc["records"]), delta=1e-5)
        self.assertAlmostEqual(p["spent_usd"], doc["spent_usd"], delta=1e-5)
        self.assertIn("STOPPED", r.stdout)
        self.assertIn("Nothing more was sent and nothing was retried", r.stdout)
        self.assertIn("PARTIAL", open(os.path.join(d, "results.md")).read())
        self.assertIn("--resume", r.stdout)
        self.only_private(self.res)
        self.no_secrets(r.stdout + r.stderr, self.res)
        return doc

    def test_every_billing_shape_stops_at_once_with_partial_files(self):
        for shp in BILLING:
            with self.subTest(shp=shp[:2]):
                self.setUp_again()
                r = self.stop_run(shp, 4)
                self.check_partial(r, shp, 4, 5)

    def test_every_auth_shape_stops_at_once_with_exit_6(self):
        for shp in AUTH:
            with self.subTest(shp=shp[:2]):
                self.setUp_again()
                r = self.stop_run(shp, 4)
                self.check_partial(r, shp, 4, 6)

    def setUp_again(self):
        """A fresh stub and results folder for each sub-case."""
        self.tearDown()
        self.setUp()

    def test_a_400_on_a_thread_continue_is_not_taken_for_a_replayable_error(self):
        # request 7 is the first arm 3 continue, which allows 400 and 404 (it replays on thread errors); a credit 400 must stop instead
        r = self.stop_run(BILLING[1], 6)
        doc = self.check_partial(r, BILLING[1], 6, 5)
        self.assertEqual(doc["partial"]["stage"]["arm"], 3)
        self.assertNotIn("replay", [x["kind"] for x in doc["records"]])

    def test_in_stream_billing_error_event_stops(self):
        self.st.actions[:] = [None, None, "stream_billing"]
        r = self.go()
        self.assertEqual(r.returncode, 5, r.stdout)
        self.assertEqual(self.st.msg_requests, 3)
        doc, _ = self.results()
        self.assertTrue(doc["status"].startswith("PARTIAL"))
        self.assertGreater(doc["records"][-1]["charged_usd"], 0)   # billing of a cut stream is unknown: charged at its bound, never less

    def test_a_plain_rate_limit_with_retry_after_is_still_retried_once_then_aborts_as_before(self):
        self.st.error_after, self.st.error_shape = 2, (429, "rate_limit_error", "slow down", {"retry-after": "1"})
        r = self.go()
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertEqual(self.st.msg_requests, 4)    # 2 good, the failing request and its single retry
        doc, _ = self.results()
        self.assertTrue(doc["status"].startswith("aborted"))
        self.assertNotIn("partial", doc)

    def test_probe_billing_and_auth_errors(self):
        for shp, code in ((BILLING[0], 5), (BILLING[1], 5), (AUTH[0], 6)):
            with self.subTest(shp=shp[:2]):
                self.setUp_again()
                self.st.error_after, self.st.error_shape = 0, shape(shp)
                r = run_cli(["--probe", "--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $4.5\n")
                self.assertEqual(r.returncode, code, r.stdout)
                self.assertEqual(self.st.msg_requests, 1)
                with open(os.path.join(self.folder(), "probe.json")) as f:
                    rec = json.load(f)
                self.assertEqual(rec["verdict"], "PARTIAL")
                self.assertEqual(rec["spent_usd"], 0)
                self.assertIn("STOPPED", r.stdout)
                self.only_private(self.res)
                self.no_secrets(r.stdout, self.res)

    def test_401_action_in_the_probe_is_exit_6(self):
        self.st.actions = ["401"]
        r = run_cli(["--probe", "--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $4.5\n")
        self.assertEqual(r.returncode, 6, r.stdout)
        self.assertEqual(len(self.st.log), 1)

    def test_count_tokens_billing_error_stops_before_any_message(self):
        self.st.count_error = shape(BILLING[0])
        r = self.go(["--count-tokens"])
        self.assertEqual(r.returncode, 5, r.stdout)
        self.assertEqual(self.st.msg_requests, 0)
        self.assertIn("STOPPED", r.stdout)
        self.assertNotIn(FAKE_KEY, r.stdout + r.stderr)


class AllMode(Base):
    def test_order_probe_then_count_then_arms_and_the_phrase_once(self):
        r = self.run_all()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.count("To go ahead type exactly"), 1)
        paths = [p for p, _, _ in self.st.log]
        self.assertEqual(paths[:3], ["/v1/messages"] * 3)
        self.assertEqual(paths[3], "/v1/messages/count_tokens")
        self.assertEqual(paths.count("/v1/messages/count_tokens"), 1)
        self.assertEqual(paths[4:], ["/v1/messages"] * FULL_PLAN)
        self.assertEqual(self.st.log[0][2]["max_tokens"], 256)   # the probe came first
        self.assertIn("PROBE VERDICT: ACCEPTED", r.stdout)
        d = self.folder()
        self.assertEqual(sorted(os.listdir(d)), ["probe.json", "results.json", "results.md"])
        doc, _ = self.results()
        self.assertEqual(doc["status"], "complete")
        self.assertTrue(doc["checks_done"])
        self.assertEqual(len(doc["completed_units"]), 7)
        self.assertNotIn(FAKE_KEY, r.stdout + self.all_text())
        self.only_private(self.res)

    def test_stops_unless_accepted_and_never_counts_or_runs(self):
        self.st.reject_threads = True
        r = self.run_all()
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertEqual(len(self.st.log), 2)
        self.assertEqual(getattr(self.st, "count_calls", 0), 0)
        self.assertIn("Stopping before the paid arms", r.stdout)

    def test_too_big_history_is_adjusted_with_the_measured_ratio(self):
        self.st.count_scale = 1.2
        r = self.run_all()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.st.count_calls, 2)             # counted, adjusted, counted again (free)
        self.assertIn("adjusting --chars-per-token", r.stdout)
        doc, _ = self.results()
        self.assertLess(doc["config"]["chars_per_token"], 4.0)
        self.assertGreaterEqual(doc["config"]["chars_per_token"], 2.0)

    def test_way_too_big_history_refuses_before_any_full_size_request(self):
        self.st.count_scale = 5
        r = self.run_all()
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("Nothing was sent at full size", r.stdout)
        self.assertEqual(self.st.msg_requests, 3)            # the probe only
        with open(os.path.join(self.folder(), "probe.json")) as f:
            self.assertEqual(json.load(f)["verdict"], "ACCEPTED")

    def test_the_guards_still_hold(self):
        # tty only
        r = self.run_all(pipe_stdin=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("typed at a terminal", r.stdout)
        # wrong phrase, and the old default phrase
        for bad in ("yes\n", "SPEND UP TO $5\n", "\n"):
            r = self.run_all(confirm=bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertIn("Not confirmed", r.stdout)
        self.assertEqual(len(self.st.log), 0)
        # margin and ratio bounds
        for flag, bad in (("--token-margin", "0.5"), ("--chars-per-token", "9")):
            r = self.run_all([flag, bad])
            self.assertEqual(r.returncode, 2, (flag, bad))
        # host allowlist
        r = run_cli(["--all"] + SMALL, url="https://example.com", stdin="SPEND UP TO $4.5\n")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not api.anthropic.com", r.stdout)
        # no key
        r = self.run_all(key="")
        self.assertEqual(r.returncode, 2)
        # --skip-probe does not go with --all
        r = self.run_all(["--skip-probe"])
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)

    def test_over_cap_refuses(self):
        r = self.run_all(cap="0.0001")
        self.assertEqual(r.returncode, 2)
        self.assertIn("Refusing to start", r.stdout)
        self.assertEqual(len(self.st.log), 0)

    def test_mutually_exclusive_with_the_other_modes(self):
        for other in ("--run", "--probe", "--dry-run"):
            self.assertNotEqual(run_cli(["--all", other], key="").returncode, 0)

    def test_a_billing_error_in_the_arms_leaves_a_resumable_partial(self):
        self.st.error_after, self.st.error_shape = 3 + 4, shape(BILLING[1])
        r = self.run_all()
        self.assertEqual(r.returncode, 5, r.stdout)
        self.assertIn("--resume", r.stdout)
        doc, _ = self.results()
        self.assertEqual(doc["partial"]["stage"]["arm"], 2)
        self.only_private(self.res)
        self.no_secrets(r.stdout, self.res)


class DefaultCap(unittest.TestCase):
    def test_default_cap_is_4_50_and_the_bound_fits_with_room(self):
        r = run_cli(["--dry-run"], key="")
        m = re.search(r"PLANNED UPPER BOUND\s+\$([0-9.]+)\s+\(cap \$([0-9.]+)", r.stdout)
        self.assertEqual(float(m.group(2)), 4.5)
        self.assertAlmostEqual(float(m.group(1)), 4.44, places=2)
        self.assertLessEqual(float(m.group(1)), 4.5)
        self.assertNotIn("EXCEEDS", r.stdout)

    def test_the_printed_phrase_is_for_4_50(self):
        r = run_cli(["--all"], url="http://127.0.0.1:9", stdin="no\n")
        self.assertIn("type exactly: SPEND UP TO $4.5\n", r.stdout)
        self.assertEqual(r.returncode, 2)


class ResumeBase(Base):
    def partial(self, after=3 + 8, shp=None, extra=()):
        """An --all run that hits a credit error after `after` /v1/messages requests (3 are the probe). Returns the folder."""
        self.st.error_after, self.st.error_shape = after, shape(shp or BILLING[0])
        r = self.run_all(extra)
        self.assertEqual(r.returncode, 5, r.stdout + r.stderr)
        self.st.error_after = None
        self.st.msg_requests = 0
        self.st.log[:] = []
        return self.folder()

    def edit(self, d, fn, name="results.json"):
        path = os.path.join(d, name)
        with open(path) as f:
            doc = json.load(f)
        fn(doc)
        with open(path, "w") as f:
            json.dump(doc, f)
        os.chmod(path, 0o600)


class Resume(ResumeBase):
    def test_resume_runs_only_the_rest_and_ends_complete(self):
        d = self.partial()                      # arm 4 repetition 0 is the first request that fails
        with open(os.path.join(d, "results.json")) as f:
            first = json.load(f)
        done = {tuple(u) for u in first["completed_units"]}
        self.assertEqual(done, {(1, 0), (2, 0), (3, 0)})
        r = self.run_resume(d)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.count("To go ahead type exactly"), 1)
        self.assertIn("Probe not repeated", r.stdout)
        done_requests = sum(1 for x in first["records"] if (x["arm"], x["rep"]) in done)
        sent = [p for p, _, _ in self.st.log if p == "/v1/messages"]
        self.assertEqual(len(sent), FULL_PLAN - done_requests)          # nothing finished is sent again; the probe is not repeated
        self.assertLess(len(sent), FULL_PLAN)
        with open(os.path.join(d, "results.json")) as f:
            doc = json.load(f)
        self.assertEqual(doc["status"], "complete")
        self.assertNotIn("partial", doc)
        self.assertEqual(len(doc["completed_units"]), 7)
        self.assertTrue(doc["checks_done"])
        self.assertGreater(doc["spent_usd"], first["spent_usd"])         # cumulative: the first run's spend is carried
        self.assertEqual(doc["summary"]["cache"]["cold_prefix_not_cold"], 0)   # resumed units use a fresh cold prefix
        self.assertGreaterEqual(doc["abandoned_records_usd"], 0)
        self.only_private(self.res)
        self.no_secrets(r.stdout + r.stderr, self.res)

    def test_the_cap_covers_the_whole_folder(self):
        d = self.partial()
        with open(os.path.join(d, "results.json")) as f:
            spent = json.load(f)["spent_usd"]
        self.assertGreater(spent, 0)
        r = self.run_resume(d, cap=repr(spent / 2))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertEqual(len(self.st.log), 0)
        self.assertRegex(r.stdout, r"Refusing to resume|EXCEEDS")

    def test_remaining_bound_is_smaller_than_the_full_bound(self):
        a = {"turns": 2, "reps": 2, "nocache_turns": 2, "nocache_reps": 1, "reload_reps": 2, "expiry_test": False,
             "margin": 1.25, "max_tokens": 64, "small_tokens": 2000, "checks": True, "retries": 1, "tokens": 3000}
        full = pricing.estimate("claude-haiku-5-5", a)
        left = pricing.estimate("claude-haiku-5-5", a, pricing.remaining_counts(a, {(1, 0), (2, 0), (3, 0)}, False))
        self.assertLess(left["total"], full["total"])
        self.assertEqual(left["counts"]["arm1"], 0)
        self.assertEqual(left["counts"]["arm2"], 3)
        self.assertEqual(left["counts"]["checks"], 2)
        none_left = pricing.remaining_counts(a, {(1, 0), (2, 0), (2, 1), (3, 0), (3, 1), (4, 0), (4, 1)}, True)
        self.assertEqual(none_left["attempts"], 0)

    def test_dry_run_shows_what_is_left_and_sends_nothing(self):
        d = self.partial()
        r = run_cli(["--resume", d, "--dry-run"] + SMALL + ["--results-dir", self.res], url=self.srv.url, key="")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("REMAINING UPPER BOUND", r.stdout)
        self.assertIn("arm 1 rep 0", r.stdout)
        self.assertEqual(len(self.st.log), 0)

    def test_wrong_phrase_or_pipe_makes_no_call(self):
        d = self.partial()
        self.assertEqual(self.run_resume(d, confirm="nope\n").returncode, 2)
        self.assertEqual(self.run_resume(d, pipe_stdin=True).returncode, 2)
        self.assertEqual(len(self.st.log), 0)

    def test_complete_folder_has_nothing_left(self):
        r = self.run_all()
        self.assertEqual(r.returncode, 0)
        n = len(self.st.log)
        r = self.run_resume(self.folder())
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("Nothing left to run", r.stdout)
        self.assertEqual(len(self.st.log), n)

    def test_resume_after_an_unfinished_probe_repeats_the_probe(self):
        self.st.error_after, self.st.error_shape = 0, shape(BILLING[0])
        self.assertEqual(self.run_all().returncode, 5)
        d = self.folder()
        self.st.error_after = None
        self.st.msg_requests = 0
        self.st.log[:] = []
        r = self.run_resume(d)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PROBE VERDICT: ACCEPTED", r.stdout)
        self.assertEqual(len([1 for p, _, _ in self.st.log if p == "/v1/messages"]), 3 + FULL_PLAN)

    def test_a_rejected_probe_cannot_be_resumed(self):
        self.st.reject_threads = True
        self.assertEqual(self.run_all().returncode, 4)
        n = len(self.st.log)
        r = self.run_resume(self.folder())
        self.assertEqual(r.returncode, 2)
        self.assertIn("REJECTED", r.stdout)
        self.assertEqual(len(self.st.log), n)

    def test_multi_size_resume_skips_the_finished_size(self):
        sizes = ["--sizes", "2000,3000", "--turns", "2", "--reps", "2", "--nocache-turns", "2", "--nocache-reps", "1",
                 "--max-tokens", "64", "--chars-per-token", "4.0", "--results-dir", self.res]
        # probe 3 + size 2000 (20 requests) + 2 of size 3000 (then the 3rd fails)
        self.st.error_after, self.st.error_shape = 3 + 20 + 2, shape(BILLING[0])
        r = run_cli(["--all"] + sizes, url=self.srv.url, stdin="SPEND UP TO $4.5\n")
        self.assertEqual(r.returncode, 5, r.stdout + r.stderr)
        d = self.folder()
        self.only_private(self.res)
        with open(os.path.join(d, "results.md")) as f:
            self.assertIn("PARTIAL", f.read())
        self.st.error_after = None
        self.st.msg_requests = 0
        calls_before = getattr(self.st, "count_calls", 0)
        n_before = len(self.st.log)
        r = run_cli(["--resume", d] + sizes, url=self.srv.url, stdin="SPEND UP TO $4.5\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.st.count_calls - calls_before, 1)         # only the unfinished size is counted
        for size in (2000, 3000):
            with open(os.path.join(d, str(size), "results.json")) as f:
                self.assertEqual(json.load(f)["status"], "complete")
        sent = [b for p, _, b in self.st.log[n_before:] if p == "/v1/messages"]
        self.assertEqual(len(sent), 16 - 2)       # size 3000 is 16 requests without the checks; its first two were done; size 2000 sends nothing


class ResumeRefusals(ResumeBase):
    def refuse(self, d, why=None, extra=()):
        n = len(self.st.log)
        r = self.run_resume(d, extra=extra)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("Refusing to resume", r.stdout)
        if why:
            self.assertIn(why, r.stdout)
        self.assertEqual(len(self.st.log), n, "a refused resume makes no request")
        self.assertNotIn("Traceback", r.stdout + r.stderr)

    def setUp(self):
        super().setUp()
        self.d = self.partial()

    def test_bad_numbers(self):
        for bad in (-1, 11, "1.0", True, None):
            self.edit(self.d, lambda doc, b=bad: doc.update(spent_usd=b))
            self.refuse(self.d, "spent_usd")
        with open(os.path.join(self.d, "results.json")) as f:
            txt = re.sub(r'"spent_usd": [^,}\n]+', '"spent_usd": NaN', f.read())
        with open(os.path.join(self.d, "results.json"), "w") as f:
            f.write(txt)
        self.refuse(self.d, "spent_usd")

    def test_spent_is_never_trusted_below_what_the_records_add_up_to(self):
        # a file that claims a lower spend than its records is not refused: the higher number is used for the cap
        self.edit(self.d, lambda doc: doc.update(spent_usd=0.0))
        r = self.run_resume(self.d, cap="0.00001")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(self.st.log), 0)

    def test_malformed_shapes(self):
        cases = {
            "config": lambda doc: doc.pop("config"),
            "records": lambda doc: doc.update(records="x"),
            "record": lambda doc: doc["records"][0].update(charged_usd=-3),
            "record kind": lambda doc: doc["records"][0].update(kind="evil"),
            "usage": lambda doc: doc["records"][0].update(usage={"input_tokens": "9"}),
            "completed_units": lambda doc: doc.update(completed_units=[[1, 99]]),
            "completed_units arm": lambda doc: doc.update(completed_units=[[7, 0]]),
            "marked done": lambda doc: doc.update(completed_units=doc["completed_units"] + [[4, 1]]),
            "checks_done": lambda doc: doc.update(checks_done="yes"),
            "status": lambda doc: doc.update(status=5),
            "abandoned": lambda doc: doc.update(abandoned_records_usd=-1),
        }
        for name, fn in cases.items():
            with self.subTest(name):
                self.setUp_fresh()
                self.edit(self.d, fn)
                self.refuse(self.d)

    def setUp_fresh(self):
        self.tearDown()
        StubCase.setUp(self)
        self.d = self.partial()

    def test_not_json_and_truncated_and_missing(self):
        path = os.path.join(self.d, "results.json")
        raw = open(path).read()
        for bad in ("not json", raw[:len(raw) // 2], "[]", ""):
            with open(path, "w") as f:
                f.write(bad)
            self.refuse(self.d)
        os.remove(path)
        n = len(self.st.log)
        r = self.run_resume(self.d)           # nothing saved for the size: it runs from scratch, with the saved spend still counted
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertGreater(len(self.st.log), n)

    def test_different_flags_are_refused(self):
        for extra in (["--turns", "3"], ["--reps", "3"], ["--model", "claude-sonnet-5-5"], ["--seed", "2"], ["--max-tokens", "65"],
                      ["--no-checks"], ["--nocache-reps", "2"], ["--reload-reps", "1"], ["--token-margin", "1.3"]):
            with self.subTest(extra):
                self.refuse(self.d, extra=extra)

    def test_a_folder_that_is_not_private_or_is_a_symlink_or_missing(self):
        os.chmod(self.d, 0o755)
        self.refuse(self.d, "private")
        os.chmod(self.d, 0o700)
        link = os.path.join(self.res, "link")
        os.symlink(self.d, link)
        self.refuse(link, "plain directory")
        self.refuse(os.path.join(self.res, "nope"), "does not exist")

    def test_old_partial_without_unit_list_is_refused(self):
        def old(doc):
            doc.pop("completed_units")
            doc.pop("checks_done")
        self.edit(self.d, old)
        self.refuse(self.d, "older version")

    def test_bad_probe_file(self):
        self.edit(self.d, lambda doc: doc.update(verdict="WHATEVER"), "probe.json")
        self.refuse(self.d, "probe.json")
        self.edit(self.d, lambda doc: doc.update(verdict="ACCEPTED", spent_usd=-4), "probe.json")
        self.refuse(self.d, "probe.json")

    def test_a_symlinked_results_file_is_refused(self):
        path = os.path.join(self.d, "results.json")
        other = os.path.join(self.res, "other.json")
        os.rename(path, other)
        os.symlink(other, path)
        self.refuse(self.d, "symbolic link")


class ResumeUnits(unittest.TestCase):
    def test_load_rejects_non_finite_helpers(self):
        self.assertFalse(resume._num(math.nan))
        self.assertFalse(resume._num(math.inf))
        self.assertFalse(resume._num(True))
        self.assertTrue(resume._num(0))
        self.assertFalse(resume._int(True))


if __name__ == "__main__":
    unittest.main()
