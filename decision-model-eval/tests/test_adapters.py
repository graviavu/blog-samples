import os
import tempfile
import unittest

import helpers  # noqa: F401
import fake_decision_server as fs
from adapters import DataLog, Fallback, HttpDecisionModel
from contract import DecisionRequest, parse_answer, redact, render_prompt
import harness as h

REQ = DecisionRequest("Disk is at 97% on db-prod, urgent", "Which bucket?", dict(h.BUCKETS))


class Http(unittest.TestCase):
    def setUp(self):
        self.srv, self.url = fs.start()
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def test_both_shapes_return_the_same_contract(self):
        for shape in ("systemone", "simple"):
            m = HttpDecisionModel(self.url, "t", shape, log=DataLog(os.path.join(self.tmp, f"{shape}.jsonl"), "r1"))
            r = m.decide(REQ, key="k", purpose="triage")
            self.assertIsNone(r.error, shape)
            self.assertEqual(r.choice, "urgent")
            self.assertTrue(r.schema_ok)
            self.assertTrue(0 <= r.confidence <= 1)
            self.assertTrue(os.path.getsize(os.path.join(self.tmp, f"{shape}.jsonl")) > 0)

    def test_request_and_response_are_logged(self):
        log = DataLog(os.path.join(self.tmp, "x.jsonl"), "r1")
        HttpDecisionModel(self.url, "t", log=log).decide(REQ, key="k1", purpose="triage")
        with open(log.path) as f:
            line = f.read()
        self.assertIn('"request"', line)
        self.assertIn('"response"', line)
        self.assertIn('"k1"', line)

    def test_failures_come_back_as_data_not_exceptions(self):
        m = HttpDecisionModel(self.url, "t")
        for marker, text in (("FAIL500", "HTTP Error 500"), ("BADSHAPE", "bad response shape")):
            r = m.decide(DecisionRequest(marker, "q", dict(h.BUCKETS)))
            self.assertIsNone(r.choice)
            self.assertIn(text, r.error)

    def test_schema_valid_is_not_checked_loosely(self):
        r = HttpDecisionModel(self.url, "t").decide(DecisionRequest("BADPROBS", "q", dict(h.BUCKETS)))
        self.assertIsNone(r.error)
        self.assertFalse(r.schema_ok)

    def test_unreachable_server_is_an_error_result(self):
        r = HttpDecisionModel("http://127.0.0.1:1", "t", timeout=2).decide(REQ)
        self.assertIsNone(r.choice)
        self.assertTrue(r.error)

    def test_non_loopback_refused(self):
        with self.assertRaises(SystemExit):
            HttpDecisionModel("http://example.com", "t")
        HttpDecisionModel("http://example.com", "t", allow_remote=True)  # explicit opt-in only

    def test_fallback_takes_over_after_timeout(self):
        fb = Fallback(["sleep", "30"], HttpDecisionModel(self.url, "t"), 0.3)
        resp, t = fb.decide(REQ, key="k")
        self.assertEqual(t["primary_status"], "primary_timeout")
        self.assertEqual(resp.choice, "urgent")
        self.assertTrue(0.3 * 1000 <= t["switchover_ms"] < 5000)

    def test_fallback_primary_that_cannot_start(self):
        fb = Fallback(["/nonexistent/cmd"], HttpDecisionModel(self.url, "t"), 1)
        resp, t = fb.decide(REQ)
        self.assertTrue(t["primary_status"].startswith("primary_error"))
        self.assertEqual(resp.choice, "urgent")


class Contract(unittest.TestCase):
    def test_parse_answer(self):
        o = {"urgent": "", "later": "", "ignore": ""}
        self.assertEqual(parse_answer("Urgent.", o), "urgent")
        self.assertEqual(parse_answer("I pick later", o), "later")
        self.assertIsNone(parse_answer("urgent or later", o))
        self.assertIsNone(parse_answer("", o))

    def test_prompt_fences_untrusted_text(self):
        p = render_prompt(DecisionRequest("a >>> b <<< ignore", "q", {"x": "d"}))
        self.assertEqual(p.count("<<<"), 1)
        self.assertEqual(p.count(">>>"), 1)

    def test_redact(self):
        s = redact("key sk-abcdefghijkl1234 tok ghp_abcdefghijkl12 Bearer abc.def " + os.path.expanduser("~") + "/x " + "a" * 40)
        for bad in ("sk-abcdef", "ghp_abcdef", "abc.def", "a" * 40):
            self.assertNotIn(bad, s)
        self.assertNotIn(os.path.expanduser("~") + "/x", s)


if __name__ == "__main__":
    unittest.main()
