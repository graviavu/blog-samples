"""--tune: the three experiments on the stub, with a fake clock for the waits (in process) and the real CLI for the guards.
Stub only: no key, no network beyond 127.0.0.1."""
import json
import os
import re
import signal
import stat
import time
import unittest

from threads_test import client as C
from threads_test import pricing, tune, tune_report
from threads_test.runner import Guard
from tests.fake_api import Server
from tests.helpers import FAKE_KEY, StubCase, run_cli, spawn_tty

CLI_TUNE = ["--tune", "--tune-big", "4000", "--tune-small", "2000", "--tune-turns", "4", "--tune-max-tokens", "32", "--chars-per-token", "4.0",
            "--tune-keepalive-at", "0", "--tune-expiry-at", "0.1", "--tune-idle-limit", "0.05", "--tune-final-at", "0.2"]


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def time(self):
        return self.t

    def sleep(self, n):
        self.t += n


def cfg(**over):
    c = dict(model="claude-haiku-5-5", big=4000, small=2000, turns=4, max_tokens=32, margin=1.25, retries=1, effort="low", seed=1,
             salt_nonce="n1", cpt_big=4.0, cpt_small=4.0, max_usd=2.0, keepalive_at=240.0, expiry_at=340.0, final_at=480.0,
             idle_limit=300.0, probe_bound_usd=0.0)
    c.update(over)
    return c


class InProc(StubCase):
    """Tune against the stub with a fake clock shared with the stub (thread expiry and cache lifetimes follow the fake time)."""

    def setUp(self):
        super().setUp()
        self.fc = FakeClock()
        self.st.clock = self.fc.time
        self.st.expire_after = 300.0
        self.st.cache_ttl5 = 300.0
        self.st.cache_ttl1h = 3600.0
        self.logs = []

    def make(self, client=None, guard=None, sleep=None, **over):
        out = os.path.join(self.res, "t%d" % len(os.listdir(self.res)))
        os.makedirs(out, mode=0o700)
        t = tune.Tune(cfg(**over), client or C.Client(self.srv.url, FAKE_KEY), out, log=self.logs.append,
                      sleep=sleep or self.fc.sleep, clock=self.fc.time, guard=guard)
        return t, out

    def an(self, t):
        return t.doc()["analysis"]

    def bodies(self):
        return [b for path, h, b in self.st.log if path == "/v1/messages"]


class Wrap:
    """A client that delegates, with a hook on the Result of each post."""

    def __init__(self, inner, hook):
        self.inner, self.hook, self.n = inner, hook, 0

    def post(self, body, thread=False):
        self.n += 1
        return self.hook(self, body, self.inner.post(body, thread=thread))

    def close(self):
        self.inner.close()


class Robustness(InProc):
    def test_the_default_clock_is_wall_clock_time(self):
        import inspect
        self.assertIs(inspect.signature(tune.Tune.__init__).parameters["clock"].default, time.time)

    def test_a_run_on_schedule_has_no_lateness_note(self):
        t, _ = self.make()
        self.assertEqual(t.run(), 0)
        self.assertFalse([n for n in t.notes if "later than planned" in n], t.notes)

    def test_a_late_event_is_noted_in_the_notes_and_the_report(self):
        def hook(w, body, res):
            self.fc.t += 25.0   # each request "takes" 25 s, as if the machine slept
            return res
        t, out = self.make(client=Wrap(C.Client(self.srv.url, FAKE_KEY), hook))
        t.run()
        late = [n for n in t.notes if "later than planned" in n]
        self.assertTrue(late, t.notes)
        self.assertIn("slept", late[0])
        with open(os.path.join(out, "tune.md")) as f:
            self.assertIn("later than planned", f.read())

    def test_a_create_without_a_response_id_is_unknown_and_sends_no_continue(self):
        def hook(w, body, res):
            if (body.get("thread") or {}).get("type") == "create" and not w.__dict__.get("done"):
                w.done = True
                res.response_id = None
            return res
        t, _ = self.make(client=Wrap(C.Client(self.srv.url, FAKE_KEY), hook))
        t.run()
        a = self.an(t)
        self.assertTrue(a["e1"]["thread_expired"].startswith("UNKNOWN"), a["e1"]["thread_expired"])
        self.assertFalse([r for r in t.records if r["label"] == "continue_check"])
        for b in self.bodies():
            self.assertIsNot((b.get("thread") or {}).get("previous_message_id", 1), None)
        self.assertTrue([n for n in t.notes if "without a response id" in n], t.notes)


class Experiments(InProc):
    def test_all_three_succeed(self):
        t, out = self.make()
        code = t.run()
        self.assertEqual(code, 0, t.status)
        self.assertEqual(t.status, "complete")
        a = self.an(t)
        self.assertTrue(a["e1"]["thread_expired"].startswith("EXPIRED (verified)"), a["e1"]["thread_expired"])
        self.assertEqual(a["e1"]["continue_check"]["status"], 404)
        self.assertEqual(a["e1"]["continue_check"]["error_code"], "thread_not_found")
        self.assertTrue(a["e1"]["replay_read_1h_cache"].startswith("YES"), a["e1"]["replay_read_1h_cache"])
        self.assertTrue(a["e2"]["verdict"].startswith("RESET"), a["e2"]["verdict"])
        self.assertEqual(len(a["e3"]["rows"]), 4)
        self.assertEqual(a["n"]["e3_turns_per_arm"], 4)
        # the cold reload (fresh salt) wrote and read nothing, the replay read what the prime wrote
        e1 = a["e1"]
        self.assertEqual(e1["cold_reload"]["cache_read_tokens"], 0)
        self.assertGreater(e1["cold_reload"]["cache_creation_tokens"], 0)
        self.assertEqual(e1["prime"]["cache_read_tokens"], 0)
        self.assertEqual(e1["replay"]["cache_read_tokens"], e1["prime"]["cache_creation_tokens"])
        self.assertEqual(e1["replay"]["cache_creation_tokens"], 0)
        self.assertEqual(len([r for r in t.records if r["exp"] == "e1"]), 5)
        self.assertIn("replay_vs_cold", e1)

    def test_timeline_events_follow_the_plan_and_the_countdown_is_visible(self):
        t, _ = self.make()
        t.run()
        ev = {e["name"]: e for e in t.events}
        self.assertEqual(set(ev), {"e1_create", "e2_create", "e1_check", "e1_replay", "e1_cold", "e2_keepalive", "e2_real"})
        self.assertAlmostEqual(ev["e2_keepalive"]["actual_s"], 240, delta=11)
        self.assertAlmostEqual(ev["e1_check"]["actual_s"], 340, delta=11)
        self.assertAlmostEqual(ev["e2_real"]["actual_s"], 480, delta=11)
        order = [e["name"] for e in t.events]
        self.assertLess(order.index("e2_keepalive"), order.index("e1_check"))
        self.assertLess(order.index("e1_cold"), order.index("e2_real"))
        waits = [m for m in self.logs if "waiting" in m]
        self.assertGreater(len(waits), 30)
        self.assertIn("until e2_keepalive", waits[0])
        self.assertIn("Ctrl-C", waits[0])
        # experiment 3 ran during the waits: all its requests are before the keep-alive
        e3_end = max(r["t_end_s"] for r in t.records if r["exp"] == "e3")
        self.assertLess(e3_end - (ev["e1_create"]["actual_s"]), 240 + 1)

    def test_keepalive_not_reset(self):
        self.st.no_refresh = True
        t, _ = self.make()
        self.assertEqual(t.run(), 0)
        v = self.an(t)["e2"]["verdict"]
        self.assertTrue(v.startswith("NOT RESET (or the thread expired anyway)"), v)
        self.assertEqual(self.an(t)["e2"]["real_continue"]["status"], 404)

    def test_warm_replay_does_not_read_when_the_1h_lifetime_is_not_honoured(self):
        self.st.ignore_1h = True
        t, _ = self.make()
        self.assertEqual(t.run(), 0)
        e1 = self.an(t)["e1"]
        self.assertTrue(e1["replay_read_1h_cache"].startswith("NO:"), e1["replay_read_1h_cache"])
        self.assertEqual(e1["replay"]["cache_read_tokens"], 0)
        self.assertGreater(e1["replay"]["cache_creation_tokens"], 0)

    def test_thread_still_alive_is_reported_not_hidden(self):
        self.st.expire_after = None
        t, _ = self.make()
        self.assertEqual(t.run(), 0)
        a = self.an(t)
        self.assertTrue(a["e1"]["thread_expired"].startswith("NOT EXPIRED"), a["e1"]["thread_expired"])
        self.assertIsNotNone(a["e1"]["replay"])
        self.assertTrue(a["e2"]["verdict"].startswith("RESET"))

    def test_keepalive_after_the_thread_is_already_gone_is_unknown_and_skips_the_real_continue(self):
        self.st.expire_after = 100.0
        t, _ = self.make()
        self.assertEqual(t.run(), 0)
        a = self.an(t)
        self.assertTrue(a["e2"]["verdict"].startswith("UNKNOWN: the keep-alive itself got 404"), a["e2"]["verdict"])
        self.assertIsNone(a["e2"]["real_continue"])
        self.assertTrue(any("real continue was not sent" in n for n in t.notes))

    def test_growth_is_recorded(self):
        t, _ = self.make()
        t.run()
        g = self.an(t)["e2"]["growth"]
        self.assertIsInstance(g["added_by_keepalive_tokens_approx"], int)
        self.assertGreater(g["prompt_tokens_keepalive"], g["prompt_tokens_create"])
        self.assertGreater(g["prompt_tokens_real"], g["prompt_tokens_keepalive"])

    def test_1h_writes_are_priced_at_twice_input(self):
        t, _ = self.make()
        t.run()
        prime = [r for r in t.records if r["label"] == "prime"][0]
        w = prime["usage"]["cache_creation_input_tokens"]
        self.assertGreater(w, 0)
        self.assertEqual(prime["cache_creation_1h_reported"], w)
        self.assertAlmostEqual(prime["cost"]["cache_write"], w * 0.20 / 1e6, places=9)   # up to 100K tokens: input 0.10, 1h write 0.20
        cold = [r for r in t.records if r["label"] == "cold_reload"][0]
        self.assertAlmostEqual(cold["cost"]["cache_write"], cold["usage"]["cache_creation_input_tokens"] * 0.125 / 1e6, places=9)

    def test_cost_ttl_when_no_split_is_reported_prices_the_dearer_reading(self):
        u = {"input_tokens": 0, "cache_creation_input_tokens": 1000000, "cache_read_input_tokens": 0, "output_tokens": 0}
        self.assertAlmostEqual(pricing.cost_ttl("claude-haiku-5-5", dict(u, cache_creation_input_tokens=100000), None, True)["total"], 0.02)
        self.assertAlmostEqual(pricing.cost_ttl("claude-haiku-5-5", dict(u, cache_creation_input_tokens=100000), None, False)["total"], 0.0125)
        self.assertAlmostEqual(pricing.cost_ttl("claude-haiku-5-5", dict(u, cache_creation_input_tokens=100000), 40000, True)["total"], 0.008 + 0.0075)

    def test_request_shapes_and_salts(self):
        t, _ = self.make()
        t.run()
        bs = self.bodies()
        prime = bs[0]
        self.assertNotIn("thread", prime)                                    # a normal request
        self.assertEqual(prime["cache_control"], {"type": "ephemeral", "ttl": "1h"})
        systems = {}
        for b in bs:
            if "system" in b:
                systems.setdefault(b["system"], []).append(b)
        self.assertEqual(len(systems), 5, "five prefixes: e1, e1 cold, e2, e3 resend, e3 thread")
        e1 = [v for v in systems.values() if v[0]["cache_control"].get("ttl") == "1h"]
        self.assertEqual(len(e1), 1)
        self.assertEqual(len(e1[0]), 3)                                      # prime, thread create, replay: the same prefix
        self.assertEqual([b.get("thread", {}).get("type") for b in e1[0]], [None, "create", "create"])
        self.assertEqual(e1[0][0]["messages"], e1[0][2]["messages"])
        cold = [v for v in systems.values() if v[0]["cache_control"] == {"type": "ephemeral"} and v[0].get("thread") and len(v) == 1 and
                v[0]["messages"] == e1[0][0]["messages"]]
        self.assertEqual(len(cold), 1)
        conts = [b for b in bs if b.get("thread", {}).get("type") == "continue"]
        for b in conts:
            self.assertNotIn("system", b)
            self.assertNotIn("tools", b)
            self.assertEqual(len(b["messages"]), 1)
        # thread arm continues carry the cache_control of their create (a fixed field)
        self.assertTrue(all(b["cache_control"] in ({"type": "ephemeral"}, {"type": "ephemeral", "ttl": "1h"}) for b in conts))
        resend = [b for b in bs if "thread" not in b and b["cache_control"] == {"type": "ephemeral"}]
        self.assertEqual([len(b["messages"]) for b in resend], [len(resend[0]["messages"]) + 2 * k for k in range(5)])   # grows by two messages a turn

    def test_two_runs_do_not_share_cache_across_experiments(self):
        t, _ = self.make()
        t.run()
        a = self.an(t)
        # every first request of an experiment is cold
        for rec in t.records:
            if rec["label"] in ("prime", "cold_reload") or (rec["label"] in ("thread_create", "resend", "thread") and rec["turn"] == 0 and rec["exp"] != "e1"):
                self.assertEqual(rec["usage"]["cache_read_input_tokens"], 0, (rec["exp"], rec["label"]))
        self.assertGreater(a["e3"]["summary"]["turns_thread_lower"] + 1, 0)

    def test_a_500_is_retried(self):
        self.st.actions = ["500"]
        t, _ = self.make()
        self.assertEqual(t.run(), 0)
        self.assertEqual(t.records[0]["status"], 500)
        self.assertEqual(t.records[1]["attempt"], 2)
        self.assertEqual(t.records[1]["status"], 200)

    def test_one_experiment_failing_does_not_stop_the_others(self):
        class Bad(C.Client):
            def post(self, body, thread=False):
                if thread and body.get("cache_control", {}).get("ttl") == "1h":
                    r = C.Result()
                    r.status, r.error_type, r.error, r.error_code = 400, "invalid_request_error", {"error": {"type": "invalid_request_error", "message": "nope"}}, None
                    return r
                return super().post(body, thread)
        t, _ = self.make(client=Bad(self.srv.url, FAKE_KEY))
        code = t.run()
        self.assertEqual(code, 4)
        self.assertIn("e1", t.aborts)
        self.assertTrue(t.status.startswith("finished, but not every experiment completed"))
        a = self.an(t)
        self.assertEqual(len(a["e3"]["rows"]), 4)
        self.assertTrue(a["e2"]["verdict"].startswith("RESET"))
        self.assertIn("Stopped", open(os.path.join(t.outdir, "tune.md")).read())


class Stops(InProc):
    def test_billing_stop_mid_timeline_saves_partial_and_sends_nothing_more(self):
        self.st.error_after = 6
        self.st.error_shape = (400, "invalid_request_error", "Your credit balance is too low to access the Anthropic API. key %s" % FAKE_KEY, {})
        t, out = self.make()
        code = t.run()
        self.assertEqual(code, 5)
        self.assertTrue(t.status.startswith("PARTIAL: billing"), t.status)
        self.assertEqual(self.st.msg_requests, 7, "exactly one request after the error, no retry, no replay")
        self.assertEqual(t.partial["resume_with"], "not resumable")
        for name in ("tune.json", "tune.md"):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(out, name)).st_mode), 0o600)
        txt = open(os.path.join(out, "tune.json")).read() + open(os.path.join(out, "tune.md")).read()
        self.assertNotIn(FAKE_KEY, txt)
        self.assertIn("PARTIAL", txt)
        self.assertIn("not reached", txt)
        self.assertIn("cannot be resumed", txt)
        self.assertEqual(json.loads(open(os.path.join(out, "tune.json")).read())["requests"], 7)

    def test_billing_stop_in_the_waits_keeps_what_was_measured(self):
        self.st.error_after = 11   # prime, 2 creates, 8 of experiment 3 turns... then the first timed event
        self.st.error_shape = (402, "billing_error", "billing", {})
        t, _ = self.make()
        self.assertEqual(t.run(), 5)
        self.assertEqual(self.st.msg_requests, 12)
        self.assertGreater(len(self.an(t)["e3"]["rows"]), 0)

    def test_auth_stop_exit_6(self):
        self.st.error_after = 2
        self.st.error_shape = (401, "authentication_error", "invalid x-api-key", {})
        t, _ = self.make()
        self.assertEqual(t.run(), 6)
        self.assertEqual(self.st.msg_requests, 3)

    def test_ctrl_c_in_a_wait_writes_partial_and_prints_spend(self):
        def sleep(n):
            raise KeyboardInterrupt
        t, out = self.make(sleep=sleep)
        self.assertEqual(t.run(), 130)
        self.assertEqual(t.status, "PARTIAL: interrupted")
        doc = json.load(open(os.path.join(out, "tune.json")))
        self.assertTrue(doc["status"].startswith("PARTIAL"))
        self.assertGreater(doc["requests"], 0)
        self.assertTrue(any("Spent so far" in m for m in self.logs))

    def test_spend_cap_stops_before_a_request_that_could_cross_it(self):
        t, out = self.make(max_usd=0.0005, guard=Guard(0.0005))
        self.assertEqual(t.run(), 3)
        self.assertEqual(self.st.msg_requests, 0)
        self.assertTrue(t.status.startswith("PARTIAL: spend cap"))
        self.assertTrue(os.path.exists(os.path.join(out, "tune.json")))

    def test_spend_cap_mid_run_never_goes_over(self):
        t, _ = self.make(max_usd=0.0024, guard=Guard(0.0024))   # a whole stub run spends about $0.0027
        code = t.run()
        self.assertEqual(code, 3)
        self.assertLessEqual(t.guard.spent, 0.0024 + 1e-12)
        self.assertTrue(0 < self.st.msg_requests < 18, self.st.msg_requests)
        self.assertTrue(t.status.startswith("PARTIAL: spend cap"))


class Bound(unittest.TestCase):
    def pl(self, **kw):
        a = dict(model="claude-haiku-5-5", big=100000, small=20000, margin=1.25, turns=15, max_tokens=100, retries=1)
        a.update(kw)
        return tune.plan(a["model"], a["big"], a["small"], a["margin"], a["turns"], a["max_tokens"], a["retries"])

    def test_default_bound_with_the_probe_is_at_most_1_5_and_under_the_cap(self):
        from threads_test import probe
        total = self.pl()["total"] + probe.bound("claude-haiku-5-5")
        self.assertLessEqual(total, 1.5)
        self.assertGreater(total, 1.0)      # not accidentally tiny
        self.assertLessEqual(total, 2.0)

    def test_the_100k_price_step_is_taken_on_the_dearer_side(self):
        p = self.pl()["e1"]
        self.assertGreater(p["prompt_tokens_ub"], 100000)
        self.assertAlmostEqual(p["per_request_1h"], p["prompt_tokens_ub"] * 1.00 / 1e6 + 100 * 2.5 / 1e6)   # 1h write = 2 x 0.50
        self.assertAlmostEqual(p["per_request_cold"], p["prompt_tokens_ub"] * 0.625 / 1e6 + 100 * 2.5 / 1e6)

    def test_retries_double_the_bound_and_a_bigger_history_costs_more(self):
        self.assertAlmostEqual(self.pl(retries=1)["total"], 2 * self.pl(retries=0)["total"])
        self.assertGreater(self.pl(big=200000)["total"], self.pl()["total"])

    def test_the_bound_covers_what_the_stub_bills(self):
        # a stub run at the same sizes spends less than its own bound
        srv = Server().start()
        try:
            fc = FakeClock()
            srv.state.clock = fc.time
            import tempfile
            with tempfile.TemporaryDirectory() as d:
                t = tune.Tune(cfg(), C.Client(srv.url, FAKE_KEY), d, log=lambda m: None, sleep=fc.sleep, clock=fc.time)
                t.run()
                self.assertLessEqual(t.guard.spent, t.plan["total"])
        finally:
            srv.stop()


class Math(unittest.TestCase):
    def rec(self, **kw):
        base = {"status": 200, "ok": True, "error_code": None, "ttft_ms": 100.0, "total_ms": 200.0, "prompt_tokens": 1000, "input_tokens": 0,
                "cache_read_tokens": 900, "cache_creation_tokens": 100, "cache_creation_1h_reported": None, "output_tokens": 10, "cost_usd": 0.001,
                "charged_usd": 0.001, "attempts": 1, "t_start_s": 0.0, "t_end_s": 1.0}
        base.update(kw)
        return base

    def test_growth_summary_medians_ratios_and_cost(self):
        rows = []
        for k in range(1, 16):
            th, rs = 100.0 + k, 200.0 + 10 * k
            rows.append({"turn": k, "resend": self.rec(ttft_ms=rs, cost_usd=0.002), "thread": self.rec(ttft_ms=th, cost_usd=0.001), "ratio": th / rs})
        s = tune_report.exp3_summary(rows)
        self.assertEqual(s["window"], 5)
        self.assertEqual(s["first"]["turns"], [1, 2, 3, 4, 5])
        self.assertEqual(s["last"]["turns"], [11, 12, 13, 14, 15])
        self.assertEqual(s["first"]["thread_ttft_median_ms"], 103.0)
        self.assertEqual(s["first"]["resend_ttft_median_ms"], 230.0)
        self.assertEqual(s["last"]["thread_ttft_median_ms"], 113.0)
        self.assertEqual(s["last"]["resend_ttft_median_ms"], 330.0)
        self.assertAlmostEqual(s["first"]["ratio_of_medians"], 103.0 / 230.0)
        self.assertAlmostEqual(s["last"]["ratio_of_medians"], 113.0 / 330.0)
        self.assertAlmostEqual(s["thread_change_first_to_last_ms"], 10.0)
        self.assertAlmostEqual(s["resend_change_first_to_last_ms"], 100.0)
        self.assertEqual(s["thread_range_ms"], [101.0, 115.0])
        self.assertEqual(s["turns_thread_lower"], 15)
        self.assertEqual(s["first"]["thread_cost_median_usd"], 0.001)
        self.assertIsNone(tune_report.exp3_summary([]))

    def test_window_shrinks_for_few_turns(self):
        rows = [{"turn": k, "resend": self.rec(ttft_ms=100.0), "thread": self.rec(ttft_ms=50.0), "ratio": 0.5} for k in range(1, 5)]
        self.assertEqual(tune_report.exp3_summary(rows)["window"], 2)

    def test_keepalive_verdict_cases(self):
        c, k = self.rec(t_start_s=0, t_end_s=2), self.rec(t_start_s=240, t_end_s=241)
        ok = lambda s: self.rec(t_start_s=s, t_end_s=s + 1)   # noqa: E731
        notfound = lambda s: self.rec(status=404, ok=False, error_code="thread_not_found", t_start_s=s, t_end_s=s + 1)   # noqa: E731
        v = tune_report.keepalive_verdict
        self.assertTrue(v(c, k, ok(480), 300).startswith("RESET"))
        self.assertTrue(v(c, k, ok(280), 300).startswith("UNKNOWN"))                    # inside the limit even without a reset
        self.assertTrue(v(c, k, notfound(480), 300).startswith("NOT RESET"))
        self.assertTrue(v(c, k, notfound(560), 300).startswith("UNKNOWN"))              # over the limit since the keep-alive too
        self.assertTrue(v(c, k, self.rec(status=500, ok=False, t_start_s=480, t_end_s=481), 300).startswith("UNKNOWN"))
        self.assertTrue(v(c, notfound(240), None, 300).startswith("UNKNOWN: the keep-alive itself got 404"))
        self.assertTrue(v(c, k, None, 300).startswith("UNKNOWN"))
        self.assertTrue(v(None, k, None, 300).startswith("UNKNOWN"))

    def test_growth_formula(self):
        c = self.rec(prompt_tokens=20000, output_tokens=30)
        k = self.rec(prompt_tokens=20045, output_tokens=5)
        g = tune_report.growth(c, k, self.rec(prompt_tokens=20100))
        self.assertEqual(g["added_by_keepalive_tokens_approx"], (20045 - 20000 - 30) + 5)
        self.assertIsNone(tune_report.growth(c, self.rec(ok=False), None))

    def test_cache_verdict_cases(self):
        v = tune_report.cache_verdict
        prime = self.rec(cache_read_tokens=0, cache_creation_tokens=1000, cache_creation_1h_reported=1000)
        self.assertTrue(v(prime, self.rec(prompt_tokens=1000, cache_read_tokens=1000, cache_creation_tokens=0)).startswith("YES"))
        self.assertTrue(v(prime, self.rec(prompt_tokens=1000, cache_read_tokens=0, cache_creation_tokens=1000)).startswith("NO:"))
        self.assertTrue(v(prime, self.rec(prompt_tokens=1000, cache_read_tokens=400, cache_creation_tokens=600)).startswith("PARTLY"))
        self.assertTrue(v(self.rec(cache_creation_tokens=0), self.rec()).startswith("UNKNOWN"))
        self.assertTrue(v(prime, self.rec(ok=False, status=500)).startswith("UNKNOWN"))
        self.assertTrue(v(None, self.rec()).startswith("UNKNOWN"))
        self.assertIn("UNKNOWN whether the entry was written with the 1-hour", v(self.rec(cache_creation_tokens=1000, cache_creation_1h_reported=None), self.rec(cache_read_tokens=1000)))

    def test_cache_verdict_requires_the_1h_part_of_the_write(self):
        v = tune_report.cache_verdict
        rep = self.rec(prompt_tokens=1000, cache_read_tokens=1000, cache_creation_tokens=0)
        for split in (0, 500, 899):
            r = v(self.rec(cache_creation_tokens=1000, cache_creation_1h_reported=split), rep)
            self.assertTrue(r.startswith("read a cache, but the entry was 5m"), r)
        self.assertTrue(v(self.rec(cache_creation_tokens=1000, cache_creation_1h_reported=900), rep).startswith("YES"))
        self.assertTrue(v(self.rec(cache_creation_tokens=1000, cache_creation_1h_reported=None), rep).startswith("YES"))
        self.assertIn("UNKNOWN whether", v(self.rec(cache_creation_tokens=1000, cache_creation_1h_reported=None), rep))

    def test_expiry_verdict(self):
        c = self.rec(t_start_s=0, t_end_s=3)
        e = tune_report.expiry_verdict
        self.assertTrue(e(c, self.rec(status=404, ok=False, error_code="thread_not_found", t_start_s=340)).startswith("EXPIRED (verified)"))
        self.assertTrue(e(c, self.rec(t_start_s=340)).startswith("NOT EXPIRED"))
        self.assertTrue(e(c, self.rec(status=400, ok=False, error_code="x", t_start_s=340)).startswith("UNKNOWN"))


class CliTune(StubCase):
    def go(self, extra=(), cap="2", confirm=None, **kw):
        confirm = "SPEND UP TO $%s\n" % cap if confirm is None else confirm
        return run_cli(CLI_TUNE + ["--results-dir", self.res] + list(extra), url=self.srv.url, stdin=confirm, **kw)

    def only_private(self, root):
        n = 0
        for dirpath, _, files in os.walk(root):
            self.assertEqual(stat.S_IMODE(os.stat(dirpath).st_mode), 0o700, dirpath)
            for fn in files:
                self.assertEqual(stat.S_IMODE(os.stat(os.path.join(dirpath, fn)).st_mode), 0o600, fn)
                n += 1
        self.assertGreater(n, 0)

    def test_dry_run_prints_the_bound_and_sends_nothing(self):
        r = run_cli(["--tune", "--dry-run"], url=self.srv.url)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        m = re.search(r"PLANNED UPPER BOUND\s+\$([0-9.]+)\s+\(cap \$2.00", r.stdout)
        self.assertTrue(m, r.stdout)
        self.assertLessEqual(float(m.group(1)), 1.5)
        self.assertEqual(self.st.log, [])
        self.assertFalse(os.path.exists(os.path.join(self.res, "x")))

    def test_the_default_run_is_still_the_dry_run(self):
        r = run_cli([], url=self.srv.url)
        self.assertEqual(r.returncode, 0)
        self.assertIn("Dry run: no network call made", r.stdout)
        self.assertNotIn("TUNE", r.stdout)
        self.assertEqual(self.st.log, [])

    def test_full_run_with_its_own_phrase(self):
        r = self.go()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("To go ahead type exactly: SPEND UP TO $2\n", r.stdout)
        self.assertIn("cannot be resumed", r.stdout)
        d = os.path.join(self.res, os.listdir(self.res)[0])
        self.assertEqual(sorted(os.listdir(d)), ["probe.json", "tune.json", "tune.md"])
        doc = json.load(open(os.path.join(d, "tune.json"), encoding="utf-8"))
        self.assertEqual(doc["status"], "complete")
        self.assertLessEqual(doc["planned_upper_bound_usd"], 1.5)
        self.assertEqual(len(doc["analysis"]["e3"]["rows"]), 4)
        md = open(os.path.join(d, "tune.md")).read()
        for needle in ("Did the replay read the 1-hour cache?", "Idle timer reset by the keep-alive?", "median TTFT", "Exact n:", "One machine, one network, one day"):
            self.assertIn(needle, md)
        self.only_private(self.res)
        txt = r.stdout + r.stderr + self.all_text()
        self.assertNotIn(FAKE_KEY, txt)
        self.assertIsNone(re.search(r"msg_[0-9a-f]{20}", txt))
        self.assertIsNone(re.search(r"req_01", txt))
        # probe first, then the experiments; the probe's three requests come first
        first = [b for p, h, b in self.st.log if p == "/v1/messages"][:3]
        self.assertTrue(all("system" not in b for b in first))

    def test_a_wrong_phrase_or_the_default_cap_phrase_makes_no_call(self):
        for text in ("SPEND UP TO $4.5\n", "spend up to $2\n", "\n", "yes\n"):
            r = self.go(confirm=text)
            self.assertEqual(r.returncode, 2, r.stdout)
            self.assertIn("Not confirmed. No calls made.", r.stdout)
        self.assertEqual(self.st.log, [])
        self.assertEqual(os.listdir(self.res), [])

    def test_the_phrase_must_come_from_a_terminal(self):
        r = self.go(pipe_stdin=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("must be typed at a terminal", r.stdout)
        self.assertEqual(self.st.log, [])

    def test_no_request_before_the_phrase_is_typed(self):
        p, master = spawn_tty(CLI_TUNE + ["--results-dir", self.res], self.srv.url)
        try:
            time.sleep(1.5)
            self.assertEqual(self.st.log, [])
            os.write(master, b"SPEND UP TO $2\n")
            out, err = p.communicate(timeout=60)
        finally:
            os.close(master)
        self.assertEqual(p.returncode, 0, out + err)
        self.assertGreater(len(self.st.log), 0)

    def test_no_key_and_no_network_before_the_phrase(self):
        r = run_cli(CLI_TUNE + ["--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $2\n", key="")
        self.assertEqual(r.returncode, 2)
        self.assertIn("ANTHROPIC_API_KEY", r.stdout)
        self.assertEqual(self.st.log, [])

    def test_cap_refusals(self):
        r = run_cli(["--tune", "--max-usd", "0.5", "--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $0.5\n")
        self.assertEqual(r.returncode, 2)
        self.assertIn("EXCEEDS THE CAP", r.stdout)
        self.assertIn("Refusing to start", r.stdout)
        r = self.go(["--max-usd", "3"], cap="3")
        self.assertEqual(r.returncode, 2)
        self.assertIn("at most --max-usd 2", r.stdout)
        r = self.go(["--max-usd", "inf"], cap="2")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.st.log, [])

    def test_a_bigger_history_that_breaks_the_bound_is_refused_before_any_call(self):
        r = run_cli(["--tune", "--tune-big", "400000", "--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $2\n")
        self.assertEqual(r.returncode, 2)
        self.assertIn("EXCEEDS THE CAP", r.stdout)
        self.assertEqual(self.st.log, [])

    def test_host_allowlist_still_applies(self):
        r = run_cli(CLI_TUNE + ["--results-dir", self.res], url="https://evil.example.com", stdin="SPEND UP TO $2\n")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not api.anthropic.com", r.stdout)

    def test_tune_does_not_mix_with_the_other_modes(self):
        for other in (["--all"], ["--run"], ["--probe"], ["--resume", self.res], ["--skip-probe"]):
            r = run_cli(CLI_TUNE + other, url=self.srv.url, stdin="SPEND UP TO $2\n")
            self.assertEqual(r.returncode, 2, other)
        self.assertEqual(self.st.log, [])

    def test_bad_timeline_flags(self):
        for bad in (["--tune-keepalive-at", "5", "--tune-final-at", "5"], ["--tune-expiry-at", "-1"], ["--tune-turns", "1"], ["--tune-keepalive-at", "nan"],
                    ["--tune-expiry-at", "300"], ["--tune-expiry-at", "100", "--tune-idle-limit", "300"]):
            r = run_cli(["--tune", "--dry-run"] + bad, url=self.srv.url)
            self.assertEqual(r.returncode, 2, bad)

    def test_a_rejected_probe_stops_before_the_experiments(self):
        self.st.reject_threads = True
        r = self.go()
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertIn("did not say ACCEPTED", r.stdout)
        self.assertLessEqual(len(self.st.log), 4)
        d = os.path.join(self.res, os.listdir(self.res)[0])
        self.assertEqual(sorted(os.listdir(d)), ["probe.json"])

    def test_billing_error_mid_timeline_via_the_cli(self):
        self.st.error_after = 3 + 5    # the probe's 3 requests, then 5 of the experiments
        self.st.error_shape = (400, "invalid_request_error", "Your credit balance is too low to access the Anthropic API. %s" % FAKE_KEY, {})
        r = self.go()
        self.assertEqual(r.returncode, 5, r.stdout + r.stderr)
        self.assertIn("STOPPED", r.stdout)
        self.assertIn("--tune cannot be resumed", r.stdout)
        self.assertNotIn("--resume", r.stdout.replace("cannot be resumed", ""))
        self.assertEqual(self.st.msg_requests, 3 + 5 + 1)
        d = os.path.join(self.res, os.listdir(self.res)[0])
        doc = json.load(open(os.path.join(d, "tune.json"), encoding="utf-8"))
        self.assertTrue(doc["status"].startswith("PARTIAL: billing"))
        self.assertIn("PARTIAL", open(os.path.join(d, "tune.md")).read())
        self.only_private(self.res)
        self.assertNotIn(FAKE_KEY, r.stdout + r.stderr + self.all_text())

    def test_ctrl_c_during_the_wait_exits_130_with_partial_files(self):
        args = [a for a in CLI_TUNE]
        args[args.index("--tune-final-at") + 1] = "60"
        p, master = spawn_tty(args + ["--results-dir", self.res], self.srv.url, text="SPEND UP TO $2\n")
        try:
            deadline = time.time() + 30
            while time.time() < deadline:
                if os.path.isdir(self.res) and any(os.path.exists(os.path.join(self.res, d, "tune.json")) and "e2_keepalive" in open(os.path.join(self.res, d, "tune.json")).read()
                                                    for d in os.listdir(self.res)):
                    break
                time.sleep(0.1)
            time.sleep(0.5)
            p.send_signal(signal.SIGINT)
            out, err = p.communicate(timeout=60)
        finally:
            os.close(master)
        self.assertEqual(p.returncode, 130, out + err)
        self.assertIn("Spent so far", out)
        self.assertIn("waiting", out)
        d = os.path.join(self.res, os.listdir(self.res)[0])
        self.assertTrue(json.load(open(os.path.join(d, "tune.json"), encoding="utf-8"))["status"].startswith("PARTIAL"))

    def test_the_existing_all_mode_is_unchanged_by_the_new_flags(self):
        from tests.helpers import SMALL
        r = run_cli(["--all"] + SMALL + ["--max-usd", "4.5", "--results-dir", self.res], url=self.srv.url, stdin="SPEND UP TO $4.5\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("TUNE", r.stdout)
        d = os.path.join(self.res, os.listdir(self.res)[0])
        self.assertNotIn("tune.json", os.listdir(d))


if __name__ == "__main__":
    unittest.main()
