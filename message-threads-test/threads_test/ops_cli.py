"""Entry point of run-ops-test.sh. No flag (or --dry-run) prints the plan and the estimate and makes no network call and writes no file.
--run is the paid mode: the estimate must be at most the cap (default 0.60; raise it on purpose with --max-usd), the phrase
SPEND UP TO $<cap> must be typed at a terminal, then the probe (stops unless ACCEPTED), the free token counts, tests B+, E, A.
Exit codes: 0 done, 2 refused or not confirmed, 3 spend cap, 4 a test stopped or the probe was not ACCEPTED, 5 credit/billing/quota error,
6 key not accepted, 130 Ctrl-C."""
import argparse
import math
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from threads_test import client as C  # noqa: E402
from threads_test import cli  # noqa: E402
from threads_test import ops  # noqa: E402
from threads_test import ops_report  # noqa: E402
from threads_test import probe  # noqa: E402
from threads_test import redact as R  # noqa: E402
from threads_test import report  # noqa: E402
from threads_test.client import FatalApiError  # noqa: E402
from threads_test.runner import Guard  # noqa: E402

out = cli.out
DEFAULT_CAP = 0.60


def rates_arg(text):
    try:
        v = [float(x) for x in text.split(",") if x.strip()]
    except ValueError:
        raise argparse.ArgumentTypeError("not a comma separated list of numbers: %r" % text)
    if any((not math.isfinite(x)) or x <= 0 for x in v):
        raise argparse.ArgumentTypeError("rates must be finite and above 0 (Mbps)")
    return v


def tests_arg(text):
    v = [x.strip().upper() for x in text.split(",") if x.strip()]
    if not v or any(x not in ops.TESTS for x in v):
        raise argparse.ArgumentTypeError("--tests takes a comma separated list from B, E, A")
    return v


def parser():
    p = argparse.ArgumentParser(prog="run-ops-test.sh", description="Operations tests for message threads: B+ body bytes and upload time, "
                                "E dropped-stream retry, A client-side savepoint. Default is a dry run.")
    m = p.add_mutually_exclusive_group()
    m.add_argument("--dry-run", action="store_true", help="print the plan and the estimate; no network call, no file (also what you get with no flag)")
    m.add_argument("--run", action="store_true", help="the paid run: asks for the typed phrase once, then the probe, the free token counts and the tests")
    p.add_argument("--tests", type=tests_arg, default=list(ops.TESTS), help="which tests, comma separated from B,E,A (default B,E,A)")
    p.add_argument("--max-usd", type=cli.usd, default=None, help="spend cap in USD: finite, above 0, at most %g (default %g). The run refuses to start when the estimate is over it" % (cli.HARD_CEILING, DEFAULT_CAP))
    p.add_argument("--model", default="claude-haiku-5-5", help="default: the cheapest model with a price in DOCS-NOTES.md")
    p.add_argument("--probe-model", default="claude-haiku-5-5")
    p.add_argument("--b-tokens", type=int, default=100000, help="B+ history size in tokens (default 100000)")
    p.add_argument("--b-rates", type=rates_arg, default=[1.0, 5.0], help="B+ send throttles in Mbps, comma separated; a no-throttle condition always runs first (default 1,5)")
    p.add_argument("--b-reps", type=int, default=1, help="B+ repetitions of every condition (default 1)")
    p.add_argument("--e-runs", type=int, default=5, help="E runs (default 5)")
    p.add_argument("--e-tokens", type=int, default=20000, help="E history size in tokens (default 20000)")
    p.add_argument("--e-max-tokens", type=int, default=300, help="E output cap per request; a longer reply keeps the stream open longer (default 300)")
    p.add_argument("--a-tokens", type=int, default=20000, help="A history size in tokens (default 20000)")
    p.add_argument("--a-turns", type=int, default=10, help="A main-line requests (default 10)")
    p.add_argument("--a-fork-at", type=int, default=5, help="A turn index of the savepoint, counted from 0 (default 5)")
    p.add_argument("--max-tokens", type=int, default=100, help="output cap per request in B+ and A (default 100)")
    p.add_argument("--effort", default="low", help="output_config.effort on every request; 'none' leaves it out (default low)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--token-margin", dest="margin", type=float, default=1.25, help="assumed worst-case tokens / size (default 1.25)")
    p.add_argument("--chars-per-token", type=float, default=3.2, help="characters per token used to size the history, 2.0 to 4.5 (default 3.2; the free token count adjusts it)")
    p.add_argument("--base-url-host", default=None, help="the only way to send the key to a host other than api.anthropic.com or loopback: name that host exactly")
    p.add_argument("--timeout", type=int, default=600)
    p.add_argument("--results-dir", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results"))
    return p


def validate(a):
    """Returns an error text or None."""
    if a.max_usd <= 0:
        return "--max-usd must be above 0"
    if min(a.b_tokens, a.e_tokens, a.a_tokens, a.max_tokens, a.e_max_tokens, a.b_reps, a.e_runs) < 1:
        return "sizes, counts and token caps must be positive"
    if a.a_turns < 4 or not (1 <= a.a_fork_at <= a.a_turns - 2):
        return "--a-turns must be at least 4 and --a-fork-at between 1 and --a-turns minus 2 (a turn must come before and after the savepoint)"
    if not (math.isfinite(a.margin) and a.margin >= 1.0):
        return "--token-margin must be a finite number of at least 1.0"
    if not (math.isfinite(a.chars_per_token) and 2.0 <= a.chars_per_token <= 4.5):
        return "--chars-per-token must be between 2.0 and 4.5"
    if a.effort not in ("none", "low", "medium", "high", "xhigh", "max"):
        return "--effort must be none, low, medium, high, xhigh or max"
    return None


def sizes_of(a):
    s = []
    for name, size in (("B", a.b_tokens), ("E", a.e_tokens), ("A", a.a_tokens)):
        if name in a.tests and size not in s:
            s.append(size)
    return s


def cfg_of(a, cpt, probe_ub, stamp=""):
    return {"model": a.model, "tests": list(a.tests), "b_tokens": a.b_tokens, "rates": list(a.b_rates), "b_reps": a.b_reps, "e_runs": a.e_runs,
            "e_tokens": a.e_tokens, "e_max_tokens": a.e_max_tokens, "a_tokens": a.a_tokens, "a_turns": a.a_turns, "a_fork_at": a.a_fork_at,
            "max_tokens": a.max_tokens, "margin": a.margin, "effort": a.effort, "seed": a.seed, "salt_nonce": stamp, "cpt": cpt,
            "max_usd": a.max_usd, "probe_bound_usd": probe_ub}


def print_plan(a, pl, probe_ub):
    out("PLAN (nothing is sent in a dry run)")
    out("  model                %s   effort %s" % (a.model, a.effort))
    out("  step 1 probe         up to %d tiny requests on %s; at most $%.4f; the run stops unless it says ACCEPTED" % (probe.PROBE_REQUESTS, a.probe_model, probe_ub))
    out("  step 2 token counts  free count_tokens calls, one per history size (%s); the run refuses before any full-size request if a history does not fit" % ", ".join(str(s) for s in sizes_of(a)))
    t = pl["tests"]
    if "B" in t:
        conds = ["no throttle"] + ["%g Mbps" % r for r in a.b_rates]
        out("  test B+              %d requests: 1 cold prime, then per condition (%s) x %d rep: cached full resend, thread create, thread continue; %d-token history, up to %d prompt tokens assumed; expected $%.4f" % (
            t["B"]["requests"], ", ".join(conds), a.b_reps, a.b_tokens, t["B"]["prompt_tokens_ub"], t["B"]["expected"]))
        out("                       measures: body bytes, time until the last body byte was sent, TTFT, total, usage, cost; bytes per token")
    if "E" in t:
        out("  test E               %d requests: %d runs x (create, continue cut after the first delta, the same continue again, replay create); %d-token history; expected $%.4f" % (
            t["E"]["requests"], a.e_runs, a.e_tokens, t["E"]["expected"]))
        out("                       measures: which of success, thread_already_continued, thread_continue_in_flight comes back; usage and UTC window for the Console")
    if "A" in t:
        out("  test A               %d requests: %d cached main-line turns, then two forks from turn %d; %d-token history; expected $%.4f" % (
            t["A"]["requests"], a.a_turns, a.a_fork_at, a.a_tokens, t["A"]["expected"]))
        out("                       measures: cache read tokens, cost and TTFT of each fork against the entry written at turn %d" % a.a_fork_at)
    total = pl["expected"] + probe_ub
    out("  no retries and no automatic replays: a failed request is a result; a test that cannot go on stops and the others run")
    out("  ESTIMATE             $%.4f   (expected: cache works as documented, prompts at %.2fx the size on the dearer side of the 100K price step, every reply at its cap, plus the probe)" % (total, a.margin))
    out("  WORST CASE           $%.2f   (information only: no request reads the cache, every prompt token at the dearer of input and write price)" % (pl["worst"] + probe_ub))
    out("  CAP                  $%.2f   (--max-usd; the run refuses to start when the ESTIMATE is over it, and stops when the spent total plus the next request's worst case would pass it)" % a.max_usd)
    return total


def main(argv=None):
    a = parser().parse_args(argv)
    if a.max_usd is None:
        a.max_usd = DEFAULT_CAP
    err = validate(a)
    if err:
        out("error: %s" % err)
        return 2
    try:
        probe_ub = probe.bound(a.probe_model)
        cfg = cfg_of(a, {s: a.chars_per_token for s in sizes_of(a)}, probe_ub)
        pl = ops.plan(cfg)
    except ValueError as e:
        out("error: %s" % e)
        return 2
    base = os.environ.get("ANTHROPIC_BASE_URL", cli.DEFAULT_BASE)
    try:
        C.parse_base(base, a.base_url_host)
    except ValueError as e:
        out("error: ANTHROPIC_BASE_URL: %s" % e)
        return 2
    total = print_plan(a, pl, probe_ub)
    over = total > a.max_usd
    if over:
        out("  OVER THE CAP by $%.2f. %s" % (total - a.max_usd, "A paid run would refuse to start." if not a.run else "Refusing to start."))
    if not a.run:
        out("Dry run: no network call made, no file written. The paid run is ./run-ops-test.sh --run (asks for the typed phrase once).")
        if over:
            out("To go ahead anyway, pass --max-usd with a number at or above the estimate (at most %g), or lower the counts and sizes." % cli.HARD_CEILING)
        return 0
    if over:
        out("Lower the counts and sizes, or pass --max-usd with a number at or above the estimate (at most %g), then run again." % cli.HARD_CEILING)
        return 2
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        out("error: set ANTHROPIC_API_KEY in your environment (it is never printed or stored)")
        return 2
    R.add_secret(key)
    if not sys.stdin.isatty():
        out("Refusing: the phrase must be typed at a terminal.")
        return 2
    out("")
    out("This sends paid requests with your API key to %s, in this order: the probe (stops unless ACCEPTED), the free token counts, then tests %s. "
        "It stops at the cap. It cannot be resumed; if it stops, ops.md and ops.json (PARTIAL) hold what was measured. The send throttle is inside this "
        "program: nothing on your machine or network is changed." % (base, ", ".join(a.tests)))
    out("To go ahead type exactly: %s" % cli.phrase(a.max_usd))
    sys.stdout.flush()
    if sys.stdin.readline().rstrip("\r\n") != cli.phrase(a.max_usd):
        out("Not confirmed. No calls made.")
        return 2
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    outdir = os.path.join(a.results_dir, stamp)
    report.private_dir(a.results_dir)
    report.private_dir(outdir)

    def on_term(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_term)
    client = C.Client(base, key, a.timeout, a.base_url_host)
    guard = Guard(a.max_usd)
    out("Results go to %s" % outdir)
    try:
        rec = cli.run_probe(client, guard, a, outdir)
    except FatalApiError as e:
        out(cli.stop_message(e.kind, e.reason, guard.spent, outdir, resumable=False))
        return 5 if e.kind == "billing" else 6
    if rec["effort_used"] == "none":
        a.effort = "none"
    if rec["verdict"] != probe.ACCEPTED:
        out("Stopping before the tests: the probe did not say ACCEPTED. Spent $%.5f." % guard.spent)
        return 4
    cpt = {}
    for size in sizes_of(a):
        try:
            c, why = cli.count_adjust(a, size, a.chars_per_token, base, key)
        except FatalApiError as e:
            out(cli.stop_message(e.kind, e.reason, guard.spent, outdir, resumable=False))
            return 5 if e.kind == "billing" else 6
        if why:
            out(why)
            out("Spent $%.5f (the probe only). No full-size request was sent." % guard.spent)
            return 2
        cpt[size] = c
    cfg = cfg_of(a, cpt, probe_ub, stamp)
    cfg["probe_verdict"] = rec["verdict"]
    o = ops.Ops(cfg, client, outdir, log=out, guard=guard)
    code = o.run()
    if code in (5, 6) and o.partial:
        out(cli.stop_message(o.partial["kind"], o.partial["reason"], guard.spent, outdir, o.partial.get("stage"), resumable=False))
    out("Wrote ops.md and ops.json (not the key; no message or request ids) under %s. They are not committed anywhere." % outdir)
    return code


def safe_main():
    try:
        return main()
    except KeyboardInterrupt:
        out("interrupted")
        return 130
    except FatalApiError as e:
        out(cli.stop_message(e.kind, e.reason, 0.0, None, resumable=False))
        return 5 if e.kind == "billing" else 6
    except SystemExit:
        raise
    except Exception as e:  # never show a raw traceback (it could carry request details)
        out("error: %s: %s" % (type(e).__name__, e))
        return 1


if __name__ == "__main__":
    sys.exit(safe_main())
