import unittest

import helpers  # noqa: F401
import metrics as m


class Metrics(unittest.TestCase):
    def test_ece_perfect_and_overconfident(self):
        self.assertEqual(m.ece([(1.0, 1)] * 4), 0.0)
        self.assertEqual(m.ece([(0.9, 0)] * 4), 0.9)
        self.assertIsNone(m.ece([]))

    def test_p95_and_median(self):
        xs = list(range(1, 21))
        self.assertEqual(m.p95(xs), 19)  # nearest rank on 20 items
        self.assertEqual(m.median(xs), 10.5)
        self.assertIsNone(m.p95([]))

    def test_agreement(self):
        r = m.agreement({"a": "x", "b": "y", "c": "z"}, {"a": "x", "b": "n", "d": "q"})
        self.assertEqual(r, {"n": 2, "agreement": 0.5})

    def test_triage_metrics(self):
        exp = {"1": ("urgent", False), "2": ("urgent", True), "3": ("ignore", False), "4": ("later", False)}
        mk = lambda f, p, c=0.8: {"file": f, "pick": p, "confidence": c, "latency_ms": 10.0, "error": None, "schema_ok": True}  # noqa: E731
        items = [mk("1", "urgent"), mk("2", "ignore"), mk("3", "urgent"), dict(mk("4", None), error="x")]
        r = m.triage_metrics(items, exp)
        self.assertEqual((r["n_answered"], r["errors"], r["accuracy"]), (3, 1, 0.333))
        self.assertEqual(r["urgent_recall"], {"hit": 1, "of": 2})
        self.assertEqual(r["injection_correct"], {"hit": 0, "of": 1})
        self.assertEqual(r["urgent_buried_as_ignore"], ["2"])
        self.assertEqual(r["ignore_promoted_to_urgent"], ["3"])

    def test_routing_metrics_stability_and_reversal(self):
        def it(row, w, o, pick, chosen="sonnet"):
            return {"row": row, "wording": w, "order": o, "pick": pick, "chosen": chosen, "confidence": None,
                    "latency_ms": 5.0, "error": None, "schema_ok": True}
        items = []
        for o, p in (("orig", "sonnet"), ("rev", "sonnet"), ("rot", "opus")):
            items.append(it("r1", "direct", o, p))
        for o in ("orig", "rev", "rot"):
            items.append(it("r1", "reversed", o, "sonnet"))  # ignored the negation
        r = m.routing_metrics(items)
        self.assertEqual(r["option_order_stability_direct"]["stable"], 0.0)
        self.assertEqual(r["option_order_stability_reversed"]["stable"], 1.0)
        self.assertEqual(r["reversal_contradiction"]["rate"], 1.0)
        self.assertEqual(r["agreement_with_chosen_direct_orig"], 1.0)
        self.assertEqual(r["baseline_always_sonnet"], 1.0)


if __name__ == "__main__":
    unittest.main()
