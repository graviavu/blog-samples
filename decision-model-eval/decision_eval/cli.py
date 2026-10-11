#!/usr/bin/env python3
"""Entry point behind run-eval.sh. Runs the side-by-side eval of YOUR decision model (HTTP) against an optional LLM
baseline (a command you supply), on the bundled synthetic emails and a routing TSV. Advisory only: nothing is sent,
moved or routed. Use run-eval.sh, which adds the typed confirmation and the redacted log."""
import argparse
import os
import shlex
import shutil
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness as h  # noqa: E402
import metrics as m  # noqa: E402
from adapters import DataLog, Fallback, HttpDecisionModel  # noqa: E402
from contract import redact  # noqa: E402
from llm import CommandLLM, StopRun, claude_argv  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_argument
    g("--url", help="base url of your decision-model server (loopback unless --allow-remote)")
    g("--label", default="my-model")
    g("--shape", default="systemone", choices=["systemone", "simple"])
    g("--path", default=None, help="endpoint path (default depends on --shape)")
    g("--timeout", type=float, default=60, help="seconds per local-model call")
    g("--allow-remote", action="store_true")
    g("--emails", default=os.path.join(ROOT, "data", "triage", "emails"))
    g("--expected", default=os.path.join(ROOT, "data", "triage", "expected.tsv"))
    g("--routing", default=os.path.join(ROOT, "data", "routing-example.tsv"), help="TSV: ts idea task_type chosen outcome note")
    g("--tiers", default=None, help="JSON file {option: description} to replace haiku/sonnet/opus")
    g("--limit", type=int, default=0, help="first N emails and N routing rows only (0 = all)")
    g("--results-dir", default=os.path.join(ROOT, "results"))
    g("--run-id", default=None)
    g("--skip-backup", action="store_true")
    g("--backup-timeout", type=float, default=3.0)
    g("--backup-items", type=int, default=6)
    g("--backup-primary-cmd", default="sleep 600", help="simulated unreachable primary (a command that hangs)")
    g("--llm-cmd", default=None, help="command that reads the prompt on stdin and prints the answer, e.g. 'claude -p ...'")
    g("--llm-preset", default=None, choices=["claude"], help="claude -p with the isolation flags (checked against --help)")
    g("--llm-bin", default="claude")
    g("--llm-model", default="sonnet")
    g("--llm-timeout", type=int, default=180)
    g("--llm-routing-rows", type=int, default=15, help="routing rows sent to the LLM (direct/orig only)")
    g("--llm-reversed-rows", type=int, default=0, help="extra routing rows also sent reversed/orig")
    g("--budget", type=float, default=None, help="USD hard stop for the LLM baseline (required with an LLM)")
    g("--est-cost-per-call", type=float, default=None, help="USD, used when the command reports no cost (required)")
    g("--max-calls", type=int, default=None)
    g("--confirmed-llm", action="store_true", help="set by run-eval.sh after the typed confirmation")
    g("--dry-run", action="store_true")
    return ap.parse_args(argv)


def say(*a):
    print(redact(" ".join(str(x) for x in a)), flush=True)


def load_tiers(path):
    if not path:
        return h.TIERS
    import json
    with open(path) as fh:
        t = json.load(fh)
    if not isinstance(t, dict) or len(t) < 2 or not all(isinstance(v, str) for v in t.values()):
        raise SystemExit("--tiers must be a JSON object with at least two {option: description} entries")
    return t


def llm_enabled(a):
    return bool(a.llm_cmd or a.llm_preset)


def make_plan(a, emails, rows, tiers):
    n_em = len(emails)
    n_rows = len(rows)
    llm_rows = len(h.spaced(rows, a.llm_routing_rows))
    rev_rows = len(h.spaced(rows, a.llm_reversed_rows)) if a.llm_reversed_rows else 0
    p = {"emails": n_em, "routing_rows": n_rows, "options": list(tiers),
         "local_calls": n_em + n_rows * 6, "backup_items": 0 if a.skip_backup else min(a.backup_items, n_em + n_rows),
         "llm_calls": 0}
    p["backup_worst_case_s"] = round(p["backup_items"] * a.backup_timeout, 1)
    if llm_enabled(a):
        p["llm_calls"] = n_em + llm_rows + rev_rows
        p["llm_est_usd"] = round(p["llm_calls"] * (a.est_cost_per_call or 0), 4)
    return p


def inputs(a):
    for path, what in ((a.emails, "emails folder"), (a.expected, "expected.tsv"), (a.routing, "routing TSV")):
        if not os.path.exists(path):
            raise SystemExit(f"missing {what}: {path}")
    emails = h.list_emails(a.emails)
    if a.limit:
        emails = emails[:a.limit]
    rows = h.read_routing(a.routing)
    if a.limit:
        rows = rows[:a.limit]
    if not emails or not rows:
        raise SystemExit("need at least one email and one routing row")
    return emails, rows


def print_plan(a, p, dry):
    say("== DRY RUN (no model calls, no network, no files written) ==" if dry else "== plan ==")
    say(f"local model    : {a.label} at {a.url or '(--url missing)'} shape={a.shape} path={a.path or '(default)'}")
    say(f"inputs         : {p['emails']} emails ({a.emails}), {p['routing_rows']} routing rows ({a.routing}), options {p['options']}")
    say(f"local calls    : {p['local_calls']} (emails + rows x 2 wordings x 3 option orders), free of charge")
    if p["backup_items"]:
        say(f"backup test    : {p['backup_items']} items, primary = `{a.backup_primary_cmd}` killed at {a.backup_timeout}s "
            f"(simulated outage, no LLM call), then the local model; worst case {p['backup_worst_case_s']}s")
    else:
        say("backup test    : skipped")
    if llm_enabled(a):
        how = f"claude preset (bin {a.llm_bin}, model {a.llm_model}; isolation flags checked against --help before any call)" \
            if a.llm_preset else f"command `{a.llm_cmd}`"
        say(f"LLM baseline   : {how}")
        say(f"LLM calls      : up to {a.max_calls if a.max_calls is not None else p['llm_calls']} of {p['llm_calls']} planned; "
            f"est ${p['llm_est_usd']} at ${a.est_cost_per_call}/call; budget ${a.budget}; PAID calls: typed confirmation required")
        if a.budget is None or a.est_cost_per_call is None:
            say("PROBLEM        : --budget and --est-cost-per-call are required with an LLM baseline")
        elif p["llm_est_usd"] > a.budget:
            say(f"NOTE           : planned LLM calls (${p['llm_est_usd']}) exceed --budget; the guard will stop early")
    else:
        say("LLM baseline   : none (local model only; no confirmation needed)")
    say(f"outputs        : {a.results_dir}/{{metrics.json,REPORT.md,data/*.jsonl}} (request/response data kept for back-testing)")


def table(rows):
    return "\n".join(rows) + "\n"


def report_md(label, llm_name, res):
    L = [f"# Decision-model eval report\n\nRun {res['run_id']}. Model under test: `{label}`. LLM baseline: {llm_name or 'none'}.\n",
         "n is small. Read every number with the caveats in README.md before quoting it.\n", "## Email triage\n",
         "| metric | " + " | ".join(res["triage"]) + " |", "|---|" + "---|" * len(res["triage"])]
    keys = ["n_answered", "accuracy", "urgent_recall", "injection_correct", "schema_valid_rate", "ece_5bins", "ece_n",
            "latency_ms_median", "latency_ms_p95", "urgent_buried_as_ignore", "ignore_promoted_to_urgent"]
    for k in keys:
        L.append(f"| {k} | " + " | ".join(str(res["triage"][n].get(k)) for n in res["triage"]) + " |")
    L.append("")
    if "triage_agreement" in res:
        L.append(f"Agreement between the two on triage: {res['triage_agreement']}\n")
    L += ["## Routing shadow\n", "| metric | " + " | ".join(res["routing"]) + " |", "|---|" + "---|" * len(res["routing"])]
    rk = sorted({k for r in res["routing"].values() for k in r})
    for k in rk:
        L.append(f"| {k} | " + " | ".join(str(res["routing"][n].get(k)) for n in res["routing"]) + " |")
    L.append("")
    if "routing_agreement" in res:
        L.append(f"Agreement between the two on routing (direct/orig rows both answered): {res['routing_agreement']}\n")
    if res.get("backup"):
        L += ["## Backup path\n", f"{res['backup']}\n"]
    if res.get("llm_run"):
        L += ["## LLM baseline run\n", f"{res['llm_run']}\n"]
    L.append("Reference labels for routing are the tier that was actually chosen, not a ground truth.")
    return "\n".join(L) + "\n"


def main(argv=None):
    a = parse(argv)
    emails, rows = inputs(a)
    tiers = load_tiers(a.tiers)
    p = make_plan(a, emails, rows, tiers)
    if llm_enabled(a) and a.llm_cmd and a.llm_preset:
        raise SystemExit("use --llm-cmd or --llm-preset, not both")
    if llm_enabled(a) and (a.budget is None or a.est_cost_per_call is None):
        if a.dry_run:
            print_plan(a, p, True)
        raise SystemExit("LLM baseline needs --budget and --est-cost-per-call (spend guard fails closed)")
    if a.dry_run:
        print_plan(a, p, True)
        return 0
    if not a.url:
        raise SystemExit("--url is required (your decision-model server)")
    if llm_enabled(a) and not a.confirmed_llm:
        raise SystemExit("refusing paid/LLM calls without the typed confirmation: run ./run-eval.sh")
    print_plan(a, p, False)

    run_id = a.run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    data = os.path.join(a.results_dir, "data")
    os.makedirs(os.path.join(data, "inputs"), exist_ok=True)
    shutil.copytree(a.emails, os.path.join(data, "inputs", "emails"), dirs_exist_ok=True)  # exact inputs for back-testing
    shutil.copy(a.expected, os.path.join(data, "inputs", "expected.tsv"))
    shutil.copy(a.routing, os.path.join(data, "inputs", "routing_used.tsv"))
    expected = h.load_expected(a.expected)

    local = HttpDecisionModel(a.url, a.label, a.shape, a.path, a.timeout, a.allow_remote,
                              DataLog(os.path.join(data, f"local-{a.label}.jsonl"), run_id))
    res = {"run_id": run_id, "label": a.label, "plan": p, "triage": {}, "routing": {}}
    tri, rou = {}, {}
    tri[a.label], rou[a.label] = [], []
    say(f"-- local model: triage ({len(emails)}) and routing ({len(rows)} rows x 6)")
    h.run_triage(local, a.emails, emails, tri[a.label])
    h.run_routing(local, h.routing_variants(rows, tiers), tiers, rou[a.label])
    if not any(not i["error"] for i in tri[a.label] + rou[a.label]):
        say("FAILED: the local model answered nothing. First error:", (tri[a.label][0]["error"] or "")[:200])
        return 2

    # backup path: simulated outage -> local model, over triage + direct/orig routing items
    if p["backup_items"]:
        say(f"-- backup path: {p['backup_items']} items, simulated primary outage, timeout {a.backup_timeout}s")
        jobs = [(f"triage|{fn}", h.triage_request(h.read_email(a.emails, fn)), expected.get(fn, (None,))[0]) for fn in emails]
        orders = h.orders_for(tiers)
        jobs += [(f"tier|{r['row']}|direct|orig", h.routing_request(r, "direct", orders["orig"], tiers), r["chosen"]) for r in rows]
        fb = Fallback(shlex.split(a.backup_primary_cmd), local, a.backup_timeout)
        bk = []
        h.run_backup(fb, h.spaced(jobs, p["backup_items"]), bk)
        BackupLog = DataLog(os.path.join(data, "backup.jsonl"), run_id)
        for r in bk:
            BackupLog.write(r)
        res["backup_records"] = bk

    # LLM baseline
    llm_name, llm_note = None, None
    if llm_enabled(a):
        llm_name = f"llm-{a.llm_preset or 'cmd'}"
        argv_l = claude_argv(a.llm_bin, a.llm_model) if a.llm_preset else shlex.split(a.llm_cmd)
        llm = CommandLLM(argv_l, llm_name, DataLog(os.path.join(data, "llm.jsonl"), run_id), a.budget,
                         a.est_cost_per_call, a.max_calls if a.max_calls is not None else p["llm_calls"], a.llm_timeout)
        tri[llm_name], rou[llm_name] = [], []
        stopped = None
        try:
            say(f"-- LLM baseline ({llm_name}): up to {p['llm_calls']} calls, budget ${a.budget}")
            h.run_triage(llm, a.emails, emails, tri[llm_name], purpose="llm-triage")
            sub = h.spaced(rows, a.llm_routing_rows)
            only = [("direct", "orig")]
            v = h.routing_variants(sub, tiers, only)
            if a.llm_reversed_rows:
                v += h.routing_variants(h.spaced(rows, a.llm_reversed_rows), tiers, [("reversed", "orig")])
            h.run_routing(llm, v, tiers, rou[llm_name], purpose="llm-routing")
        except StopRun as e:
            stopped = str(e)
        finally:
            llm.close()
        llm_note = (f"{llm.new_calls} new calls this run, {llm.calls} calls in total, est. spend ${llm.spent:.4f} of ${a.budget} "
                    f"(estimate: reported cost where the command gives one, else --est-cost-per-call)"
                    + (f"; STOPPED: {stopped}" if stopped else ""))
        say(llm_note)
        res["llm_run"] = llm_note

    for n in tri:
        res["triage"][n] = m.triage_metrics(tri[n], expected)
        res["routing"][n] = m.routing_metrics(rou[n])
    if llm_name:
        pick = lambda items: {i["key"]: i["pick"] for i in items if not i["error"]}  # noqa: E731
        res["triage_agreement"] = m.agreement(pick(tri[a.label]), pick(tri[llm_name]))
        res["routing_agreement"] = m.agreement(pick(rou[a.label]), pick(rou[llm_name]))
    if res.get("backup_records"):
        bk = res.pop("backup_records")
        cmp_ = [r for r in bk if r["agree_reference"] is not None]
        res["backup"] = {"items": len(bk), "taken_over_after_timeout": sum(1 for r in bk if r["local_answer"]
                                                         and r["primary_status"] == "primary_timeout"),
                         "timeout_s": a.backup_timeout, "median_switchover_ms": m.median([r["switchover_ms"] for r in bk]),
                         "median_local_ms": m.median([r["local_ms"] for r in bk]),
                         "compared_to_reference": len(cmp_),
                         "agreement_with_reference": m.ratio(sum(r["agree_reference"] for r in cmp_), len(cmp_))}
        if llm_name:
            ll = pick(tri[llm_name]) | pick(rou[llm_name])
            both = [r for r in bk if r["local_answer"] and r["key"] in ll]
            res["backup"]["agreement_with_llm"] = m.agreement({r["key"]: r["local_answer"] for r in both}, ll)
    h.dump_json(os.path.join(a.results_dir, "metrics.json"), res)
    with open(os.path.join(a.results_dir, "REPORT.md"), "w") as f:
        f.write(redact(report_md(a.label, llm_name, res)))
    say("-- done. metrics.json and REPORT.md in", a.results_dir)
    say(redact(report_md(a.label, llm_name, res)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
