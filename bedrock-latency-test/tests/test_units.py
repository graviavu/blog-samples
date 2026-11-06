import io
import json
import os
import tempfile
import unittest

from bedrock_latency import client, fill, plan, pricing, probe, redact, runner, stats
from tests.fake_bedrock import Server
from tests.helpers import FAKE_TOKEN


class R(object):
    """Result-like object for the verdict rules."""
    def __init__(self, status=200, ok=None, code=None, etype=None, text="", rid="msg_abc123456"):
        self.status = status
        self.ok = (status == 200) if ok is None else ok
        self.error = None if self.ok else {"error_type": etype, "error_code": code}
        self.text, self.response_id = text, rid


class Stats(unittest.TestCase):
    def test_median_p90(self):
        self.assertEqual(stats.median([3, 1, 2]), 2)
        self.assertEqual(stats.median([1, 2, 3, 4]), 2.5)
        self.assertEqual(stats.percentile([1, 2, 3], 90), 3)
        self.assertEqual(stats.percentile(list(range(1, 21)), 90), 18)
        self.assertIsNone(stats.median([]))


class Pricing(unittest.TestCase):
    def test_haiku_tiers(self):
        p = pricing.Prices()
        self.assertEqual(p.tier("anthropic.claude-haiku-5-5", 99000)["input"], 0.10)
        self.assertEqual(p.tier("anthropic.claude-haiku-5-5", 100001)["input"], 0.50)

    def test_cost_from_usage(self):
        p = pricing.Prices()
        c = p.cost("anthropic.claude-sonnet-5-5", {"input_tokens": 1000, "cache_creation_input_tokens": 2000,
                                                  "cache_read_input_tokens": 3000, "output_tokens": 100})
        self.assertAlmostEqual(c, (1000 * 2 + 2000 * 2.5 + 3000 * 0.1 + 100 * 10) / 1e6)

    def test_multiplier(self):
        a = pricing.Prices().cost("sonnet-5-5", {"input_tokens": 1000})
        b = pricing.Prices(multiplier=1.1).cost("sonnet-5-5", {"input_tokens": 1000})
        self.assertAlmostEqual(b, a * 1.1)

    def test_override_file(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "p.json")
            with open(f, "w") as fh:
                json.dump({"sonnet-5-5": [{"up_to_prompt_tokens": None, "input": 1, "output": 2, "cache_write": 3, "cache_read": 0.5}]}, fh)
            p = pricing.Prices(pricing.load_overrides(f))
            self.assertEqual(p.tier("anthropic.claude-sonnet-5-5", 10)["input"], 1)
            with open(f, "w") as fh:
                json.dump({"x": [{"up_to_prompt_tokens": 5, "input": 1, "output": 2, "cache_write": 3, "cache_read": 0.5}]}, fh)
            with self.assertRaises(ValueError):
                pricing.load_overrides(f)   # no open-ended last tier
            with open(f, "w") as fh:
                json.dump({"x": [{"up_to_prompt_tokens": None, "input": -1, "output": 2, "cache_write": 3, "cache_read": 0.5}]}, fh)
            with self.assertRaises(ValueError):
                pricing.load_overrides(f)

    def test_unknown_model_needs_a_price(self):
        with self.assertRaises(ValueError):
            pricing.Prices().tier("anthropic.claude-mystery-1", 10)

    def test_bound_is_at_least_any_real_cost(self):
        p = pricing.Prices()
        m = "anthropic.claude-sonnet-5-5"
        ub = p.bound(m, 10000, 64)
        for u in ({"input_tokens": 10000, "output_tokens": 64}, {"cache_creation_input_tokens": 10000, "output_tokens": 64}):
            self.assertGreaterEqual(ub, p.cost(m, u))

    def test_ids(self):
        self.assertEqual(pricing.model_id("sonnet-5-5"), "anthropic.claude-sonnet-5-5")
        self.assertEqual(pricing.model_id("anthropic.claude-haiku-5-5"), "anthropic.claude-haiku-5-5")
        self.assertEqual(pricing.model_key("anthropic.claude-haiku-5-5"), "haiku-5-5")


class Fill(unittest.TestCase):
    def test_deterministic_and_salted(self):
        a = fill.build_history("s1", 8000, 4.0)
        self.assertEqual(a, fill.build_history("s1", 8000, 4.0))
        self.assertNotEqual(a[0]["content"], fill.build_history("s2", 8000, 4.0)[0]["content"])

    def test_shape(self):
        h = fill.build_history("s", 20000, 4.0)
        self.assertEqual(h[0]["role"], "user")
        self.assertEqual(h[-1]["role"], "assistant")
        self.assertTrue(all(h[i]["role"] != h[i + 1]["role"] for i in range(len(h) - 1)))
        chars = sum(len(m["content"]) for m in h)
        self.assertAlmostEqual(chars / (20000 * 4.0), 1.0, delta=0.05)


class Verdicts(unittest.TestCase):
    def test_accepted(self):
        v, _ = probe.decide(R(), R(), R(), True)
        self.assertEqual(v, probe.ACCEPTED)

    def test_rejected_create(self):
        v, why = probe.decide(R(), R(400, code="unsupported_parameter", etype="invalid_request_error"), None, False)
        self.assertEqual(v, probe.REJECTED)
        self.assertIn("unsupported_parameter", why)

    def test_rejected_continue(self):
        v, _ = probe.decide(R(), R(), R(400, code=None, etype="invalid_request_error"), False)
        self.assertEqual(v, probe.REJECTED)

    def test_inconclusive_cases(self):
        self.assertEqual(probe.decide(R(401, etype="authentication_error"), None, None, False)[0], probe.INCONCLUSIVE)
        self.assertEqual(probe.decide(R(), R(503), None, False)[0], probe.INCONCLUSIVE)
        self.assertEqual(probe.decide(R(), R(429), None, False)[0], probe.INCONCLUSIVE)
        self.assertEqual(probe.decide(R(), R(), R(), False)[0], probe.INCONCLUSIVE)
        self.assertEqual(probe.decide(R(), R(), R(404, code="thread_not_found"), False)[0], probe.INCONCLUSIVE)
        self.assertEqual(probe.decide(R(), R(), None, False)[0], probe.INCONCLUSIVE)


class Redaction(unittest.TestCase):
    def test_patterns(self):
        redact.add_secret("SECRETTOKEN-123456")
        t = redact.redact("x SECRETTOKEN-123456 acct 123456789012 arn:aws:iam::123456789012:role/r msg_01ABCDEF123 req_01ZZZZ99999 "
                          "7f1c2d3e-0000-4000-8000-123456789abc Bearer abc.def")
        for bad in ("SECRETTOKEN", "123456789012", "arn:aws", "msg_01", "req_01", "7f1c2d3e", "abc.def"):
            self.assertNotIn(bad, t)

    def test_error_description_keeps_codes_drops_ids(self):
        d = client.describe_error(400, json.dumps({"type": "error", "request_id": "req_01ABCDEF1234", "error": {
            "type": "invalid_request_error", "message": "bad thing in req_01ABCDEF1234", "details": {"error_code": "thread_unsupported_request"}}}),
            {"x-amzn-ErrorType": "ValidationException"})
        self.assertEqual(d["error_type"], "invalid_request_error")
        self.assertEqual(d["error_code"], "thread_unsupported_request")
        self.assertEqual(d["amzn_error_type"], "ValidationException")
        self.assertNotIn("req_01", json.dumps(d))

    def test_non_json_error(self):
        d = client.describe_error(502, "<html>Bad gateway</html>")
        self.assertEqual(d["http_status"], 502)
        self.assertIn("Bad gateway", d["message"])


class Endpoint(unittest.TestCase):
    def test_plain_http_only_on_loopback(self):
        client.parse_endpoint("http://127.0.0.1:9/anthropic")
        with self.assertRaises(ValueError):
            client.parse_endpoint("http://example.com/anthropic")

    def test_key_only_goes_to_api_aws_or_loopback_or_the_named_host(self):
        for ok in ("bedrock-mantle.us-east-1.api.aws", "BEDROCK-MANTLE.EU-WEST-1.API.AWS", "127.0.0.1", "localhost", "::1"):
            client.check_host(ok)
        for bad in ("example.com", "api.aws", "evilapi.aws", "bedrock-mantle.us-east-1.api.aws.example.com", "api.aws.evil", ""):
            with self.assertRaises(ValueError, msg=bad):
                client.check_host(bad)
        client.check_host("proxy.example.com", allow="proxy.example.com")
        with self.assertRaises(ValueError):
            client.check_host("other.example.com", allow="proxy.example.com")

    def test_rejects_credentials_and_queries(self):
        for u in ("https://u:p@example.com/x", "https://example.com/x?a=b", "ftp://example.com"):
            with self.assertRaises(ValueError):
                client.parse_endpoint(u)


class Plan(unittest.TestCase):
    def test_counts(self):
        self.assertEqual(plan.counts(3), {"A": 3, "B": 4, "C": 4})
        self.assertEqual(plan.counts(3, False)["C"], 0)

    CFG = {"models": ["anthropic.claude-sonnet-5-5", "anthropic.claude-haiku-5-5"], "sizes": [20000, 100000], "reps": 3,
           "max_tokens": 64, "margin": 1.1, "probe_model": "anthropic.claude-haiku-5-5", "thread_arm": True}

    def test_default_plan_fits_the_default_cap_with_the_default_multiplier(self):
        pl = plan.build(self.CFG, pricing.Prices(multiplier=1.1))
        self.assertAlmostEqual(pl["total"], 4.92, delta=0.01)
        self.assertLessEqual(pl["total"], 5.0)
        self.assertLess(plan.typical(self.CFG, pricing.Prices(multiplier=1.1)), pl["total"])

    def test_200k_is_over_five_dollars(self):
        cfg = dict(self.CFG, sizes=[20000, 100000, 200000])
        self.assertGreater(plan.build(cfg, pricing.Prices(multiplier=1.1))["total"], 5.0)


def res(status=None, ok_stream=False, sent=True, stream_started=False, exception=None, usage=None):
    r = client.Result()
    r.status, r.sent, r.stream_started, r.exception = status, sent, stream_started, exception
    if ok_stream:
        r.status, r.complete, r.stream_started = 200, True, True
    r.usage = usage if usage is not None else {}
    return r


class Charge(unittest.TestCase):
    P = pricing.Prices()
    M = "anthropic.claude-haiku-5-5"
    B = 0.45

    def c(self, r):
        return runner.charge(r, self.M, self.B, self.P)

    def test_ok_with_usage_is_the_usage_cost(self):
        u = {"input_tokens": 1000, "output_tokens": 10}
        self.assertEqual(self.c(res(ok_stream=True, usage=u)), (self.P.cost(self.M, u), False))

    def test_ok_without_usage_is_the_bound(self):
        for u in ({}, {"input_tokens": 1000}, {"output_tokens": 10}, {"cache_read_input_tokens": 5000, "output_tokens": 10}):
            self.assertEqual(self.c(res(ok_stream=True, usage=u)), (self.B, True), u)

    def test_failures_after_sending_are_the_bound(self):
        self.assertEqual(self.c(res(exception="TimeoutError: timed out"))[0], self.B)
        self.assertEqual(self.c(res(exception="ConnectionResetError: reset"))[0], self.B)
        self.assertEqual(self.c(res(200, stream_started=True, exception="stream ended before message_stop"))[0], self.B)
        self.assertEqual(self.c(res(503, exception="IncompleteRead"))[0], self.B)   # error body cut off
        for st in (500, 502, 504):
            self.assertEqual(self.c(res(st))[0], self.B, st)

    def test_only_clean_refusals_and_unsent_requests_are_free(self):
        self.assertEqual(self.c(res(exception="ConnectionRefusedError", sent=False))[0], 0.0)
        self.assertEqual(self.c(res(exception="gaierror: DNS", sent=False))[0], 0.0)
        for st in (400, 401, 403, 404, 408, 429, 503, 529):
            self.assertEqual(self.c(res(st))[0], 0.0, st)

    def test_retry_only_before_the_body_was_sent(self):
        self.assertTrue(res(exception="ConnectionRefusedError", sent=False).transient)
        self.assertFalse(res(exception="TimeoutError: timed out").transient)
        self.assertFalse(res(exception="ConnectionResetError").transient)
        self.assertFalse(res(503, exception="IncompleteRead").transient)
        self.assertTrue(res(503).transient)
        self.assertFalse(res(400).transient)


class CapFiresOnTheStub(unittest.TestCase):
    """The reviewer's case: a caller that keeps sending. With honest charging the cap must fire after cap/bound requests."""
    CAP, BOUND = 1.0, 0.45

    def setUp(self):
        self.srv = Server(FAKE_TOKEN).start()
        self.st = self.srv.state

    def tearDown(self):
        self.srv.stop()

    def loop(self, timeout=10):
        cl = client.Client(self.srv.url, FAKE_TOKEN, timeout=timeout)
        r = runner.Runner({"max_usd": self.CAP, "retries": 1}, cl, pricing.Prices(), "/nonexistent", lambda m: None, sleep=lambda x: None)
        body = {"model": "anthropic.claude-haiku-5-5", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}
        with self.assertRaises(runner.Stop) as cm:
            for _ in range(50):
                r.send(body, None, "turn", "anthropic.claude-haiku-5-5", self.BOUND)
        return r, cm.exception

    def check(self, r, stop):
        self.assertEqual(stop.status, "stopped_cap")
        self.assertEqual(r.requests, 2)                        # 0.45 + 0.45, then 0.90 + 0.45 > 1.0
        self.assertEqual(len(self.st.log), 2)                  # no hidden retries
        self.assertAlmostEqual(r.spent, 2 * self.BOUND)
        self.assertLessEqual(r.spent, self.CAP)

    def test_no_usage(self):
        self.st.no_usage_after = 0
        r, stop = self.loop()
        self.check(r, stop)
        self.assertTrue(all(x.get("usage_missing") for x in r.records))

    def test_hang_then_reset(self):
        self.st.hang_reset_after, self.st.hang_s = 0, 0.05
        r, stop = self.loop()
        self.check(r, stop)
        self.assertTrue(all(x["attempts"] == 1 and x.get("exception") for x in r.records), r.records)

    def test_read_timeout(self):
        self.st.hang_reset_after, self.st.hang_s = 0, 1.5
        r, stop = self.loop(timeout=1)
        self.check(r, stop)
        self.assertTrue(all("timed out" in x["exception"] for x in r.records), r.records)


if __name__ == "__main__":
    unittest.main()
