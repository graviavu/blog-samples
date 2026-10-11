import json
import os
import tempfile
import unittest
from unittest import mock

import helpers
from adapters import DataLog
from contract import DecisionRequest
from llm import CommandLLM, StopRun, claude_argv

REQ = DecisionRequest("Pay the invoice today", "Which?", {"urgent": "a", "later": "b", "ignore": "c"})


def make(tmp, **kw):
    d = dict(argv=[helpers.FAKE_LLM], name="llm", log=DataLog(os.path.join(tmp, "llm.jsonl"), "r"), budget=1.0,
             est_cost=0.01, max_calls=100, timeout=20)
    d.update(kw)
    return CommandLLM(**d)


class Llm(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.calls = os.path.join(self.tmp, "calls.jsonl")
        p = mock.patch.dict(os.environ, {"FAKE_LLM_LOG": self.calls}, clear=False)
        p.start()
        self.addCleanup(p.stop)

    def n_calls(self):
        if not os.path.exists(self.calls):
            return 0
        with open(self.calls) as f:
            return len(f.read().splitlines())

    def test_answer_and_prompt_on_stdin_not_argv(self):
        m = make(self.tmp, argv=[helpers.FAKE_LLM, "-p"])
        r = m.decide(REQ, key="k")
        m.close()
        self.assertEqual(r.choice, "urgent")
        with open(self.calls) as f:
            rec = json.loads(f.readline())
        self.assertEqual(rec["argv"], ["-p"])
        self.assertGreater(rec["prompt_len"], 50)

    def test_budget_stops_before_crossing(self):
        m = make(self.tmp, budget=0.025, argv=[helpers.FAKE_LLM, "-p"])
        m.decide(REQ, key="a")
        m.decide(REQ, key="b")
        with self.assertRaises(StopRun):
            m.decide(REQ, key="c")  # spent 0.02 + est 0.01 > 0.025
        self.assertEqual(self.n_calls(), 2)

    def test_max_calls(self):
        m = make(self.tmp, max_calls=1)
        m.decide(REQ, key="a")
        with self.assertRaises(StopRun):
            m.decide(REQ, key="b")

    def test_unknown_cost_is_charged_at_the_estimate_never_zero(self):
        with mock.patch.dict(os.environ, {"FAKE_LLM_COST": "none"}):
            m = make(self.tmp, argv=[helpers.FAKE_LLM, "-p"], est_cost=0.3, budget=0.5)
            r = m.decide(REQ, key="a")
            self.assertEqual(r.cost_usd, 0.3)
            with self.assertRaises(StopRun):
                m.decide(REQ, key="b")

    def test_reported_cost_is_used(self):
        with mock.patch.dict(os.environ, {"FAKE_LLM_COST": "0.002"}):
            m = make(self.tmp, argv=[helpers.FAKE_LLM, "-p"])
            self.assertEqual(m.decide(REQ, key="a").cost_usd, 0.002)

    def test_rerun_uses_cache_and_counts_prior_spend(self):
        make(self.tmp).decide(REQ, key="a")
        before = self.n_calls()
        m2 = make(self.tmp)  # same log file
        r = m2.decide(REQ, key="a")
        self.assertEqual(r.choice, "urgent")
        self.assertEqual(self.n_calls(), before)
        self.assertAlmostEqual(m2.spent, 0.01)
        self.assertEqual(m2.calls, 1)

    def test_changed_prompt_is_not_served_from_cache(self):
        m = make(self.tmp)
        m.decide(REQ, key="a")
        m.decide(DecisionRequest("different", "Which?", REQ.options), key="a")
        self.assertEqual(self.n_calls(), 2)

    def test_unparseable_is_an_error_and_is_not_retried(self):
        with mock.patch.dict(os.environ, {"FAKE_LLM_MODE": "garbage"}):
            m = make(self.tmp)
            self.assertEqual(m.decide(REQ, key="a").error, "unparseable answer")
            m.decide(REQ, key="a")
            self.assertEqual(self.n_calls(), 1)

    def test_three_failures_in_a_row_stop_the_run(self):
        with mock.patch.dict(os.environ, {"FAKE_LLM_MODE": "fail"}):
            m = make(self.tmp)
            m.decide(REQ, key="a")
            m.decide(REQ, key="b")
            with self.assertRaises(StopRun):
                m.decide(REQ, key="c")

    def test_timeout_is_an_error(self):
        m = make(self.tmp, argv=["sleep", "30"], timeout=0.3)
        r = m.decide(REQ, key="a")
        self.assertIn("timeout", r.error)

    def test_requires_budget_and_estimate(self):
        with self.assertRaises(SystemExit):
            make(self.tmp, budget=None)
        with self.assertRaises(SystemExit):
            make(self.tmp, est_cost=None)


class Preset(unittest.TestCase):
    def test_claude_argv_has_every_isolation_flag(self):
        a = claude_argv(helpers.FAKE_LLM, "sonnet")
        for f in ("-p", "--tools=", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--max-budget-usd"):
            self.assertIn(f, a)
        self.assertEqual(a[a.index("--permission-mode") + 1], "dontAsk")
        self.assertEqual(a[a.index("--setting-sources") + 1], "project")

    def test_refuses_when_a_flag_is_missing(self):
        with mock.patch.dict(os.environ, {"FAKE_LLM_OMIT": "--strict-mcp-config"}):
            with self.assertRaises(SystemExit) as c:
                claude_argv(helpers.FAKE_LLM, "sonnet")
            self.assertEqual(c.exception.code, 1)

    def test_refuses_when_binary_missing(self):
        with self.assertRaises(SystemExit):
            claude_argv("/nonexistent/claude", "sonnet")


if __name__ == "__main__":
    unittest.main()
