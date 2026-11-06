"""Entry point. Default and --dry-run: print the plan and the cost bound, no network call, no file.
--probe: step 1 only. --run: probe, then the latency arms. Both need the typed phrase SPEND UP TO $<cap>."""
import argparse
import math
import os
import re
import secrets
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bedrock_latency import client as C  # noqa: E402
from bedrock_latency import plan, pricing  # noqa: E402
from bedrock_latency import redact as R  # noqa: E402
from bedrock_latency.runner import Runner  # noqa: E402

TOKEN_ENV = "AWS_BEARER_TOKEN_BEDROCK"
# Documented pattern on the Claude in Amazon Bedrock page (read 2026-11-06). Made an option because it is the one fact the run depends on.
DEFAULT_ENDPOINT = "https://bedrock-mantle.{region}.api.aws/anthropic"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def out(msg=""):
    print(R.redact(msg), flush=True)


def usd(text):
    try:
        v = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("not a number: %r" % text)
    if not math.isfinite(v) or v <= 0:
        raise argparse.ArgumentTypeError("must be a finite number above 0")
    return v


def int_list(text):
    try:
        v = [int(x) for x in text.split(",") if x.strip()]
    except ValueError:
        raise argparse.ArgumentTypeError("expected comma-separated integers, e.g. 20000,100000,200000")
    if not v or min(v) < 1000:
        raise argparse.ArgumentTypeError("each size must be at least 1000 tokens")
    return v


def parser():
    p = argparse.ArgumentParser(prog="run-test.sh", description="Latency of long conversations on Amazon Bedrock: full resend vs prompt cache vs message thread.")
    m = p.add_mutually_exclusive_group()
    m.add_argument("--dry-run", action="store_true", help="print the plan and the cost bound; no network call, no files (this is also the default)")
    m.add_argument("--probe", action="store_true", help="step 1 only: do threads work here? A few cents at most. Needs the typed phrase")
    m.add_argument("--run", action="store_true", help="probe, then the latency arms. Needs the typed phrase")
    p.add_argument("--models", default="sonnet-5-5,haiku-5-5", help="comma-separated; short names get the anthropic.claude- prefix (default sonnet-5-5,haiku-5-5)")
    p.add_argument("--probe-model", default="haiku-5-5", help="model for the probe (default haiku-5-5, the cheapest)")
    p.add_argument("--sizes", type=int_list, default=[20000, 100000, 200000], help="context sizes in tokens (default 20000,100000,200000)")
    p.add_argument("--reps", type=int, default=3, help="measured turns per cell (default 3)")
    p.add_argument("--max-tokens", type=int, default=64, help="output cap per request, thinking included (default 64)")
    p.add_argument("--effort", default="low", choices=["none", "low", "medium", "high"], help="output_config.effort on every request; none leaves it out. The probe drops it if the endpoint refuses it (default low)")
    p.add_argument("--max-usd", type=usd, default=5.0, help="spend cap in USD (default 5). The run refuses to start if the planned worst case is above it")
    p.add_argument("--region", default=os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1", help="AWS region for the default endpoint (default: AWS_REGION, else us-east-1)")
    p.add_argument("--endpoint", default=None, help="base URL up to and including /anthropic; default " + DEFAULT_ENDPOINT + ". /v1/messages is appended")
    p.add_argument("--auth-header", choices=["x-api-key", "bearer"], default="x-api-key", help="how the bearer token is sent: x-api-key header (what the Bedrock page shows, default) or Authorization: Bearer")
    p.add_argument("--anthropic-version", default="2026-10-21", help="anthropic-version header; empty string omits it (default 2026-10-21, taken from the Claude API docs)")
    p.add_argument("--prices", default=None, help="JSON file that overrides or adds per-model prices (see README)")
    p.add_argument("--price-multiplier", type=float, default=1.0, help="multiply every price, e.g. 1.1 for a regional endpoint (default 1.0)")
    p.add_argument("--margin", type=float, default=1.1, help="assumed worst-case tokens / size target (default 1.1)")
    p.add_argument("--chars-per-token", type=float, default=3.5, help="starting guess to size the filler; measured per model before the arms (default 3.5)")
    p.add_argument("--retries", type=int, default=1, help="retries on clear transient errors only (default 1)")
    p.add_argument("--timeout", type=int, default=600, help="seconds per request (default 600)")
    p.add_argument("--results-dir", default=os.path.join(ROOT, "results"))
    return p


def phrase(cap):
    return "SPEND UP TO $%s" % ("%.2f" % cap).rstrip("0").rstrip(".")


def print_plan(a, cfg, pl, endpoint, mode):
    out("PLAN (a dry run sends nothing)")
    out("  endpoint             %s/v1/messages" % endpoint)
    out("  auth                 %s from the environment; header name: %s" % (TOKEN_ENV, "Authorization (Bearer scheme)" if a.auth_header == "bearer" else "x-api-key"))
    out("  models               %s" % ", ".join(cfg["models"]))
    out("  step 1 probe         %d tiny requests on %s (plain, thread create, thread continue); about $%.4f at most" % (plan.PROBE_REQUESTS, cfg["probe_model"], pl["probe_bound"]))
    if mode == "probe":
        out("  step 2 arms          not in this mode (use --run)")
    else:
        out("  step 2 sizes         %s tokens, %d measured turns per cell; per model one %d-token calibration request" % (", ".join(str(s) for s in a.sizes), a.reps, plan.CAL_TOKENS))
        for arm in plan.ARMS:
            n = plan.counts(a.reps)[arm]
            out("  arm %s                %-28s %d requests per cell%s" % (arm, plan.ARM_NAMES[arm], n, "  (only if the probe says ACCEPTED)" if arm == "C" else ""))
        out("  requests             up to %d in total" % pl["requests"])
        out("  cost bound per cell  (model, size: all arms)")
        for c in pl["cells"]:
            out("    %-12s %7d   $%.2f" % (pricing.model_key(c["model"]), c["size"], sum(x["bound_usd"] for x in c["arms"].values())))
        out("  typical cost         about $%.2f if cache reads work and replies are short (an estimate, not a bound)" % plan.typical(cfg, cfg["_prices"]))
    out("  prices (USD/MTok)    Anthropic list prices read 2026-11-05, multiplier %g. Bedrock's own prices are UNKNOWN here; override with --prices" % a.price_multiplier)
    out("  bound rule           every prompt token billed at the dearer of input and cache-write price, no cache-read credit, every reply at the output cap;")
    out("                       failed requests are assumed unbilled unless a stream had started; the run also checks spend before and after every request")
    total = pl["probe_bound"] if mode == "probe" else pl["total"]
    out("  PLANNED WORST CASE   $%.2f   (cap $%.2f)" % (total, a.max_usd))
    return total


def main(argv=None):
    a = parser().parse_args(argv)
    mode = "run" if a.run else "probe" if a.probe else "dry"
    if min(a.reps, a.max_tokens, a.timeout) < 1 or a.retries < 0 or a.margin < 1 or a.chars_per_token <= 0 or not math.isfinite(a.price_multiplier) or a.price_multiplier <= 0:
        out("error: counts and sizes must be positive, margin at least 1")
        return 2
    if not re.fullmatch(r"[a-z0-9\-]{2,30}", a.region):
        out("error: bad --region")
        return 2
    endpoint = (a.endpoint or DEFAULT_ENDPOINT.format(region=a.region)).rstrip("/")
    try:
        scheme, host, port, prefix = C.parse_endpoint(endpoint)
        overrides = pricing.load_overrides(a.prices) if a.prices else None
        prices = pricing.Prices(overrides, a.price_multiplier)
        models = [pricing.model_id(x.strip()) for x in a.models.split(",") if x.strip()]
        if not models:
            raise ValueError("--models is empty")
        probe_model = pricing.model_id(a.probe_model)
        for m in models + [probe_model]:
            prices.tier(m, 1)
    except (ValueError, OSError) as e:
        out("error: %s" % e)
        return 2
    cfg = {"models": models, "probe_model": probe_model, "sizes": a.sizes, "reps": a.reps, "max_tokens": a.max_tokens, "margin": a.margin,
           "thread_arm": True, "effort": a.effort, "max_usd": a.max_usd, "chars_per_token": a.chars_per_token, "retries": a.retries,
           "probe_only": mode == "probe", "_prices": prices}
    pl = plan.build(cfg, prices)
    total = print_plan(a, cfg, pl, endpoint, mode)
    over = total > a.max_usd
    if over:
        out("  EXCEEDS THE CAP by $%.2f. %s" % (total - a.max_usd, "A real run would refuse to start." if mode == "dry" else "Refusing to start."))
        out("  Lower --sizes, --reps or --models, or raise --max-usd on purpose.")
    if mode == "dry":
        out("Dry run: no network call made, no file written. Next: --probe (cheap), then --run.")
        return 0
    if over:
        return 2
    token = os.environ.get(TOKEN_ENV, "")
    if not token:
        out("error: set %s in your environment (it is never printed or stored)" % TOKEN_ENV)
        return 2
    R.add_secret(token)
    out("")
    out("This sends paid requests with your Bedrock API key to %s and stops at the cap." % host)
    out("To go ahead type exactly: %s" % phrase(a.max_usd))
    sys.stdout.flush()
    if sys.stdin.readline().rstrip("\r\n") != phrase(a.max_usd):
        out("Not confirmed. No calls made.")
        return 2
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    outdir = os.path.join(a.results_dir, stamp)
    run_cfg = dict(cfg, nonce=stamp + secrets.token_hex(3), started_utc=stamp)
    del run_cfg["_prices"]
    keys = {pricing.model_key(m) for m in models + [probe_model]}
    run_cfg["public"] = {"models": models, "probe_model": probe_model, "sizes": a.sizes, "reps": a.reps, "max_tokens": a.max_tokens, "effort": a.effort,
                         "max_usd": a.max_usd, "margin": a.margin, "region": a.region, "endpoint_host": host, "auth_header": a.auth_header,
                         "anthropic_version": a.anthropic_version, "price_multiplier": a.price_multiplier, "retries": a.retries, "mode": mode,
                         "prices_usd_per_mtok": {k: v for k, v in prices.table.items() if k in keys},
                         "planned_worst_case_usd": round(total, 4)}

    def on_term(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, on_term)
    cl = C.Client(endpoint, token, a.auth_header, a.anthropic_version, a.timeout)
    runner = Runner(run_cfg, cl, prices, outdir, out)
    out("Results go to %s" % outdir)
    code = runner.run()
    out("Wrote results.json and results.md (no token, no account id, no request ids). Spent about $%.4f." % runner.spent)
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
