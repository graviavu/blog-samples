"""--resume: read a PARTIAL or complete results folder, check it hard, and say which arms and sizes are already done.

Nothing in the folder is trusted. The folder must belong to you and be private (0700), every file is size-limited and shape-checked,
the saved settings must equal the current flags, and the spend is the HIGHEST of what the files claim and what their records add up
to. Anything malformed makes the resume refuse; nothing is guessed."""
import json
import math
import os
import stat

from . import probe as P

MAX_BYTES = 64 * 1024 * 1024
ARMS = (1, 2, 3, 4)
PROBE_VERDICTS = (P.ACCEPTED, P.REJECTED, P.INCONCLUSIVE, "INTERRUPTED", "PARTIAL")
EFFORTS = ("none", "low", "medium", "high", "xhigh", "max")
USAGE = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
COST = ("input", "cache_write", "cache_read", "output", "total")
KINDS = ("turn", "prime", "create", "replay", "reload", "bogus_continue", "reload_after_404", "check_continue",
         "check_double_continue", "expiry_create", "expiry_continue")


class ResumeError(Exception):
    pass


def _num(x, lo=0.0, hi=None):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and x >= lo and (hi is None or x <= hi)


def _int(x, lo=0, hi=10 ** 9):
    return isinstance(x, int) and not isinstance(x, bool) and lo <= x <= hi


def _read(path, what):
    try:
        if os.path.islink(path):
            raise ResumeError("%s is a symbolic link" % what)
        if os.path.getsize(path) > MAX_BYTES:
            raise ResumeError("%s is over %d MB" % (what, MAX_BYTES >> 20))
        with open(path, encoding="utf-8") as f:
            obj = json.load(f)
    except ResumeError:
        raise
    except (OSError, ValueError) as e:
        raise ResumeError("%s cannot be read as JSON (%s)" % (what, type(e).__name__))
    if not isinstance(obj, dict):
        raise ResumeError("%s is not a JSON object" % what)
    return obj


def check_dir(path):
    try:
        st = os.stat(path)
    except OSError:
        raise ResumeError("%s does not exist" % path)
    if not stat.S_ISDIR(st.st_mode) or os.path.islink(path):
        raise ResumeError("%s is not a plain directory" % path)
    if st.st_uid != os.getuid():
        raise ResumeError("%s is not owned by you" % path)
    if st.st_mode & 0o077:
        raise ResumeError("%s is not private (must be 0700)" % path)


def _record(r, i):
    bad = lambda why: ResumeError("record %d is malformed (%s)" % (i, why))  # noqa: E731
    if not isinstance(r, dict):
        raise bad("not an object")
    if not (r.get("arm") in ARMS or r.get("arm") == "check") or isinstance(r.get("arm"), bool):
        raise bad("arm")
    if not (_int(r.get("rep"), 0, 10000) and _int(r.get("turn"), 0, 10000) and _int(r.get("attempt"), 1, 1000)):
        raise bad("rep, turn or attempt")
    if r.get("kind") not in KINDS:
        raise bad("kind")
    if not (r.get("status") is None or _int(r["status"], 100, 599)) or not isinstance(r.get("complete"), bool):
        raise bad("status or complete")
    for k in ("ttft_ms", "total_ms"):
        if r.get(k) is not None and not _num(r[k]):
            raise bad(k)
    u, c = r.get("usage"), r.get("cost")
    if not isinstance(u, dict) or not all(_int(u.get(k), 0, 10 ** 10) for k in USAGE):
        raise bad("usage")
    if not isinstance(c, dict) or not all(_num(c.get(k)) for k in COST):
        raise bad("cost")
    if not _num(r.get("charged_usd")):
        raise bad("charged_usd")


# these must equal the current flags: a different plan would make the finished arms incomparable to the new ones
SAME = ("model", "tokens", "turns", "reps", "nocache_turns", "nocache_reps", "reload_reps", "max_tokens", "seed", "margin", "retries",
        "checks", "expiry_test", "effort", "sizes")


def _size_state(doc, want, what):
    """Validate one results.json and split it into done / dropped parts. want: the expected config for this size."""
    if not isinstance(doc.get("status"), str):
        raise ResumeError("%s: no status" % what)
    spent = doc.get("spent_usd")
    if not _num(spent, 0.0, 10.0):
        raise ResumeError("%s: spent_usd is missing, negative, not finite or above the $10 ceiling" % what)
    flight = doc.get("in_flight_worst_case_usd", 0)
    if not _num(flight, 0.0, 10.0):
        raise ResumeError("%s: in_flight_worst_case_usd is not a plausible number" % what)
    cfg = doc.get("config")
    if not isinstance(cfg, dict):
        raise ResumeError("%s: no config" % what)
    for k in SAME:
        if cfg.get(k) != want[k]:
            raise ResumeError("%s: saved %s is %r but the flags now say %r; resume needs the same flags as the first run" % (what, k, cfg.get(k), want[k]))
    cpt = cfg.get("chars_per_token")
    if not _num(cpt, 2.0, 4.5):
        raise ResumeError("%s: saved chars_per_token is not a number from 2.0 to 4.5" % what)
    recs = doc.get("records")
    if not isinstance(recs, list) or len(recs) > 200000:
        raise ResumeError("%s: records missing or too many" % what)
    for i, r in enumerate(recs):
        _record(r, i)
    wants = {1: want["nocache_reps"], 2: want["reps"], 3: want["reps"], 4: want["reload_reps"]}
    if "completed_units" in doc:
        units = doc["completed_units"]
        if not isinstance(units, list) or not all(isinstance(u, list) and len(u) == 2 and u[0] in ARMS and _int(u[1], 0, wants.get(u[0], 0) - 1)
                                                  and not isinstance(u[0], bool) for u in units):
            raise ResumeError("%s: completed_units is malformed" % what)
        done = {(u[0], u[1]) for u in units}
        checks_done = doc.get("checks_done")
        if not isinstance(checks_done, bool):
            raise ResumeError("%s: checks_done is missing" % what)
    elif doc["status"] == "complete":
        done = {(a, r) for a, n in wants.items() for r in range(n)}
        checks_done = True
    else:
        raise ResumeError("%s: a partial file without completed_units (written by an older version); it cannot be resumed safely" % what)
    for arm, rep in done:
        if not any(r["arm"] == arm and r["rep"] == rep and r["status"] == 200 and r["complete"] for r in recs):
            raise ResumeError("%s: unit arm %d repetition %d is marked done but has no completed request" % (what, arm, rep))
    checks = doc.get("checks", {})
    if not isinstance(checks, dict) or not all(isinstance(v, dict) for v in checks.values()):
        raise ResumeError("%s: checks is malformed" % what)
    abandoned = doc.get("abandoned_records_usd", 0)
    if not _num(abandoned, 0.0, 10.0):
        raise ResumeError("%s: abandoned_records_usd is not a plausible number" % what)
    requests = doc.get("requests", 0)
    if not _int(requests, 0, 10 ** 7):
        raise ResumeError("%s: requests is malformed" % what)
    keep = [(r["arm"] in ARMS and (r["arm"], r["rep"]) in done) or (r["arm"] == "check" and checks_done) for r in recs]
    kept = [r for r, k in zip(recs, keep) if k]
    dropped = sum(r["charged_usd"] for r, k in zip(recs, keep) if not k)
    notes = doc.get("notes", [])
    if not isinstance(notes, list) or not all(isinstance(n, str) for n in notes):
        raise ResumeError("%s: notes is malformed" % what)
    return {"records": kept, "done": done, "checks": checks if checks_done else {}, "checks_done": checks_done, "requests": requests,
            "abandoned_usd": abandoned + dropped, "notes": notes, "chars_per_token": cpt,
            "claimed_spent": spent, "in_flight": flight, "recorded": sum(r["charged_usd"] for r in recs) + abandoned}


def load(path, sizes, want_for, cap):
    """Returns {"probe_ok", "effort_used", "spent", "sizes": {tokens: state or None}}. want_for(i, size, effort_used) gives the expected config of size i.
    Raises ResumeError when anything is off. spent is the highest of the claimed and the recomputed spend, plus any in-flight allowance."""
    check_dir(path)
    out = {"probe_ok": False, "effort_used": None, "sizes": {}}
    claimed, flight, recorded = [], 0.0, 0.0
    pp = os.path.join(path, "probe.json")
    if os.path.exists(pp):
        pr = _read(pp, "probe.json")
        if pr.get("verdict") not in PROBE_VERDICTS:
            raise ResumeError("probe.json: unknown verdict")
        if pr.get("verdict") == P.REJECTED:
            raise ResumeError("the saved probe says REJECTED: this key was refused threads, there is nothing to resume")
        if not _num(pr.get("spent_usd", 0.0), 0.0, 10.0) or not _num(pr.get("in_flight_worst_case_usd", 0.0), 0.0, 10.0):
            raise ResumeError("probe.json: spent numbers are malformed")
        if pr.get("effort_used", "low") not in EFFORTS:
            raise ResumeError("probe.json: effort_used is malformed")
        out["probe_ok"] = pr["verdict"] == P.ACCEPTED
        out["effort_used"] = pr.get("effort_used")
        claimed.append(pr.get("spent_usd", 0.0))
        flight += pr.get("in_flight_worst_case_usd", 0.0)
    multi = len(sizes) > 1
    for i, size in enumerate(sizes):
        fp = os.path.join(path, str(size), "results.json") if multi else os.path.join(path, "results.json")
        if not os.path.exists(fp):
            out["sizes"][size] = None
            continue
        if multi:
            check_dir(os.path.dirname(fp))
        st = _size_state(_read(fp, "%s" % os.path.relpath(fp, path)), want_for(i, size, out["effort_used"]), os.path.relpath(fp, path))
        out["sizes"][size] = st
        claimed.append(st["claimed_spent"])
        flight += st["in_flight"]
        recorded += st["recorded"]
    spent = max(claimed + [recorded, 0.0]) + flight
    if not _num(spent, 0.0, cap) or spent >= cap:
        raise ResumeError("the saved spend ($%.4f, with the in-flight allowance $%.4f) is already at or over the cap $%.2f" % (spent, flight, cap))
    out["spent"] = spent
    return out
