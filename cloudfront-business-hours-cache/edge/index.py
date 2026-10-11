"""Lambda@Edge origin-response function: no cache in business hours, long cache outside, and an object cached just
before the window opens expires AT the opening.

Reads one S3 object with path rules (kept 30 s in memory, parsed once):
  {"rules": [{"path": "/prices/*", "startMin": 480, "endMin": 1020, "inTtl": 0, "outTtl": 14400}, ...],
   "default": {"startMin": 480, "endMin": 1020, "inTtl": 0, "outTtl": 0}}          ("default" is optional)
The rule for the request URI (event["Records"][0]["cf"]["request"]["uri"], query string stripped) is chosen by exact path or
trailing-* prefix; an exact path beats any prefix, the LONGEST matching prefix wins, the first of identical patterns wins,
case-sensitive. No rule and no default: s-maxage=0. A malformed rule is skipped (only its index is logged, never its content).
A URI that is empty, or contains "//", "/./", "/../", a trailing "/." or "/..", any "%" or any backslash gets no window at all: s-maxage=0.

Then it computes the time since 00:00 UTC (to the second, with the fraction) and sets
  Cache-Control: public, max-age=0, s-maxage=<ttl>
  (all of the following per matched rule)
  startMin*60 <= secondsOfDay < endMin*60  -> inTtl   (0 means CloudFront does not cache the object)
  otherwise                                -> min(outTtl, seconds until the next opening), floored, never below 0
"Next opening" is today's start if it is still ahead, otherwise tomorrow's start (86400 - now + start). The cap is computed on
every invocation from the current time; only the window itself is read from S3 (and kept 30 s in memory).

Clock note: the Lambda clock and the CloudFront edge clock can differ by a few seconds, and CloudFront counts the TTL from when it
receives the response. The remaining time is floored, so an object may expire a few seconds EARLY, never late by design.

Only status 200, 203, 204 and 206 are rewritten (errors, redirects and 304 are left alone). A response is also left untouched when
the origin says Cache-Control private, no-store or no-cache, or sets a cookie (set-cookie): the origin knows better than a clock,
and a shared cache must not keep per-user content. Any problem reading or parsing the config gives s-maxage=0, never a long TTL,
and the handler never raises. Only error NAMES are logged, never messages, paths, bucket names or config content.

Lambda@Edge has no environment variables, so run-test.sh replaces the two __PLACEHOLDERS__ below in the packaged copy.
Standard library plus boto3 (part of the Lambda Python runtime); boto3 is imported lazily, so a runtime without it still fails safe.
"""
import json
import math
import re
import time

CONFIG_BUCKET = '__CONFIG_BUCKET__'
CONFIG_KEY = '__CONFIG_KEY__'
CONFIG_CACHE_SECONDS = 30.0   # a good config is kept in memory this long
FAIL_CACHE_SECONDS = 5.0      # a failure is remembered briefly, so an S3 outage does not mean one S3 call per request
# TTLs above the cache policy MaxTTL (86400, see cfn/stack.yaml) would be cut down by CloudFront anyway: such a rule is malformed.
MAX_TTL_SECONDS = 86400
MAX_CONFIG_BYTES = 256 * 1024
MAX_RULES = 1000
S3_TIMEOUT_SECONDS = 1.5   # connect and read; the function timeout is 10 s (a cold boto3 import is slow)
REWRITE_STATUS = frozenset((200, 203, 204, 206))
FALLBACK_CACHE_CONTROL = 'public, max-age=0, s-maxage=0'

_BAD_PATH_CHARS = re.compile(r'[\s\x00-\x1f\x7f?#]')
_URI_VARIANT = re.compile(r'//|/\./|/\.\./|/\.{1,2}$|%|\\')   # also any backslash: \..\ is a dot segment to some servers
_FORBIDS_SHARED = re.compile(r'(^|[\s,])(private|no-store|no-cache)(?=$|[\s,=])', re.IGNORECASE)


class S3ClientUnavailable(Exception):
    """boto3 could not be imported (or the client could not be created)."""


def _log(message):
    print(message)


def _int_in(v, lo, hi):
    """JSON gives 5 or 5.0 for the same number; like the JavaScript original both count as an integer. Not bool, not NaN."""
    if isinstance(v, bool):
        return None
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    if isinstance(v, int) and lo <= v <= hi:
        return v
    return None


def parse_window(c):
    """A window is {startMin,endMin,inTtl,outTtl}: 0 <= startMin < endMin <= 1440 (one window, same UTC day), integer TTLs 0..86400."""
    if not isinstance(c, dict):
        return None
    start = _int_in(c.get('startMin'), 0, 1439)
    end = _int_in(c.get('endMin'), 1, 1440)
    in_ttl = _int_in(c.get('inTtl'), 0, MAX_TTL_SECONDS)
    out_ttl = _int_in(c.get('outTtl'), 0, MAX_TTL_SECONDS)
    if None in (start, end, in_ttl, out_ttl) or start >= end:
        return None
    return {'startMin': start, 'endMin': end, 'inTtl': in_ttl, 'outTtl': out_ttl}


def parse_pattern(path):
    """'/exact/path' or '/prefix/*' (the * only at the very end). No spaces or control characters, at most 1024 characters."""
    if not isinstance(path, str) or not 1 <= len(path) <= 1024 or path[0] != '/':
        return None
    if _BAD_PATH_CHARS.search(path):
        return None
    star = path.find('*')
    if star == -1:
        return {'path': path, 'prefix': False, 'key': path}
    if star != len(path) - 1:
        return None
    return {'path': path, 'prefix': True, 'key': path[:-1]}


def _no_constant(name):
    raise ValueError(name)   # NaN / Infinity / -Infinity are not JSON


def parse_config(text):
    """Returns {'rules': [...], 'default': window|None}, or None when the text is not a usable config at all.
    Bad rules are skipped; only the index is logged."""
    if not isinstance(text, str):
        return None
    if len(text.encode('utf-8', 'replace')) > MAX_CONFIG_BYTES:
        _log('config too large')
        return None
    if text[:1] == '﻿':       # UTF-8 byte order mark (some editors add it)
        text = text[1:]
    try:
        c = json.loads(text, parse_constant=_no_constant)
    except (ValueError, RecursionError):
        return None
    if not isinstance(c, dict):
        return None
    raw_rules = c.get('rules')
    if 'rules' in c and not isinstance(raw_rules, list):
        return None
    if raw_rules is not None and len(raw_rules) > MAX_RULES:
        _log('config too large')
        return None
    rules = []
    for i, r in enumerate(raw_rules or []):
        pat = parse_pattern(r.get('path')) if isinstance(r, dict) else None
        window = parse_window(r) if pat else None
        if not pat or not window:
            _log('rule %d skipped (malformed)' % i)
            continue
        pat['window'] = window
        rules.append(pat)
    default = None
    if 'default' in c:
        default = parse_window(c['default'])
        if not default:
            _log('default skipped (malformed)')
    return {'rules': rules, 'default': default}


def select_window(config, uri):
    """The window for a request URI: query string stripped, exact path beats any prefix, the longest prefix wins, the first of
    equal patterns wins, case-sensitive (matched as CloudFront gives it, not decoded or normalised).
    None = no window: no rule and no default, OR a URI variant that must never be cached (see the module docstring).
    Anything else that matches no rule (for example /Prices/a, or /prices without the slash) gets "default"."""
    path = uri if isinstance(uri, str) else ''
    q = path.find('?')
    if q != -1:
        path = path[:q]
    if path == '' or path[0] != '/' or _URI_VARIANT.search(path):
        return None
    best = None
    for r in config['rules']:
        if r['prefix']:
            if not path.startswith(r['key']):
                continue
            if best is None or len(r['key']) > len(best['key']):   # strictly longer only: first of equals wins
                best = r
        elif path == r['key']:
            return r['window']                                       # exact: cannot be beaten
    return best['window'] if best else config['default']


def seconds_since_midnight_utc(epoch):
    """Seconds since 00:00 UTC with the fraction, so that flooring a remaining time can only make it shorter."""
    return epoch % 86400


def _sane(v):
    """NaN, negative and below 1 all become 0; otherwise floor."""
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return 0
    return int(math.floor(v)) if v > 0 else 0


def ttl_seconds_for(window, epoch):
    """Seconds of the TTL for "now". startMin is inclusive, endMin is exclusive."""
    now = seconds_since_midnight_utc(epoch)
    start = window['startMin'] * 60
    end = window['endMin'] * 60
    if start <= now < end:
        return _sane(window['inTtl'])
    until_open = start - now if now < start else 86400 - now + start   # after the close: tomorrow's opening
    out_ttl = window['outTtl']
    if (isinstance(out_ttl, float) and math.isnan(out_ttl)) or (isinstance(until_open, float) and math.isnan(until_open)):
        return 0
    return _sane(min(out_ttl, until_open))


def cache_control_for(window, epoch):
    return 'public, max-age=0, s-maxage=%d' % ttl_seconds_for(window, epoch)


def origin_forbids_shared(headers):
    """True when the origin asked for no shared caching (private, no-store, no-cache) or sets a cookie."""
    h = headers if isinstance(headers, dict) else {}
    cookies = h.get('set-cookie')
    if isinstance(cookies, list) and len(cookies) > 0:
        return True
    values = h.get('cache-control')
    if values is not None and not isinstance(values, list):
        return True        # a header we do not understand: leave the response alone
    values = values or []
    joined = ','.join(str(v.get('value') or '') for v in values if isinstance(v, dict))
    return bool(_FORBIDS_SHARED.search(joined))


# ---- S3 access. The factory is module level so that the tests can inject a fake client.
_client = None


def _make_client():
    try:
        import boto3                                   # part of the Lambda Python runtime
        from botocore.config import Config
        return boto3.client('s3', region_name='us-east-1',
                            config=Config(connect_timeout=S3_TIMEOUT_SECONDS, read_timeout=S3_TIMEOUT_SECONDS, retries={'max_attempts': 0}))
    except Exception:
        raise S3ClientUnavailable()


S3_CLIENT_FACTORY = _make_client


def load_from_s3():
    """The text of the config object. Raises on any problem (the caller turns that into the fail-safe)."""
    global _client
    if _client is None:
        _client = S3_CLIENT_FACTORY()
    out = _client.get_object(Bucket=CONFIG_BUCKET, Key=CONFIG_KEY)
    raw = out['Body'].read(MAX_CONFIG_BYTES + 1)       # never read more than the limit plus one byte
    return raw.decode('utf-8')


def _error_name(e):
    """A name only, never the message. For a botocore ClientError that is the AWS error code (for example NoSuchKey)."""
    if isinstance(e, S3ClientUnavailable):
        return 's3-client-unavailable'
    response = getattr(e, 'response', None)
    if isinstance(response, dict):
        code = (response.get('Error') or {}).get('Code')
        if isinstance(code, str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', code):
            return code
    return type(e).__name__


def make_handler(load_text, now=time.time, cache_seconds=CONFIG_CACHE_SECONDS, fail_seconds=FAIL_CACHE_SECONDS):
    """load_text() -> str with the config JSON (raises on failure). now() -> epoch seconds. Both injectable for tests."""
    cached = {'config': None, 'until': None}

    def get_config():
        t = now()
        if cached['until'] is not None and t < cached['until']:
            return cached['config']
        try:
            config = parse_config(load_text())
            if not config:
                _log('config invalid, using fallback')
            cached['config'] = config
            cached['until'] = now() + (cache_seconds if config else fail_seconds)
        except Exception as e:                          # noqa: BLE001 - any failure is the fail-safe
            name = _error_name(e)
            _log(name if name == 's3-client-unavailable' else 'config read failed (%s), using fallback' % name)
            cached['config'] = None
            cached['until'] = now() + fail_seconds
        return cached['config']

    def handler(event, context=None):
        try:
            response = event['Records'][0]['cf']['response']
        except Exception:                               # noqa: BLE001
            return {}
        try:
            try:
                status = int(float(response.get('status')))
            except (TypeError, ValueError):
                return response
            if status not in REWRITE_STATUS:
                return response                         # never rewrite errors, redirects, 304
            headers = response.get('headers')
            if origin_forbids_shared(headers):
                return response
            value = FALLBACK_CACHE_CONTROL
            try:
                config = get_config()
                if config:
                    request = event['Records'][0]['cf'].get('request') or {}
                    window = select_window(config, request.get('uri'))
                    if window:                          # no rule and no default: stays at the fallback s-maxage=0
                        value = cache_control_for(window, now())
            except Exception:                           # noqa: BLE001
                value = FALLBACK_CACHE_CONTROL
            if not isinstance(headers, dict):
                headers = {}
                response['headers'] = headers
            headers['cache-control'] = [{'key': 'Cache-Control', 'value': value}]
            return response
        except Exception:                               # noqa: BLE001 - the handler never raises
            return response

    return handler


lambda_handler = make_handler(load_text=load_from_s3)
