import unittest

from threads_test import convo, pricing, report, stats
from threads_test import redact as R


class StatsMath(unittest.TestCase):
    def test_median(self):
        self.assertEqual(stats.median([3, 1, 2]), 2)
        self.assertEqual(stats.median([4, 1, 3, 2]), 2.5)
        self.assertIsNone(stats.median([]))

    def test_p90_nearest_rank(self):
        self.assertEqual(stats.percentile(list(range(1, 11)), 90), 9)
        self.assertEqual(stats.percentile(list(range(1, 21)), 90), 18)
        self.assertEqual(stats.percentile([5, 1, 9], 90), 9)   # under 10 values: the maximum
        self.assertEqual(stats.percentile([7], 90), 7)

    def test_savings_and_ratio(self):
        self.assertAlmostEqual(stats.saving_pct(200, 130), 35.0)
        self.assertAlmostEqual(stats.saving_pct(100, 150), -50.0)
        self.assertIsNone(stats.saving_pct(None, 1))
        self.assertIsNone(stats.saving_pct(0, 1))
        self.assertAlmostEqual(stats.ratio(65, 100), 0.65)

    def test_savings_table_versus_arm1(self):
        def rec(arm, kind, ttft, total, usage, turn=1):
            return {"arm": arm, "rep": 0, "turn": turn, "kind": kind, "attempt": 1, "status": 200, "complete": True,
                    "ttft_ms": ttft, "total_ms": total, "usage": usage, "cost": pricing.cost("claude-sonnet-5-5", usage)}
        u1 = {"input_tokens": 100000, "output_tokens": 10}
        u2 = {"input_tokens": 100, "cache_read_input_tokens": 99900, "output_tokens": 10}
        recs = [rec(1, "turn", 1000, 1500, u1), rec(1, "turn", 3000, 3500, u1),
                rec(2, "turn", 500, 900, u2), rec(2, "prime", 4000, 4500, dict(u1, cache_creation_input_tokens=100000, input_tokens=0), 0),
                rec(3, "turn", 250, 700, u2), rec(4, "reload", 2000, 2400, {"cache_creation_input_tokens": 100000, "output_tokens": 10}, 0)]
        rows = report.arm_rows(recs)
        self.assertEqual(rows[1]["ttft_ms_median"], 2000)
        self.assertAlmostEqual(rows[2]["ttft_saving_pct"], 75.0)
        self.assertAlmostEqual(rows[3]["ttft_saving_pct"], 87.5)
        self.assertAlmostEqual(rows[2]["cost_saving_pct"], (1 - rows[2]["cost_usd_median"] / rows[1]["cost_usd_median"]) * 100)
        self.assertGreater(rows[2]["cost_saving_pct"], 80)
        self.assertLess(rows[4]["cost_saving_pct"], 0)   # a cold write costs more than plain input
        self.assertEqual(rows[2]["n"], 1)                # the prime turn is not a follow-up turn
        self.assertIn("setup_cost_usd_median", rows[2])


class Pricing(unittest.TestCase):
    def test_haiku_tiers(self):
        self.assertEqual(pricing.tier("claude-haiku-5-5", 100000), (0.10, 0.50, 0.125, 0.01))
        self.assertEqual(pricing.tier("claude-haiku-5-5", 100001), (0.50, 2.50, 0.625, 0.05))

    def test_tier_counts_cache_tokens(self):
        u = {"input_tokens": 10, "cache_read_input_tokens": 99995, "output_tokens": 0}
        self.assertAlmostEqual(pricing.cost("claude-haiku-5-5", u)["cache_read"], 99995 * 0.05 / 1e6)

    def test_cost_parts(self):
        u = {"input_tokens": 1000000, "cache_creation_input_tokens": 1000000, "cache_read_input_tokens": 1000000, "output_tokens": 1000000}
        c = pricing.cost("claude-sonnet-5-5", u)
        self.assertAlmostEqual(c["total"], 2 + 2.5 + 0.1 + 10)

    def test_unknown_model_refused(self):
        with self.assertRaises(ValueError):
            pricing.tier("claude-nope", 10)

    def test_upper_bound_beats_any_cache_mix(self):
        ub = pricing.request_upper_bound("claude-haiku-5-5", 129560, 512)
        worst_actual = pricing.cost("claude-haiku-5-5", {"cache_creation_input_tokens": 129560, "output_tokens": 512})["total"]
        self.assertGreaterEqual(ub, worst_actual)

    def test_estimate_counts(self):
        a = {"tokens": 100000, "turns": 5, "reps": 3, "nocache_turns": 2, "nocache_reps": 2, "reload_reps": 3, "expiry_test": False,
             "margin": 1.25, "max_tokens": 512}
        e = pricing.estimate("claude-haiku-5-5", a)
        self.assertEqual(e["counts"]["sized"], 4 + 18 + 18 + 3 + 2)
        self.assertLess(e["total"], 10)
        a["tokens"] = 500000
        self.assertGreater(pricing.estimate("claude-haiku-5-5", a)["total"], 10)


class Convo(unittest.TestCase):
    def test_deterministic(self):
        self.assertEqual(convo.build_history(1, 2000), convo.build_history(1, 2000))
        self.assertNotEqual(convo.build_history(1, 2000), convo.build_history(2, 2000))

    def test_shape_alternates_and_ends_with_user_turn_zero(self):
        h = convo.build_history(1, 3000)
        self.assertEqual([m["role"] for m in h], ["user", "assistant"] * (len(h) // 2) + (["user"] if len(h) % 2 else []))
        self.assertEqual(h[-1]["role"], "user")
        self.assertEqual(h[-1]["content"][-1]["text"], "Turn 0: Which service looks worst so far?")
        kinds = {b["type"] for m in h if isinstance(m["content"], list) for b in m["content"]}
        self.assertTrue({"tool_use", "tool_result", "text"} <= kinds)

    def test_size_follows_tokens(self):
        import json
        small = len(json.dumps(convo.build_history(1, 2000)))
        big = len(json.dumps(convo.build_history(1, 20000)))
        self.assertAlmostEqual(small / 8000, 1.0, delta=0.15)
        self.assertAlmostEqual(big / 80000, 1.0, delta=0.15)

    def test_prefix_identical_across_calls(self):
        self.assertEqual(convo.build_history(1, 5000)[:6], convo.build_history(1, 5000)[:6])

    def test_synthetic_only(self):
        import json
        text = json.dumps(convo.build_history(1, 3000))
        self.assertNotIn("@", text)
        self.assertNotIn("/Users/", text)


class Salt(unittest.TestCase):
    def test_unique_per_arm_rep_and_run(self):
        s = {convo.make_salt(1, a, r, "run1") for a in (1, 2, 3, 4) for r in range(3)}
        self.assertEqual(len(s), 12)
        self.assertNotEqual(convo.make_salt(1, 4, 0, "run1"), convo.make_salt(1, 4, 0, "run2"))
        self.assertEqual(convo.make_salt(1, 4, 0, "run1"), convo.make_salt(1, 4, 0, "run1"))

    def test_salt_is_the_very_first_thing_in_the_system_prompt(self):
        salt = convo.make_salt(1, 4, 0, "x")
        self.assertTrue(convo.system_text(salt).startswith("[salt %s]" % salt))


class Redaction(unittest.TestCase):
    def test_key_and_bearer_and_ids(self):
        R.add_secret("topsecretvalue123")
        t = R.redact("key topsecretvalue123 sk-ant-api03-abcdefgh Bearer abc.def msg_01XFDUDYJgAACzvnptvVoYEL req_011CSHoEeq")
        for bad in ("topsecretvalue123", "sk-ant-api03", "abc.def", "01XFDUDY", "011CSHoEeq"):
            self.assertNotIn(bad, t)

    def test_request_id_field_dropped(self):
        self.assertNotIn("request_id", R.redact_obj({"error": {"message": "x"}, "request_id": "req_abc12345"}))


if __name__ == "__main__":
    unittest.main()
