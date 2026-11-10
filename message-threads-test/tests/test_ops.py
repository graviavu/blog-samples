"""run-ops-test.sh: tests B+, E and A against the stub, the cost cap, the dry run and the wrapper script.
Stub only: no key, no network beyond 127.0.0.1."""
import json
import os
import stat
import subprocess
import tempfile
import time
import unittest

from threads_test import client as C
from threads_test import convo, ops, ops_report, pricing
from threads_test.runner import Guard
from tests.fake_api import Server
from tests.helpers import FAKE_KEY, OPS_CLI, ROOT, StubCase, env_for, run_cli

SH = os.path.join(ROOT, "run-ops-test.sh")
SMALL_OPS = ["--b-tokens", "3000", "--e-tokens", "3000", "--a-tokens", "3000", "--b-rates", "50,100", "--e-runs", "2", "--a-turns", "5",
             "--a-fork-at", "2", "--max-tokens", "32", "--e-max-tokens", "64", "--chars-per-token", "4.0"]


def cfg(**over):
    c = dict(model="claude-haiku-5-5", tests=["B", "E", "A"], b_tokens=3000, rates=[50.0, 100.0], b_reps=1, e_runs=2, e_tokens=3000, e_max_tokens=64,
             a_tokens=3000, a_turns=5, a_fork_at=2, max_tokens=32, margin=1.25, effort="low", seed=1, salt_nonce="n1",
             cpt={3000: 4.0}, max_usd=0.60, probe_bound_usd=0.0)
    c.update(over)
    return c


def ops_cli(args, url=None, stdin="", **kw):
    return run_cli(args, url=url, stdin=stdin, cli=OPS_CLI, **kw)


class Wrap:
    """A client that delegates and lets a hook change the Result of a post."""

    def __init__(self, inner, hook):
        self.inner, self.hook, self.n = inner, hook, 0

    def post(self, body, thread=False, **kw):
        self.n += 1
        return self.hook(self, body, self.inner.post(body, thread=thread, **kw))

    def close(self):
        self.inner.close()


class InProc(StubCase):
    def make(self, client=None, guard=None, **over):
        out = os.path.join(self.res, "o%d" % len(os.listdir(self.res)))
        os.makedirs(out, mode=0o700)
        self.logs = []
        o = ops.Ops(cfg(**over), client or C.Client(self.srv.url, FAKE_KEY), out, log=self.logs.append, guard=guard)
        return o, out

    def bodies(self):
        return [b for path, h, b in self.st.log if path == "/v1/messages"]

    def an(self, o):
        return o.doc()["analysis"]


class Client(StubCase):
    def body(self, n=50000):
        return {"model": "claude-haiku-5-5", "max_tokens": 16, "stream": True, "messages": [{"role": "user", "content": "x" * n}],
                "cache_control": {"type": "ephemeral"}}

    def test_body_bytes_are_the_bytes_the_server_got(self):
        c = C.Client(self.srv.url, FAKE_KEY)
        b = self.body()
        r = c.post(b, measure_upload=True)
        self.assertTrue(r.ok)
        self.assertEqual(r.body_bytes, len(json.dumps(b).encode()))
        self.assertIsNotNone(r.body_sent_s)
        self.assertEqual(self.st.log[-1][2], b)

    def test_the_plain_post_is_unchanged(self):
        c = C.Client(self.srv.url, FAKE_KEY)
        r = c.post(self.body(100))
        self.assertTrue(r.ok)
        self.assertIsNone(r.body_sent_s)
        self.assertEqual(r.body_bytes, len(json.dumps(self.body(100)).encode()))

    def test_the_throttle_paces_the_upload(self):
        c = C.Client(self.srv.url, FAKE_KEY)
        b = self.body(100000)                 # about 100 KB = 0.8 Mbit
        n = len(json.dumps(b).encode())
        t0 = time.perf_counter()
        r = c.post(b, rate_bps=2e6)           # 2 Mbps: about 0.4 s
        self.assertTrue(r.ok)
        floor = n * 8.0 / 2e6
        self.assertGreaterEqual(r.body_sent_s, floor * 0.98)
        self.assertLess(r.body_sent_s, floor + 1.0)
        self.assertGreaterEqual(r.ttft, r.body_sent_s)    # TTFT includes the upload
        self.assertGreaterEqual(time.perf_counter() - t0, floor * 0.98)
        free = c.post(b, measure_upload=True)
        self.assertLess(free.body_sent_s, floor / 2)

    def test_abort_after_the_first_delta_is_before_message_stop(self):
        c = C.Client(self.srv.url, FAKE_KEY)
        r = c.post(self.body(100), abort_after_delta=True)
        self.assertEqual(r.status, 200)
        self.assertTrue(r.aborted)
        self.assertFalse(r.complete)
        self.assertFalse(r.ok)
        self.assertIsNone(r.exception)
        self.assertTrue(r.usage.get("input_tokens", 0) + r.usage.get("cache_creation_input_tokens", 0) > 0)   # message_start usage
        self.assertEqual(len(self.st.log), 1)


class TestB(InProc):
    def test_rows_bytes_and_bytes_per_token(self):
        o, out = self.make(tests=["B"])
        self.assertEqual(o.run(), 0, o.status)
        recs = [r for r in o.records if r["test"] == "B"]
        self.assertEqual(len(recs), 1 + 9)
        b = self.an(o)["B"]
        self.assertEqual([(r["cond"], r["arm"]) for r in b["rows"]],
                         [(c, a) for c in ("open", "50Mbps", "100Mbps") for a in ("resend", "create", "continue")])
        by = {(r["cond"], r["arm"]): r for r in b["rows"]}
        # a continue carries a few hundred bytes, a resend and a create the whole history
        self.assertLess(by[("open", "continue")]["body_bytes"] * 5, by[("open", "resend")]["body_bytes"])
        self.assertAlmostEqual(by[("open", "create")]["body_bytes"], by[("open", "resend")]["body_bytes"], delta=400)
        for r in b["rows"]:
            self.assertGreaterEqual(r["upload_ms"], 0)
            self.assertLessEqual(r["upload_ms"], r["ttft_ms"] + 1)
            self.assertAlmostEqual(r["ttft_after_upload_ms"], r["ttft_ms"] - r["upload_ms"], places=3)
        for k in (("50Mbps", "resend"), ("100Mbps", "create")):
            self.assertIsNotNone(by[k]["arithmetic_upload_ms"])
            self.assertGreaterEqual(by[k]["upload_ms"], by[k]["arithmetic_upload_ms"] * 0.98)
        self.assertIsNone(by[("open", "resend")]["arithmetic_upload_ms"])
        # measured bytes per token is body bytes over the prompt tokens of the usage field
        resend = [r for r in recs if r["label"].startswith("resend open")][0]
        self.assertAlmostEqual(b["bytes_per_token"]["resend"], resend["body_bytes"] / pricing.prompt_len(resend["usage"]), places=6)
        self.assertGreater(b["bytes_per_token"]["resend"], 1.0)
        self.assertEqual([p["tokens"] for p in b["projection"]], [100000, 500000, 1000000])
        p0 = b["projection"][0]
        self.assertAlmostEqual(p0["bytes"], 100000 * b["bytes_per_token"]["resend"])
        self.assertAlmostEqual(p0["seconds"]["1"], p0["bytes"] * 8 / 1e6)

    def test_every_request_shape(self):
        o, _ = self.make(tests=["B"])
        o.run()
        bs = self.bodies()
        self.assertEqual(len(bs), 10)
        creates = [b for b in bs if (b.get("thread") or {}).get("type") == "create"]
        conts = [b for b in bs if (b.get("thread") or {}).get("type") == "continue"]
        plain = [b for b in bs if "thread" not in b]
        self.assertEqual((len(creates), len(conts), len(plain)), (3, 3, 4))      # prime + 3 resends are plain
        for b in conts:
            self.assertNotIn("system", b)
            self.assertNotIn("tools", b)
            self.assertEqual(len(b["messages"]), 1)
            self.assertEqual(b["cache_control"], {"type": "ephemeral"})
        for b in plain + creates:
            self.assertEqual(b["cache_control"], {"type": "ephemeral"})
            self.assertTrue(b["system"].startswith("[salt "))
        self.assertEqual(len({b["system"] for b in plain + creates}), 1)        # one prefix: the prime warms every later request
        # warm requests read what the prime wrote
        warm = [r for r in o.records[1:] if r["label"].startswith(("resend", "create"))]
        self.assertTrue(all(r["usage"]["cache_read_input_tokens"] > 0 for r in warm))
        self.assertEqual(o.records[0]["usage"]["cache_read_input_tokens"], 0)

    def test_the_throttle_shows_in_the_upload_column(self):
        o, _ = self.make(tests=["B"], b_tokens=12000, rates=[4.0], cpt={12000: 4.0})
        o.run()
        rows = {(r["cond"], r["arm"]): r for r in self.an(o)["B"]["rows"]}
        slow, free = rows[("4Mbps", "resend")], rows[("open", "resend")]
        self.assertGreater(slow["upload_ms"], 5 * free["upload_ms"])
        self.assertGreaterEqual(slow["upload_ms"], slow["arithmetic_upload_ms"] * 0.98)
        self.assertGreaterEqual(slow["ttft_ms"], slow["upload_ms"])

    def test_a_failed_request_stops_b_but_not_the_others(self):
        def hook(w, body, res):
            if (body.get("thread") or {}).get("type") == "create" and not w.__dict__.get("hit"):
                w.hit = True
                res.status, res.complete, res.error_code = 500, False, None
            return res
        o, out = self.make(client=Wrap(C.Client(self.srv.url, FAKE_KEY), hook), tests=["B", "A"])
        code = o.run()
        self.assertEqual(code, 4)
        self.assertIn("B", o.aborts)
        self.assertNotIn("A", o.aborts)
        self.assertEqual(len([r for r in o.records if r["test"] == "A"]), 5 + 2)
        with open(os.path.join(out, "ops.md")) as f:
            self.assertIn("Tests that did not complete", f.read())


class TestE(InProc):
    def test_five_runs_cut_retry_replay(self):
        o, out = self.make(tests=["E"], e_runs=5)
        self.assertEqual(o.run(), 0, o.status)
        bs = self.bodies()
        self.assertEqual(len(bs), 20)
        for i in range(5):
            create, cut, again, replay = bs[4 * i:4 * i + 4]
            self.assertEqual(create["thread"], {"type": "create"})
            self.assertEqual(cut, again)                                  # the SAME continue, byte for byte
            self.assertEqual(cut["thread"]["type"], "continue")
            self.assertEqual(replay["thread"], {"type": "create"})
            self.assertGreater(len(replay["messages"]), len(create["messages"]))   # the full local history plus the new message
        e = self.an(o)["E"]
        self.assertEqual(len(e["runs"]), 5)
        # the stub marks an id as continued when the first continue arrives, so the retry comes back already_continued every time
        self.assertEqual(e["counts"], {"thread_already_continued": 5})
        for r in e["runs"]:
            self.assertTrue(r["cut"]["aborted"])
            self.assertTrue(r["replay"]["ok"])
            self.assertGreater(r["replay"]["cache_read_tokens"], 0)
        cut = [r for r in o.records if r["label"].startswith("continue cut")]
        self.assertTrue(all(r["aborted"] and not r["complete"] and r["usage"]["input_tokens"] + r["usage"]["cache_read_input_tokens"] > 0 for r in cut))
        b = e["billing"]
        self.assertEqual((b["complete_requests"], b["cut_requests"]), (10, 5))      # create and replay; the cut ones and the refused repeat do not count
        self.assertEqual(b["complete_usage"]["output_tokens"], sum(r["usage"]["output_tokens"] for r in o.records if r["complete"]))
        self.assertTrue(b["window_utc"][0] and b["window_utc"][1])
        with open(os.path.join(out, "ops.md")) as f:
            md = f.read()
        self.assertIn("Billing check for the Console", md)
        self.assertIn("thread_already_continued 5", md)

    def test_other_outcomes_are_counted(self):
        def hook(w, body, res):
            if body.get("thread", {}).get("type") == "continue" and not res.aborted:
                w.k = w.__dict__.get("k", 0) + 1
                if w.k == 1:
                    res.status, res.complete, res.error_code = 400, False, "thread_continue_in_flight"
                # k == 2 is left alone: the stub answers 400 thread_already_continued, which is counted as such
                elif w.k == 3:
                    res.status, res.complete, res.error_code = 404, False, "thread_not_found"
            return res
        o, _ = self.make(client=Wrap(C.Client(self.srv.url, FAKE_KEY), hook), tests=["E"], e_runs=3)
        o.run()
        counts = self.an(o)["E"]["counts"]
        self.assertEqual(counts.get("thread_continue_in_flight"), 1)
        self.assertEqual(counts.get("thread_not_found"), 1)
        self.assertEqual(counts.get("thread_already_continued"), 1)
        self.assertEqual(sum(counts.values()), 3)

    def test_outcome_names(self):
        self.assertEqual(ops_report.outcome(200, True, None), "success")
        self.assertEqual(ops_report.outcome(400, False, "thread_already_continued"), "thread_already_continued")
        self.assertEqual(ops_report.outcome(400, False, "thread_continue_in_flight"), "thread_continue_in_flight")
        self.assertTrue(ops_report.outcome(None, False, None).startswith("no response"))
        self.assertEqual(ops_report.outcome(500, False, None), "other (HTTP 500 no code)")

    def test_a_cut_that_did_not_cut_is_flagged_in_the_report(self):
        o, out = self.make(tests=["E"], e_runs=1)
        o.run()
        # a cut request that came back as a normal answer would be reported with its status, not as cut
        for r in o.records:
            if r["label"].startswith("continue cut"):
                r["aborted"], r["status"] = False, 200
        md = ops_report.render_md(dict(o.doc(), analysis=ops_report.analyze(dict(o.doc(), records=o.records))))
        self.assertIn("NOT cut", md)


class TestA(InProc):
    def test_two_forks_read_the_entry_written_at_turn_n(self):
        o, out = self.make(tests=["A"])
        self.assertEqual(o.run(), 0, o.status)
        a = self.an(o)["A"]
        n = 2
        self.assertEqual(a["fork_at"], n)
        main = {t["turn"]: t for t in a["turns"]}
        self.assertEqual(len(main), 5)
        self.assertEqual(a["expected_read_tokens"], main[n]["prompt_tokens"])
        self.assertEqual(len(a["forks"]), 2)
        for f in a["forks"]:
            self.assertEqual(f["read"], main[n]["prompt_tokens"])
            self.assertTrue(f["verdict"].startswith("HIT"), f["verdict"])
            self.assertGreater(f["cost_usd"], 0)
            self.assertIsNotNone(f["ttft_ms"])
        # the forks are the same prefix with different last messages
        bs = self.bodies()
        f1, f2 = bs[-2], bs[-1]
        self.assertEqual(f1["messages"][:-1], f2["messages"][:-1])
        self.assertNotEqual(f1["messages"][-1], f2["messages"][-1])
        self.assertEqual(f1["messages"][:-2], bs[n]["messages"])                 # the prefix is turn n's request
        self.assertNotIn("thread", f1)
        self.assertEqual(f1["cache_control"], {"type": "ephemeral"})
        self.assertIsNotNone(a["next_main_turn"])
        with open(os.path.join(out, "ops.md")) as f:
            self.assertIn("HIT: read the entry written at turn 2", f.read())

    def test_a_fork_that_misses_the_cache_is_called_a_miss(self):
        self.st.cache_ttl5 = 0.0                     # every cache entry is dead on arrival
        o, _ = self.make(tests=["A"])
        o.run()
        for f in self.an(o)["A"]["forks"]:
            self.assertEqual(f["read"], 0)
            self.assertTrue(f["verdict"].startswith("MISS"), f["verdict"])

    def _recs(self, read, n=2):
        def rec(label, prompt, rd):
            return {"test": "A", "label": label, "status": 200, "complete": True, "usage": {"input_tokens": prompt - rd, "cache_creation_input_tokens": 0, "cache_read_input_tokens": rd, "output_tokens": 1},
                    "cost": {"total": 0.001}, "ttft_ms": 5.0}
        return [rec("turn 0", 1000, 0), rec("turn 1", 1100, 1000), rec("turn 2", 1200, 1100), rec("turn 3", 1300, 1200), rec("fork A at turn 2", 1250, read), rec("fork B at turn 2", 1250, read)]

    def test_verdicts(self):
        self.assertTrue(ops_report.analyze_a(self._recs(1200))["forks"][0]["verdict"].startswith("HIT"))
        self.assertTrue(ops_report.analyze_a(self._recs(1100))["forks"][0]["verdict"].startswith("EARLIER ENTRY ONLY"))
        self.assertTrue(ops_report.analyze_a(self._recs(500))["forks"][0]["verdict"].startswith("PARTIAL"))
        self.assertTrue(ops_report.analyze_a(self._recs(0))["forks"][0]["verdict"].startswith("MISS"))

    def test_the_history_grows_each_turn(self):
        o, _ = self.make(tests=["A"])
        o.run()
        pls = [pricing.prompt_len(r["usage"]) for r in o.records if r["label"].startswith("turn ")]
        self.assertEqual(pls, sorted(pls))
        self.assertGreater(pls[-1] - pls[0], 3 * 200)


class Money(InProc):
    def test_the_default_estimate_is_under_the_default_cap(self):
        c = cfg(b_tokens=100000, e_tokens=20000, a_tokens=20000, rates=[1.0, 5.0], e_runs=5, a_turns=10, a_fork_at=5, max_tokens=100, e_max_tokens=300, cpt={})
        pl = ops.plan(c)
        self.assertLess(pl["expected"], 0.60)
        self.assertGreater(pl["expected"], 0.05)
        self.assertGreater(pl["worst"], pl["expected"])
        self.assertEqual(pl["tests"]["B"]["requests"], 10)
        self.assertEqual(pl["tests"]["E"]["requests"], 20)
        self.assertEqual(pl["tests"]["A"]["requests"], 12)

    def test_the_100k_history_is_priced_on_the_dearer_side_of_the_step(self):
        pl = ops.plan(cfg(b_tokens=100000, tests=["B"], cpt={}))
        ub = pl["tests"]["B"]["prompt_tokens_ub"]
        self.assertGreater(ub, 100000)
        self.assertEqual(pricing.tier("claude-haiku-5-5", ub)[2], 0.625)

    def test_the_estimate_covers_what_the_stub_bills(self):
        o, _ = self.make()
        self.assertEqual(o.run(), 0, o.status)
        self.assertLessEqual(o.guard.spent, o.plan["expected"])
        self.assertGreater(o.guard.spent, 0)

    def test_the_cap_stops_the_run_and_never_goes_over(self):
        o, out = self.make(guard=Guard(0.0005), max_usd=0.0005)
        self.assertEqual(o.run(), 3)
        self.assertTrue(o.status.startswith("PARTIAL: spend cap"), o.status)
        self.assertLessEqual(o.guard.spent, 0.0005)
        self.assertLess(len(self.bodies()), 10)
        self.assertTrue(os.path.exists(os.path.join(out, "ops.md")))

    def test_inflated_usage_stops_at_the_cap(self):
        self.st.usage_scale = 400
        o, _ = self.make(guard=Guard(0.05), max_usd=0.05)
        code = o.run()
        self.assertIn(code, (3, 4))
        self.assertLess(len(self.bodies()), 42)
        self.assertTrue(o.status.startswith(("PARTIAL: spend cap", "finished, but")), o.status)

    def test_a_prompt_bigger_than_the_margin_stops_that_test_before_more_full_size_requests(self):
        self.st.count_scale = 1
        o, _ = self.make(tests=["B"], b_tokens=1000, cpt={1000: 4.0})     # asked 1000 tokens, the history sent is 3000 worth
        o.hist["B"] = convo.build_history(1, 3000, 4.0)
        self.assertEqual(o.run(), 4)
        self.assertIn("estimate no longer holds", o.aborts["B"])
        self.assertEqual(len(self.bodies()), 1)

    def test_billing_error_stops_at_once_with_partial_files(self):
        self.st.error_after = 3
        self.st.error_shape = (402, "billing_error", "Your credit balance is too low", {})
        o, out = self.make()
        self.assertEqual(o.run(), 5)
        self.assertEqual(len(self.bodies()), 4)             # three answered, one refused, nothing after
        self.assertTrue(o.status.startswith("PARTIAL: billing"), o.status)
        with open(os.path.join(out, "ops.md")) as f:
            self.assertIn("PARTIAL", f.read())

    def test_auth_error_exit_6(self):
        self.st.error_after = 0
        self.st.error_shape = (401, "authentication_error", "invalid x-api-key", {})
        o, _ = self.make()
        self.assertEqual(o.run(), 6)
        self.assertEqual(len(self.bodies()), 1)

    def test_ctrl_c_flushes_partial_files(self):
        def hook(w, body, res):
            if w.n == 3:
                raise KeyboardInterrupt
            return res
        o, out = self.make(client=Wrap(C.Client(self.srv.url, FAKE_KEY), hook))
        self.assertEqual(o.run(), 130)
        self.assertTrue(o.status.startswith("PARTIAL: interrupted"))
        self.assertTrue(os.path.exists(os.path.join(out, "ops.json")))

    def test_only_the_chosen_tests_run(self):
        o, _ = self.make(tests=["E"], e_runs=1)
        o.run()
        self.assertEqual({r["test"] for r in o.records}, {"E"})
        self.assertEqual(len(self.bodies()), 4)


class Cli(StubCase):
    def args(self, *extra):
        return SMALL_OPS + ["--results-dir", self.res] + list(extra)

    def test_the_default_is_the_dry_run_with_no_call_and_no_file(self):
        p = ops_cli([], url=self.srv.url)
        self.assertEqual(p.returncode, 0, p.stderr)
        for s in ("PLAN", "ESTIMATE", "WORST CASE", "CAP", "test B+", "test E", "test A", "Dry run: no network call made, no file written"):
            self.assertIn(s, p.stdout)
        p = ops_cli(self.args("--dry-run"), url=self.srv.url)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(self.st.log, [])
        self.assertEqual(os.listdir(self.res), [])

    def test_the_default_dry_run_prints_the_estimate_under_the_cap(self):
        p = ops_cli(["--dry-run"], url=self.srv.url)
        est = [ln for ln in p.stdout.splitlines() if ln.strip().startswith("ESTIMATE")][0]
        usd = float(est.split("$")[1].split()[0])
        self.assertLess(usd, 0.60)
        self.assertNotIn("OVER THE CAP", p.stdout)
        self.assertIn("1 Mbps", p.stdout)
        self.assertIn("5 Mbps", p.stdout)

    def test_dry_run_needs_no_key_and_makes_no_connection(self):
        p = ops_cli(["--dry-run"], url="http://127.0.0.1:9", key="")
        self.assertEqual(p.returncode, 0)

    def test_over_the_cap_refuses_and_the_override_allows(self):
        big = ["--b-tokens", "1000000"]
        p = ops_cli(big + ["--run"], url=self.srv.url, stdin="SPEND UP TO $0.6\n")
        self.assertEqual(p.returncode, 2)
        self.assertIn("OVER THE CAP", p.stdout)
        self.assertIn("Refusing to start", p.stdout)
        self.assertEqual(self.st.log, [])
        d = ops_cli(big + ["--dry-run"], url=self.srv.url)
        self.assertIn("OVER THE CAP", d.stdout)
        self.assertIn("A paid run would refuse to start", d.stdout)
        ok = ops_cli(big + ["--max-usd", "10", "--dry-run"], url=self.srv.url)
        self.assertNotIn("OVER THE CAP", ok.stdout)

    def test_cap_validation(self):
        for bad in ("0", "-1", "nan", "inf", "11", "abc"):
            p = ops_cli(["--dry-run", "--max-usd", bad], url=self.srv.url)
            self.assertNotEqual(p.returncode, 0, bad)
        p = ops_cli(["--dry-run", "--a-turns", "3"], url=self.srv.url)
        self.assertEqual(p.returncode, 2)
        p = ops_cli(["--dry-run", "--a-fork-at", "9"], url=self.srv.url)
        self.assertEqual(p.returncode, 2)
        p = ops_cli(["--dry-run", "--tests", "X"], url=self.srv.url)
        self.assertNotEqual(p.returncode, 0)
        p = ops_cli(["--dry-run", "--b-rates", "0"], url=self.srv.url)
        self.assertNotEqual(p.returncode, 0)

    def test_a_wrong_phrase_or_a_pipe_makes_no_call(self):
        p = ops_cli(self.args("--run"), url=self.srv.url, stdin="SPEND UP TO $4.5\n")
        self.assertEqual(p.returncode, 2)
        self.assertIn("Not confirmed", p.stdout)
        p = ops_cli(self.args("--run"), url=self.srv.url, stdin="SPEND UP TO $0.6\n", pipe_stdin=True)
        self.assertEqual(p.returncode, 2)
        self.assertIn("typed at a terminal", p.stdout)
        p = ops_cli(self.args("--run"), url=self.srv.url, stdin="", key="")
        self.assertEqual(p.returncode, 2)
        self.assertEqual(self.st.log, [])

    def test_host_allowlist_still_applies(self):
        p = ops_cli(["--dry-run"], url="https://evil.example.com")
        self.assertEqual(p.returncode, 2)
        self.assertIn("not api.anthropic.com", p.stdout)

    def test_full_run_through_the_cli(self):
        p = ops_cli(self.args("--run"), url=self.srv.url, stdin="SPEND UP TO $0.6\n", timeout=240)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("PROBE VERDICT: ACCEPTED", p.stdout)
        dirs = os.listdir(self.res)
        self.assertEqual(len(dirs), 1)
        d = os.path.join(self.res, dirs[0])
        self.assertEqual(sorted(os.listdir(d)), ["ops.json", "ops.md", "probe.json"])
        for fn in os.listdir(d):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(d, fn)).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o700)
        with open(os.path.join(d, "ops.json")) as f:
            doc = json.load(f)
        self.assertEqual(doc["status"], "complete")
        self.assertEqual(doc["requests"], 10 + 8 + 7)
        self.assertLess(doc["spent_usd"], 0.60)
        with open(os.path.join(d, "ops.md")) as f:
            md = f.read()
        with open(os.path.join(d, "ops.json")) as f:
            raw_json = f.read()
        for s in ("### B+", "### E:", "### A:", "Measured bytes per token", "Billing check for the Console", "HIT:", "| --- |"):
            self.assertIn(s, md)
        # the key is in no output and no file; no message or request ids either
        blob = p.stdout + p.stderr + md + raw_json
        self.assertNotIn(FAKE_KEY, blob)
        self.assertNotIn("sk-ant", blob)
        self.assertNotRegex(blob, r"msg_[0-9a-f]{8,}")
        # the probe's three requests come first, then the counts are free, then the tests
        paths = [path for path, h, b in self.st.log]
        self.assertEqual(paths.count("/v1/messages/count_tokens"), 1)    # one size: all three tests use 3000
        self.assertEqual(paths[:3], ["/v1/messages"] * 3)
        for path, h, b in self.st.log:
            if path == "/v1/messages":
                self.assertEqual(h["x-api-key"], FAKE_KEY)

    def test_billing_error_via_the_cli(self):
        self.st.error_after = 5
        self.st.error_shape = (402, "billing_error", "credit balance too low", {})
        p = ops_cli(self.args("--run"), url=self.srv.url, stdin="SPEND UP TO $0.6\n", timeout=240)
        self.assertEqual(p.returncode, 5, p.stdout)
        self.assertIn("STOPPED", p.stdout)
        d = os.path.join(self.res, os.listdir(self.res)[0])
        with open(os.path.join(d, "ops.md")) as f:
            self.assertIn("PARTIAL", f.read())

    def test_a_rejected_probe_stops_before_the_tests(self):
        self.st.reject_threads = True
        p = ops_cli(self.args("--run"), url=self.srv.url, stdin="SPEND UP TO $0.6\n", timeout=240)
        self.assertEqual(p.returncode, 4, p.stdout)
        self.assertIn("Stopping before the tests", p.stdout)
        self.assertFalse([1 for path, h, b in self.st.log if "system" in b and len(json.dumps(b)) > 3000])

    def test_the_existing_cli_is_untouched_by_the_new_mode(self):
        p = run_cli([], url=self.srv.url)
        self.assertEqual(p.returncode, 0)
        self.assertIn("PLAN", p.stdout)
        self.assertNotIn("test B+", p.stdout)


class Wrapper(unittest.TestCase):
    def test_dry_run_through_the_script(self):
        p = subprocess.run([SH], capture_output=True, text=True, env=env_for(None, ""), timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("ESTIMATE", p.stdout)

    def test_the_exit_code_of_the_program_is_the_exit_code_of_the_script(self):
        p = subprocess.run([SH, "--max-usd", "nan"], capture_output=True, text=True, env=env_for(None, ""), timeout=60)
        self.assertNotEqual(p.returncode, 0)
        p = subprocess.run([SH, "--run", "--b-tokens", "1000000"], capture_output=True, text=True, env=env_for(None, ""), timeout=60)
        self.assertEqual(p.returncode, 2)

    def test_term_is_passed_on_and_temp_files_are_removed(self):
        with tempfile.TemporaryDirectory() as d:
            fake = os.path.join(d, "fakepy")
            marker = os.path.join(d, "got-term")
            tmpfile = os.path.join(ROOT, "results", "stray.json.tmp")
            with open(fake, "w") as f:
                f.write('#!/usr/bin/env bash\ntrap \'echo term > "%s"; exit 7\' TERM\nmkdir -p "%s"\ntouch "%s"\necho ready\nwhile true; do sleep 0.1; done\n'
                        % (marker, os.path.dirname(tmpfile), tmpfile))
            os.chmod(fake, 0o755)
            created_results = not os.path.exists(os.path.join(ROOT, "results"))
            e = env_for(None, "")
            e["PYTHON_BIN"] = fake
            p = subprocess.Popen([SH, "--dry-run"], stdout=subprocess.PIPE, text=True, env=e)
            try:
                self.assertEqual(p.stdout.readline().strip(), "ready")
                p.terminate()
                self.assertEqual(p.wait(timeout=20), 7)       # the program's own exit code comes back
            finally:
                if p.poll() is None:
                    p.kill()
                p.stdout.close()
            self.assertTrue(os.path.exists(marker))
            self.assertFalse(os.path.exists(tmpfile))
            if created_results:
                os.rmdir(os.path.join(ROOT, "results"))

    def test_the_typed_phrase_reaches_the_program_through_the_script(self):
        import pty
        srv = Server().start()
        try:
            with tempfile.TemporaryDirectory() as res:
                master, slave = pty.openpty()
                p = subprocess.Popen([SH, "--run", "--tests", "E", "--e-runs", "1", "--e-tokens", "3000", "--e-max-tokens", "32", "--chars-per-token", "4.0",
                                      "--results-dir", res], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env_for(srv.url))
                os.close(slave)
                os.write(master, b"SPEND UP TO $0.6\n")
                try:
                    out, err = p.communicate(timeout=120)
                finally:
                    os.close(master)
                self.assertEqual(p.returncode, 0, out + err)
                self.assertIn("PROBE VERDICT: ACCEPTED", out)
                self.assertTrue(os.path.exists(os.path.join(res, os.listdir(res)[0], "ops.md")))
                self.assertNotIn(FAKE_KEY, out + err)
        finally:
            srv.stop()

    def test_the_script_never_touches_the_network_or_the_system(self):
        with open(SH) as f:
            src = f.read()
        for word in ("pfctl", "dnctl", "tc ", "sudo", "networksetup", "curl", "iptables"):
            self.assertNotIn(word, src.replace("firewall, traffic shaper", ""), word)


if __name__ == "__main__":
    unittest.main()
