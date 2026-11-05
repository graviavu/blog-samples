"""Entry point. --dry-run prints the plan and the worst-case cost and makes no network call. --run asks for a typed confirmation."""
import argparse
import math
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from threads_test import client as C  # noqa: E402
from threads_test import convo  # noqa: E402
from threads_test import pricing  # noqa: E402
from threads_test import redact as R  # noqa: E402
from threads_test.runner import Runner  # noqa: E402

DEFAULT_BASE = "https://api.anthropic.com"


def out(msg=""):
    print(R.redact(msg), flush=True)


HARD_CEILING = 10.0


def usd(text):
    try:
        v = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("not a number: %r" % text)
    if not math.isfinite(v) or v <= 0:
        raise argparse.ArgumentTypeError("must be a finite number above 0")
    if v > HARD_CEILING:
        raise argparse.ArgumentTypeError("above the hard ceiling of $%g (R approved at most that much; there is no override flag)" % HARD_CEILING)
    return v


def parser():
    p = argparse.ArgumentParser(prog="run-test.sh", description="Latency and cost of full resend vs prompt cache vs message thread vs reload.")
    m = p.add_mutually_exclusive_group()
    m.add_argument("--dry-run", action="store_true", help="print the plan and the worst-case cost; no network call, no files")
    m.add_argument("--run", action="store_true", help="make the paid calls (asks for a typed confirmation first)")
    p.add_argument("--model", default="claude-haiku-5-5", help="default: the cheapest model with a price in DOCS-NOTES.md")
    p.add_argument("--tokens", type=int, default=100000, help="size of the synthetic history (default 100000; 500000 costs about 5x)")
    p.add_argument("--turns", type=int, default=5, help="follow-up turns per repetition in arms 2 and 3")
    p.add_argument("--reps", type=int, default=3, help="repetitions of arms 2 and 3")
    p.add_argument("--nocache-turns", type=int, default=2, help="requests per repetition in arm 1 (the dearest arm)")
    p.add_argument("--nocache-reps", type=int, default=2, help="repetitions of arm 1")
    p.add_argument("--reload-reps", type=int, default=None, help="cold reload requests in arm 4 (default: --reps)")
    p.add_argument("--no-checks", dest="checks", action="store_false", help="skip the 404 / double-continue checks")
    p.add_argument("--expiry-test", action="store_true", help="also wait just over 5 minutes idle and continue (slow, cheap)")
    p.add_argument("--expiry-wait", type=int, default=310, help="idle seconds for --expiry-test (default 310)")
    p.add_argument("--max-usd", type=usd, default=10.0, help="spend cap in USD: finite, above 0, at most %g (default %g; no override)" % (HARD_CEILING, HARD_CEILING))
    p.add_argument("--max-tokens", type=int, default=512, help="output cap per request, thinking included (default 512)")
    p.add_argument("--effort", default="low", help="output_config.effort on every request; 'none' leaves it out (default low)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--token-margin", dest="margin", type=float, default=1.25, help="assumed worst-case tokens / --tokens (default 1.25)")
    p.add_argument("--chars-per-token", type=float, default=3.2, help="characters per token used to size the history (default 3.2, on the low side to keep the prompt under --tokens)")
    p.add_argument("--retries", type=int, default=1, help="retries per failed request (default 1)")
    p.add_argument("--count-tokens", action="store_true", help="with --run: count the history once with the free count_tokens endpoint before the confirmation (needs the key; not used in dry runs)")
    p.add_argument("--timeout", type=int, default=600)
    p.add_argument("--results-dir", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results"))
    return p


def phrase(cap):
    return "SPEND UP TO $%s" % ("%.2f" % cap).rstrip("0").rstrip(".")


def plan_args(a, tokens=None):
    return {"tokens": tokens or a.tokens, "turns": a.turns, "reps": a.reps, "nocache_turns": a.nocache_turns,
            "nocache_reps": a.nocache_reps, "reload_reps": a.reload_reps, "expiry_test": a.expiry_test,
            "margin": a.margin, "max_tokens": a.max_tokens, "small_tokens": 2000, "checks": a.checks, "retries": a.retries}


def print_plan(a, est):
    c = est["counts"]
    out("PLAN (nothing is sent in a dry run)")
    out("  model                %s" % a.model)
    out("  history size         about %d tokens (worst case assumed %d per request)" % (a.tokens, est["prompt_tokens_ub"]))
    out("  arm 1 no cache       %d reps x %d requests = %d" % (a.nocache_reps, a.nocache_turns, c["arm1"]))
    out("  arm 2 prompt cache   %d reps x (1 prime + %d turns) = %d" % (a.reps, a.turns, c["arm2"]))
    out("  arm 3 thread + cache %d reps x (1 create + %d continues) = %d" % (a.reps, a.turns, c["arm3"]))
    out("  arm 4 cold reload    %d requests (unique salt, nothing cached)" % c["arm4"])
    out("  behaviour checks     %s" % ("2 full-size requests (replay after a 404, one continue); the failing calls cost no tokens" if a.checks else "skipped"))
    if a.expiry_test:
        out("  expiry test          2 small requests, %d s idle" % a.expiry_wait)
    out("  total                %d full-size requests + %d small" % (c["sized"], c["small"]))
    out("  retries and replays  the bound adds %d replays (one per arm 3 continue) and attempts every request %d times (--retries %d): %d full-size attempts" % (c["replays"], 1 + c["retries"], c["retries"], c["attempts"]))
    lo = pricing.tier(a.model, est["prompt_tokens_ub"])
    out("  pricing assumed      per MTok input %.3f, output %.3f, cache write %.3f, cache read %.3f (tier for a %d-token prompt; DOCS-NOTES.md)" % (lo[0], lo[1], lo[2], lo[3], est["prompt_tokens_ub"]))
    out("  bound rule           every prompt token billed at the dearer of input and cache-write price, no cache-read credit, every output up to --max-tokens %d" % a.max_tokens)
    out("  PLANNED UPPER BOUND  $%.2f   (cap $%.2f; includes retries and replays; real spend is lower)" % (est["total"], a.max_usd))
    out("  this one request     up to $%.4f" % est["per_request_ub"])
    out("  for comparison, same flags at other sizes:")
    for t in (100000, 500000):
        if t != a.tokens:
            e2 = pricing.estimate(a.model, plan_args(a, t))
            out("    --tokens %-7d planned upper bound $%.2f%s" % (t, e2["total"], "" if e2["total"] <= a.max_usd else "  (over the cap: reduce --reps, --turns, --nocache-reps, --nocache-turns, or use --no-checks)"))


def count_check(a, base, key):
    """Opt-in: count the generated history once with the free count_tokens endpoint. Returns an error text or None."""
    hist = convo.build_history(a.seed, a.tokens, a.chars_per_token)
    body = {"model": a.model, "system": convo.system_text("0" * 24), "tools": convo.TOOLS, "messages": hist}
    try:
        n = C.Client(base, key, a.timeout).count_tokens(body)
    except ValueError as e:
        return "error: %s" % e
    out("count_tokens (free, counted once): the history is %d tokens for --tokens %d (ratio %.2f)." % (n, a.tokens, n / a.tokens))
    if n > a.tokens * a.margin:
        return "Refusing to start: the history is over --tokens x --token-margin (%.0f). Lower --chars-per-token or --tokens; the bound would not hold." % (a.tokens * a.margin)
    return None


def main(argv=None):
    a = parser().parse_args(argv)
    if not (a.dry_run or a.run):
        out("Nothing done: pass --dry-run to see the plan, or --run to spend money. See --help.")
        return 2
    if a.reload_reps is None:
        a.reload_reps = a.reps
    if a.max_usd <= 0 or min(a.tokens, a.turns, a.reps, a.nocache_turns, a.nocache_reps, a.max_tokens) < 1 or a.reload_reps < 0:
        out("error: counts and sizes must be positive")
        return 2
    if a.effort not in ("none", "low", "medium", "high", "xhigh", "max"):
        out("error: --effort must be none, low, medium, high, xhigh or max")
        return 2
    try:
        est = pricing.estimate(a.model, plan_args(a))
    except ValueError as e:
        out("error: %s" % e)
        return 2
    base = os.environ.get("ANTHROPIC_BASE_URL", DEFAULT_BASE)
    try:
        C.parse_base(base)
    except ValueError as e:
        out("error: ANTHROPIC_BASE_URL: %s" % e)
        return 2
    print_plan(a, est)
    over = est["total"] > a.max_usd
    if over:
        out("  EXCEEDS THE CAP by $%.2f. %s" % (est["total"] - a.max_usd, "A real run would refuse to start." if a.dry_run else "Refusing to start."))
    if a.dry_run:
        out("Dry run: no network call made, no file written.")
        return 0
    if over:
        out("Lower --tokens, --reps, --turns or --nocache-*, or raise --max-usd, then run again.")
        return 2
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        out("error: set ANTHROPIC_API_KEY in your environment (it is never printed or stored)")
        return 2
    R.add_secret(key)
    if a.count_tokens:
        msg = count_check(a, base, key)
        if msg:
            out(msg)
            return 2
    out("")
    out("This sends paid requests with your API key to %s and stops at the cap." % base)
    out("To go ahead type exactly: %s" % phrase(a.max_usd))
    sys.stdout.flush()
    reply = sys.stdin.readline().rstrip("\r\n")
    if reply != phrase(a.max_usd):
        out("Not confirmed. No calls made.")
        return 2
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    outdir = os.path.join(a.results_dir, stamp)
    os.makedirs(outdir, exist_ok=True)
    cfg = {"model": a.model, "tokens": a.tokens, "turns": a.turns, "reps": a.reps, "nocache_turns": a.nocache_turns,
           "nocache_reps": a.nocache_reps, "reload_reps": a.reload_reps, "checks": a.checks, "expiry_test": a.expiry_test,
           "expiry_wait": a.expiry_wait, "max_usd": a.max_usd, "max_tokens": a.max_tokens, "effort": a.effort, "seed": a.seed,
           "margin": a.margin, "chars_per_token": a.chars_per_token, "retries": a.retries, "small_tokens": 2000,
           "salt_nonce": stamp, "estimated_worst_case_usd": round(est["total"], 4)}

    def on_term(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_term)
    runner = Runner(cfg, C.Client(base, key, a.timeout), outdir, log=out)
    out("Results go to %s" % outdir)
    code = runner.run()
    out("Wrote results.json and results.md (not the key, no ids)." if os.path.exists(os.path.join(outdir, "results.md")) else "No results written.")
    return code


def safe_main():
    try:
        return main()
    except KeyboardInterrupt:
        out("interrupted")
        return 130
    except SystemExit:
        raise
    except Exception as e:  # never show a raw traceback (it could carry request details)
        out("error: %s: %s" % (type(e).__name__, e))
        return 1


if __name__ == "__main__":
    sys.exit(safe_main())
