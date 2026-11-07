"""Entry point. No flag (or --dry-run) prints the plan and the worst-case cost and makes no network call.
--probe is step 1 (a few tiny requests), --run is the probe and then the arms, --all is the whole thing in one go (probe, free token count,
arms, summary), --resume DIR finishes a PARTIAL folder. Every paid mode needs the typed phrase SPEND UP TO $<cap>, once.
Exit codes: 0 done, 2 refused or not confirmed, 3 spend cap, 4 aborted or probe not ACCEPTED, 5 credit/billing/quota error, 6 key not accepted, 130 Ctrl-C."""
import argparse
import json
import math
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from threads_test import client as C  # noqa: E402
from threads_test import convo  # noqa: E402
from threads_test import pricing  # noqa: E402
from threads_test import probe  # noqa: E402
from threads_test import report  # noqa: E402
from threads_test import redact as R  # noqa: E402
from threads_test import resume as RS  # noqa: E402
from threads_test.client import FatalApiError  # noqa: E402
from threads_test.runner import Guard, Runner, SpendCap  # noqa: E402

DEFAULT_BASE = "https://api.anthropic.com"


def out(msg=""):
    print(R.redact(msg), flush=True)


HARD_CEILING = 10.0
DEFAULT_CAP = 4.5   # of R's $5 of credit, $0.50 is never touched; the default plan's bound is $4.44
DEFAULT_SIZES = [20000, 100000]


def sizes_arg(text):
    try:
        v = [int(x) for x in text.split(",") if x.strip()]
    except ValueError:
        raise argparse.ArgumentTypeError("not a comma separated list of integers: %r" % text)
    if not v or len(v) > 4 or min(v) < 1 or len(set(v)) != len(v):
        raise argparse.ArgumentTypeError("give 1 to 4 different positive sizes, for example 20000,100000")
    return sorted(v)


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
    m.add_argument("--dry-run", action="store_true", help="print the plan and the worst-case cost; no network call, no files (also what you get with no flag)")
    m.add_argument("--probe", action="store_true", help="step 1: a few tiny requests on a small model; does this key accept the threads beta? Under 1 cent. Asks for the typed phrase")
    m.add_argument("--run", action="store_true", help="the probe, then the latency arms (stops after the probe unless it says ACCEPTED). Asks for the typed phrase")
    m.add_argument("--all", action="store_true", help="the whole test in one command: plan, the typed phrase once, the probe (stops unless ACCEPTED), the free token count (refuses or adjusts the history size before any full-size request), the arms, the summary")
    p.add_argument("--resume", metavar="RESULTS_DIR", default=None, help="finish a PARTIAL (or complete) results folder: skips the arms and sizes already done, runs the rest like --all, with the same flags, the same phrase and the cap applied to what is left (spend so far is read from the saved files). With --dry-run: only shows what is left")
    p.add_argument("--skip-probe", action="store_true", help="with --run: do not repeat the probe (only after --probe said ACCEPTED; saves under 1 cent)")
    p.add_argument("--probe-model", default="claude-haiku-5-5", help="model for the probe (default claude-haiku-5-5, the cheapest)")
    p.add_argument("--model", default="claude-haiku-5-5", help="default: the cheapest model with a price in DOCS-NOTES.md")
    p.add_argument("--sizes", type=sizes_arg, default=DEFAULT_SIZES, help="history sizes in tokens, comma separated, run smallest first (default 20000,100000)")
    p.add_argument("--tokens", type=int, default=None, help="run ONE history size instead of --sizes (for example 500000; the bound grows about 5x per 5x size, so lower the reps and pass --max-usd)")
    p.add_argument("--turns", type=int, default=3, help="follow-up turns per repetition in arms 2 and 3 (default 3)")
    p.add_argument("--reps", type=int, default=2, help="repetitions of arms 2 and 3 (default 2)")
    p.add_argument("--nocache-turns", type=int, default=2, help="requests per repetition in arm 1 (the dearest arm; default 2)")
    p.add_argument("--nocache-reps", type=int, default=1, help="repetitions of arm 1 (default 1)")
    p.add_argument("--reload-reps", type=int, default=None, help="cold reload requests in arm 4 (default: --reps)")
    p.add_argument("--no-checks", dest="checks", action="store_false", help="skip the 404 / double-continue checks")
    p.add_argument("--expiry-test", action="store_true", help="also wait just over 5 minutes idle and continue (slow, cheap)")
    p.add_argument("--expiry-wait", type=int, default=310, help="idle seconds for --expiry-test (default 310)")
    p.add_argument("--max-usd", type=usd, default=DEFAULT_CAP, help="spend cap in USD: finite, above 0, at most %g (default %g; no override)" % (HARD_CEILING, DEFAULT_CAP))
    p.add_argument("--max-tokens", type=int, default=512, help="output cap per request, thinking included (default 512)")
    p.add_argument("--effort", default="low", help="output_config.effort on every request; 'none' leaves it out (default low)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--token-margin", dest="margin", type=float, default=1.25, help="assumed worst-case tokens / --tokens (default 1.25)")
    p.add_argument("--chars-per-token", type=float, default=3.2, help="characters per token used to size the history, 2.0 to 4.5 (default 3.2; the real ratio of this history is UNKNOWN, 3.2 is a guess on the low side; --count-tokens measures it)")
    p.add_argument("--base-url-host", default=None, help="the only way to send the key to a host other than api.anthropic.com or loopback: name that host exactly (ANTHROPIC_BASE_URL must use it)")
    p.add_argument("--retries", type=int, default=1, help="retries per failed request (default 1)")
    p.add_argument("--count-tokens", action="store_true", help="with --run: count the history once with the free count_tokens endpoint before the confirmation (needs the key; not used in dry runs)")
    p.add_argument("--timeout", type=int, default=600)
    p.add_argument("--results-dir", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results"))
    return p


def phrase(cap):
    return "SPEND UP TO $%s" % ("%.2f" % cap).rstrip("0").rstrip(".")


def plan_args(a):
    return {"turns": a.turns, "reps": a.reps, "nocache_turns": a.nocache_turns,
            "nocache_reps": a.nocache_reps, "reload_reps": a.reload_reps, "expiry_test": a.expiry_test,
            "margin": a.margin, "max_tokens": a.max_tokens, "small_tokens": 2000, "checks": a.checks, "retries": a.retries}


def print_plan(a, sizes, est, probe_ub, mode):
    out("PLAN (nothing is sent in a dry run)")
    out("  model                %s" % a.model)
    out("  step 1 probe         up to %d tiny requests on %s (plain, plain again without effort if refused, thread create, thread continue); at most $%.4f"
        % (probe.PROBE_REQUESTS, a.probe_model, probe_ub))
    if mode == "probe":
        out("  step 2 arms          not in this mode (use --run)")
        total = probe_ub
    else:
        total = est["total"] + probe_ub
        out("  step 2 sizes         %s tokens of history, smallest first (the same flags for each size)" % ", ".join(str(t) for t in sizes))
        for k, (t, e) in enumerate(est["per_size"]):
            c = e["counts"]
            out("  --- size %d tokens: worst case assumed %d per request" % (t, e["prompt_tokens_ub"]))
            out("  arm 1 no cache       %d reps x %d requests = %d" % (a.nocache_reps, a.nocache_turns, c["arm1"]))
            out("  arm 2 prompt cache   %d reps x (1 prime + %d turns) = %d" % (a.reps, a.turns, c["arm2"]))
            out("  arm 3 thread + cache %d reps x (1 create + %d continues) = %d" % (a.reps, a.turns, c["arm3"]))
            out("  arm 4 cold reload    %d requests (unique salt, nothing cached)" % c["arm4"])
            if k == 0:
                out("  behaviour checks     %s" % ("2 full-size requests (replay after a 404, one continue); the failing calls cost no tokens" if a.checks else "skipped"))
                if a.expiry_test:
                    out("  expiry test          2 small requests, %d s idle" % a.expiry_wait)
            out("  requests             %d full-size + %d small; the bound adds %d replays (one per arm 3 continue) and attempts every request %d times (--retries %d): %d full-size attempts" % (
                c["sized"], c["small"], c["replays"], 1 + c["retries"], c["retries"], c["attempts"]))
            lo = pricing.tier(a.model, e["prompt_tokens_ub"])
            out("  pricing assumed      per MTok input %.3f, output %.3f, cache write %.3f, cache read %.3f (tier for a %d-token prompt; DOCS-NOTES.md)" % (lo[0], lo[1], lo[2], lo[3], e["prompt_tokens_ub"]))
            out("  bound for this size  $%.2f (one request up to $%.4f)" % (e["total"], e["per_request_ub"]))
        out("  bound rule           every prompt token billed at the dearer of input and cache-write price, no cache-read credit, every output up to --max-tokens %d" % a.max_tokens)
        out("  typical cost         about $%.2f if the cache works as documented and replies are short (a model, not a bound; DOCS-NOTES.md)" % pricing.typical(a.model, plan_args(a), sizes))
    out("  PLANNED UPPER BOUND  $%s   (cap $%.2f; %s; real spend is lower)" % ("%.2f" % total if total >= 0.01 else "%.4f" % total, a.max_usd, "includes retries and replays and the probe" if mode != "probe" else "the probe alone"))
    if mode == "dry":
        out("  for comparison, other single sizes with the same flags (--tokens N):")
        for t in (100000, 500000):
            if [t] != sizes:
                e2 = pricing.estimate_sizes(a.model, plan_args(a), [t])
                tot = e2["total"] + probe_ub
                out("    --tokens %-7d planned upper bound $%.2f%s" % (t, tot, "" if tot <= a.max_usd else "  (over the cap: lower --reps, --turns, --nocache-reps, --nocache-turns, use --no-checks, or raise --max-usd up to %g)" % HARD_CEILING))
    return total


def count_tokens_of(a, size, cpt, base, key):
    hist = convo.build_history(a.seed, size, cpt)
    body = {"model": a.model, "system": convo.system_text("0" * 24), "tools": convo.TOOLS, "messages": hist}
    return C.Client(base, key, a.timeout, a.base_url_host).count_tokens(body)


def count_check(a, size, base, key):
    """Opt-in (--run --count-tokens): count the generated history once with the free count_tokens endpoint. Returns an error text or None."""
    try:
        n = count_tokens_of(a, size, a.chars_per_token, base, key)
    except ValueError as e:
        return "error: %s" % e
    out("count_tokens (free, counted once): the %d-token history is %d tokens (ratio %.2f)." % (size, n, n / size))
    if n > size * a.margin:
        return "Refusing to start: the history is over --tokens x --token-margin (%.0f). Lower --chars-per-token or the size; the bound would not hold." % (size * a.margin)
    return None


def count_adjust(a, size, cpt, base, key):
    """--all: count the history (free), and when it is over --token-margin x size, or under 70% of the size, rebuild it once with the
    measured characters-per-token and count again. Returns (chars_per_token, None) or (None, refusal text). The cost bound depends on
    the size and the margin, not on the ratio, so an adjusted history keeps the bound."""
    lo, hi = size * 0.7, size * a.margin
    for attempt in (1, 2):
        try:
            n = count_tokens_of(a, size, cpt, base, key)
        except ValueError as e:
            return None, "error: %s" % e
        out("count_tokens (free): the %d-token history is %d tokens (ratio %.2f, --chars-per-token %.2f)." % (size, n, n / size, cpt))
        if lo <= n <= hi:
            return cpt, None
        if attempt == 2:
            break
        new = cpt * size / max(n, 1)
        if not (math.isfinite(new) and 2.0 <= new <= 4.5):
            return None, "Refusing to start: the history is %d tokens for a size of %d and the measured ratio would need --chars-per-token %.2f, outside 2.0 to 4.5. Nothing was sent at full size." % (n, size, new)
        out("  adjusting --chars-per-token %.2f -> %.2f for this size and counting again (free)." % (cpt, new))
        cpt = new
    return None, "Refusing to start: after one adjustment the %d-token history still counts %d tokens (allowed %d to %d). Nothing was sent at full size." % (size, n, lo, hi)


def write_json(outdir, name, obj):
    report.write_text(outdir, name, json.dumps(R.redact_obj(obj), indent=2, sort_keys=True) + "\n")


def stop_message(kind, reason, spent, outdir, stage=None):
    what = ("the API reported a credit, billing or quota problem" if kind == "billing"
            else "the API did not accept the key (or it may not use this model or beta)")
    L = ["", "STOPPED: %s." % what, "  %s" % reason,
         "  Nothing more was sent and nothing was retried. Spent so far (counted from the usage fields): $%.5f. The refused request is charged nothing." % spent]
    if stage:
        L.append("  Stage reached: size %s tokens, arm %s, repetition %s, turn %s (%s)." % (stage.get("tokens"), stage.get("arm"), stage.get("rep"), stage.get("turn"), stage.get("kind")))
    if outdir:
        L.append("  Partial results (marked PARTIAL) are in %s and usable as they are." % outdir)
        L.append("  If your balance allows it later: ./run-test.sh --resume %s   (same flags; only the arms not yet done run)" % outdir)
    L.append("  Check your balance and plan in the Console." if kind == "billing" else "  Check ANTHROPIC_API_KEY.")
    return "\n".join(L)


def run_probe(client, guard, a, outdir):
    rec = {}
    try:
        probe.run(client, guard, a.probe_model, a.effort, out, rec)
    except FatalApiError as e:
        rec.update(verdict="PARTIAL", reason="PARTIAL: %s error, stopped at once, no retry (%s)" % (e.kind, e.reason), spent_usd=round(guard.spent, 6))
        write_json(outdir, "probe.json", rec)
        raise
    except BaseException as e:   # Ctrl-C, SIGTERM or the spend cap: keep what the probe knows
        rec["reason"] = "stopped early (%s)" % type(e).__name__
        rec["spent_usd"] = round(guard.spent, 6)
        write_json(outdir, "probe.json", rec)
        wire = rec.get("in_flight_worst_case_usd", 0.0)
        out("Probe stopped (%s). Spent $%.5f.%s Partial probe.json written." % (
            type(e).__name__, guard.spent, " The request on the wire may add up to $%.5f." % wire if wire else ""))
        raise
    out("PROBE VERDICT: %s  (%s)" % (rec["verdict"], rec["reason"]))
    if rec["verdict"] == probe.REJECTED:
        out("Threads were refused for this key or organization. The status and code above are the evidence; nothing more to run.")
    write_json(outdir, "probe.json", rec)
    return rec


def size_cfg(a, i, size, sizes, total, effort):
    return {"model": a.model, "tokens": size, "turns": a.turns, "reps": a.reps, "nocache_turns": a.nocache_turns,
            "nocache_reps": a.nocache_reps, "reload_reps": a.reload_reps, "checks": a.checks and i == 0,
            "expiry_test": a.expiry_test and i == 0, "expiry_wait": a.expiry_wait, "max_usd": a.max_usd,
            "max_tokens": a.max_tokens, "effort": effort, "seed": a.seed, "margin": a.margin,
            "chars_per_token": a.chars_per_token, "retries": a.retries, "small_tokens": 2000,
            "estimated_worst_case_usd": round(total, 4), "sizes": sizes}


def size_done(a, st, want_checks):
    """Is every arm of this size (and its checks, when wanted) already complete in the saved state?"""
    return bool(st) and len(st["done"]) == a.nocache_reps + 2 * a.reps + a.reload_reps and (st["checks_done"] or not want_checks)


def resume_plan(a, sizes, saved, probe_ub):
    """Print what is left and return (remaining bound in dollars including the probe if it must be repeated)."""
    pa = plan_args(a)
    out("RESUME PLAN (nothing is sent in a dry run)")
    out("  results folder       %s" % a.resume)
    out("  spent so far         $%.4f (the highest of what the saved files claim and what their records add up to, plus any request that was on the wire)" % saved["spent"])
    total = 0.0
    if saved["probe_ok"]:
        out("  step 1 probe         already ACCEPTED in the saved probe.json: not repeated")
    else:
        total += probe_ub
        out("  step 1 probe         not ACCEPTED yet in the saved folder: repeated, at most $%.4f" % probe_ub)
    for i, size in enumerate(sizes):
        st = saved["sizes"].get(size)
        ai = dict(pa, tokens=size, checks=a.checks and i == 0, expiry_test=a.expiry_test and i == 0)
        counts = pricing.remaining_counts(ai, st["done"], st["checks_done"]) if st else None
        e = pricing.estimate(a.model, ai, counts)
        total += e["total"]
        c = e["counts"]
        done = "none" if not st else ", ".join("arm %d rep %d" % u for u in sorted(st["done"])) or "none"
        out("  --- size %d tokens: done %s%s" % (size, done, "; behaviour checks done" if st and st["checks_done"] and ai["checks"] else ""))
        out("      left: %d full-size + %d small requests, %d full-size attempts with replays and retries; bound $%.2f" % (c["sized"], c["small"], c["attempts"], e["total"]))
    out("  REMAINING UPPER BOUND $%.2f  + spent $%.4f = $%.2f   (cap $%.2f; real spend is lower)" % (total, saved["spent"], total + saved["spent"], a.max_usd))
    return total


def main(argv=None):
    a = parser().parse_args(argv)
    if a.resume and (a.run or a.probe):
        out("error: --resume goes with --all or alone (it runs like --all), not with --run or --probe")
        return 2
    mode = "dry" if a.dry_run else "all" if (a.all or a.resume) else "run" if a.run else "probe" if a.probe else "dry"
    if a.reload_reps is None:
        a.reload_reps = a.reps
    sizes = [a.tokens] if a.tokens is not None else list(a.sizes)
    if a.tokens is not None and a.sizes != DEFAULT_SIZES:
        out("error: use --tokens (one size) or --sizes, not both")
        return 2
    if a.max_usd <= 0 or min(sizes + [a.turns, a.reps, a.nocache_turns, a.nocache_reps, a.max_tokens]) < 1 or a.reload_reps < 0 or a.retries < 0:
        out("error: counts and sizes must be positive")
        return 2
    if not (math.isfinite(a.margin) and a.margin >= 1.0):
        out("error: --token-margin must be a finite number of at least 1.0 (below 1.0 the cost bound is meaningless)")
        return 2
    if not (math.isfinite(a.chars_per_token) and 2.0 <= a.chars_per_token <= 4.5):
        out("error: --chars-per-token must be between 2.0 and 4.5 (above 4.5 the history may exceed the size the bound assumes)")
        return 2
    if a.effort not in ("none", "low", "medium", "high", "xhigh", "max"):
        out("error: --effort must be none, low, medium, high, xhigh or max")
        return 2
    if a.skip_probe and (a.all or a.resume):
        out("error: --skip-probe does not go with --all or --resume (the probe is part of the automatic run; it is skipped by itself when a saved probe.json already says ACCEPTED)")
        return 2
    try:
        est = pricing.estimate_sizes(a.model, plan_args(a), sizes)
        probe_ub = probe.bound(a.probe_model)
    except ValueError as e:
        out("error: %s" % e)
        return 2
    base = os.environ.get("ANTHROPIC_BASE_URL", DEFAULT_BASE)
    try:
        C.parse_base(base, a.base_url_host)
    except ValueError as e:
        out("error: ANTHROPIC_BASE_URL: %s" % e)
        return 2
    saved = None
    if a.resume:
        def want_for(i, size, effort_used):
            return {"model": a.model, "tokens": size, "turns": a.turns, "reps": a.reps, "nocache_turns": a.nocache_turns,
                    "nocache_reps": a.nocache_reps, "reload_reps": a.reload_reps, "max_tokens": a.max_tokens, "seed": a.seed,
                    "margin": a.margin, "retries": a.retries, "checks": a.checks and i == 0, "expiry_test": a.expiry_test and i == 0,
                    "effort": "none" if effort_used == "none" else a.effort, "sizes": sizes}
        try:
            saved = RS.load(a.resume, sizes, want_for, a.max_usd)
        except RS.ResumeError as e:
            out("Refusing to resume: %s" % e)
            return 2
        left = resume_plan(a, sizes, saved, probe_ub)
        total = left + saved["spent"]
        if saved["probe_ok"] and all(size_done(a, saved["sizes"][s], a.checks and k == 0) for k, s in enumerate(sizes)):
            out("Nothing left to run: every arm and size in %s is complete." % a.resume)
            return 0
    else:
        total = print_plan(a, sizes, est, probe_ub, mode)
    over = total > a.max_usd
    if over:
        out("  EXCEEDS THE CAP by $%.2f. %s" % (total - a.max_usd, "A paid run would refuse to start." if mode == "dry" else "Refusing to start."))
    if mode == "dry":
        out("Dry run: no network call made, no file written. Next: ./run-test.sh --all (probe, token count, run, summary in one go), or --probe and then --run step by step.")
        return 0
    if over:
        out("Lower the sizes, --reps, --turns or --nocache-*, or raise --max-usd (at most %g), then run again." % HARD_CEILING)
        return 2
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        out("error: set ANTHROPIC_API_KEY in your environment (it is never printed or stored)")
        return 2
    R.add_secret(key)
    if not sys.stdin.isatty():
        out("Refusing: the phrase must be typed at a terminal.")
        return 2
    if a.count_tokens and mode == "run":
        for size in sizes:
            try:
                msg = count_check(a, size, base, key)
            except FatalApiError as e:
                out(stop_message(e.kind, e.reason, 0.0, None))
                return 5 if e.kind == "billing" else 6
            if msg:
                out(msg)
                return 2
    out("")
    if mode == "all":
        out("This sends paid requests with your API key to %s, in this order: the probe (stops unless ACCEPTED), the free token count, then the arms, and stops at the cap." % base)
    else:
        out("This sends paid requests with your API key to %s and stops at the cap." % base)
    out("To go ahead type exactly: %s" % phrase(a.max_usd))
    sys.stdout.flush()
    reply = sys.stdin.readline().rstrip("\r\n")
    if reply != phrase(a.max_usd):
        out("Not confirmed. No calls made.")
        return 2
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    if a.resume:
        outdir = a.resume
        stamp += "-resume"
    else:
        outdir = os.path.join(a.results_dir, stamp)
        report.private_dir(a.results_dir)
        report.private_dir(outdir)

    def on_term(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_term)
    client = C.Client(base, key, a.timeout, a.base_url_host)
    guard = Guard(a.max_usd)
    if saved:
        guard.spent = saved["spent"]   # the cap covers the whole folder, not only this run
    out("Results go to %s" % outdir)
    if a.skip_probe and mode == "run":
        out("Probe skipped (--skip-probe): the arms start without checking that threads are accepted.")
        rec = {"verdict": probe.ACCEPTED, "effort_used": a.effort}
    elif saved and saved["probe_ok"]:
        out("Probe not repeated: the saved probe.json says ACCEPTED.")
        rec = {"verdict": probe.ACCEPTED, "effort_used": saved["effort_used"] or a.effort}
    else:
        try:
            rec = run_probe(client, guard, a, outdir)
        except FatalApiError as e:
            out(stop_message(e.kind, e.reason, guard.spent, outdir))
            return 5 if e.kind == "billing" else 6
    if rec["effort_used"] == "none":
        a.effort = "none"   # the endpoint refused output_config.effort; the arms leave it out too
    if mode == "probe":
        out("Probe spent $%.5f. %s" % (guard.spent, "Next: --all, or --run." if rec["verdict"] == probe.ACCEPTED else "No --run until this is ACCEPTED."))
        return 0 if rec["verdict"] == probe.ACCEPTED else 4
    if rec["verdict"] != probe.ACCEPTED:
        out("Stopping before the paid arms: the probe did not say ACCEPTED. Spent $%.5f." % guard.spent)
        return 4
    multi = len(sizes) > 1
    code, entries, runner = 0, [], None
    for i, size in enumerate(sizes):
        sub = os.path.join(outdir, str(size)) if multi else outdir
        report.private_dir(sub)
        st = saved["sizes"].get(size) if saved else None
        cfg = size_cfg(a, i, size, sizes, total, a.effort)
        cfg["salt_nonce"] = ("%s-%d" % (stamp, size)) if multi else stamp   # a different cold prefix for every size and for a resumed run
        if st:
            cfg["chars_per_token"] = st["chars_per_token"]   # the same history as the arms already done
        if mode == "all" and not size_done(a, st, cfg["checks"]):
            try:
                cpt, why = count_adjust(a, size, cfg["chars_per_token"], base, key)
            except FatalApiError as e:
                out(stop_message(e.kind, e.reason, guard.spent, outdir))
                return 5 if e.kind == "billing" else 6
            if why:
                out(why)
                out("Spent $%.5f (the probe only%s). No full-size request was sent for this size." % (guard.spent, "" if not entries else " and the earlier sizes"))
                return 2
            cfg["chars_per_token"] = cpt
        if multi:
            out("=== history size %d tokens (%d of %d) ===" % (size, i + 1, len(sizes)))
        runner = Runner(cfg, client, sub, log=out, guard=guard, resume=st)
        code = runner.run()
        entries.append((size, runner.status, report.summarize(runner.records)))
        if multi:
            report.write_text(outdir, "results.md", report.render_sizes_md(entries, cfg, runner.status if code else "complete so far" if i + 1 < len(sizes) else "complete", guard.spent))
        if code:
            break
    if code in (5, 6) and runner and runner.partial:
        out(stop_message(runner.partial["kind"], runner.partial["reason"], guard.spent, outdir, runner.partial.get("stage")))
    out("Wrote results.json and results.md (not the key; ids matching known patterns are redacted) under %s." % outdir)
    return code


def safe_main():
    try:
        return main()
    except KeyboardInterrupt:
        out("interrupted")
        return 130
    except SpendCap as e:
        out("stopped at the spend cap: %s" % e)
        return 3
    except FatalApiError as e:
        out(stop_message(e.kind, e.reason, 0.0, None))
        return 5 if e.kind == "billing" else 6
    except SystemExit:
        raise
    except Exception as e:  # never show a raw traceback (it could carry request details)
        out("error: %s: %s" % (type(e).__name__, e))
        return 1


if __name__ == "__main__":
    sys.exit(safe_main())
