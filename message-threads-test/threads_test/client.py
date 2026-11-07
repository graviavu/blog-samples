"""Minimal Messages API client: http.client + hand-parsed SSE. The key goes in a header, never in argv or a file."""
import http.client
import json
import re
import time
import urllib.parse

from . import redact as R

API_VERSION = "2026-10-21"  # from the docs cURL example (DOCS-NOTES.md)
BETA = "message-threads-2026-08-12"


class FatalApiError(Exception):
    """The API said the account cannot pay (credit, billing, quota, spend limit) or the key is not accepted.
    Never retried: the run stops, saves what it has and exits non-zero. kind is "billing" or "auth"."""

    def __init__(self, kind, reason):
        super().__init__(reason)
        self.kind, self.reason = kind, reason


# Error types and statuses from https://platform.claude.com/docs/en/api/errors (read 2026-11-07): 402 billing_error, 401
# authentication_error, 403 permission_error, 400 invalid_request_error also for an organization or workspace spend limit, and 429
# rate_limit_error also for a usage tier's monthly spend cap (that 429 has no retry-after header). The exact message text of a
# credit-balance error is UNKNOWN (not on that page), so a 400, 403 or 429 whose body mentions these words also stops the run.
_MONEY_WORDS = re.compile(r"credit|balance|billing|quota|spend (limit|cap)|payment|insufficient funds|purchase", re.I)


def classify(status, error_type, text, retry_after=None):
    """Returns "billing", "auth" or None. Errs on the side of stopping."""
    if status == 402 or error_type == "billing_error":
        return "billing"
    if status == 401 or error_type == "authentication_error":
        return "auth"
    if status in (400, 403, 429) and _MONEY_WORDS.search(text or ""):
        return "billing"
    if status == 429 and not retry_after:
        return "billing"   # docs: a tier spend-cap 429 has no retry-after header and keeps failing; a plain rate limit is expected to carry one
    if status == 403 or error_type == "permission_error":
        return "auth"
    return None


class Result:
    def __init__(self):
        self.status = None
        self.ttft = None
        self.total = None
        self.usage = {}
        self.stop_reason = None
        self.text = ""
        self.first_kind = None
        self.complete = False
        self.error = None        # redacted error body (dict) or message string
        self.error_code = None
        self.error_type = None
        self.retry_after = None
        self.exception = None    # network-level failure, redacted text
        self.response_id = None  # kept in memory only, never written out

    @property
    def transient(self):
        if self.exception:
            return True
        if self.status is not None and self.status == 200 and not self.complete:
            return True
        return self.status in (408, 409, 429, 500, 502, 503, 504, 529)

    def fatal(self):
        """(kind, reason) when this response means the run must stop at once, else None. Reason text is redacted."""
        if self.status == 200 and not self.error:
            return None
        text = json.dumps(self.error) if isinstance(self.error, (dict, list)) else str(self.error or "")
        kind = classify(self.status, self.error_type, text, self.retry_after)
        if not kind:
            return None
        msg = ""
        if isinstance(self.error, dict):
            e = self.error.get("error", self.error)
            msg = str(e.get("message", "")) if isinstance(e, dict) else ""
        elif self.error:
            msg = str(self.error)
        return kind, R.redact("HTTP %s %s%s" % (self.status, self.error_type or "no error type", (": " + msg[:160]) if msg else ""))

    @property
    def ok(self):
        return self.status == 200 and self.complete and not self.error


def is_loopback(host):
    return host in ("127.0.0.1", "localhost", "::1")


OFFICIAL_HOST = "api.anthropic.com"


def parse_base(url, allow_host=None):
    """Only https://api.anthropic.com or a loopback stub is accepted. Any other host needs allow_host
    (--base-url-host) to name it exactly: the API key goes to whatever host this names."""
    u = urllib.parse.urlparse(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("bad base URL")
    if u.username is not None or u.password is not None:
        raise ValueError("credentials inside the base URL are not accepted")
    host = u.hostname.lower()
    named = allow_host is not None and host == allow_host.strip().lower()
    if not (is_loopback(host) or (host == OFFICIAL_HOST and u.scheme == "https") or named):
        raise ValueError("host %r is not api.anthropic.com or a loopback stub; the API key would be sent there. "
                         "If you mean it, pass --base-url-host %s" % (host, host))
    if u.scheme == "http" and not is_loopback(u.hostname):
        raise ValueError("refusing plain http to a non-loopback host: the key would travel unencrypted")
    return u.scheme, u.hostname, u.port or (443 if u.scheme == "https" else 80)


def _parse_error(raw):
    """(error type or None, redacted body). The body is a dict when it is JSON, else the first 500 characters."""
    try:
        obj = json.loads(raw)
    except ValueError:
        return None, R.redact(raw[:500])
    err = obj.get("error") if isinstance(obj, dict) else None
    etype = err.get("type") if isinstance(err, dict) and isinstance(err.get("type"), str) else None
    return etype, R.redact_obj(obj)


def _error_code(body):
    err = body.get("error") if isinstance(body, dict) else None
    d = err.get("details") if isinstance(err, dict) else None
    return d.get("error_code") if isinstance(d, dict) else None


class Client:
    def __init__(self, base_url, key, timeout=600, allow_host=None):
        self.scheme, self.host, self.port = parse_base(base_url, allow_host)
        self.key = key
        self.timeout = timeout
        R.add_secret(key)

    def _connect(self):
        cls = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        return cls(self.host, self.port, timeout=self.timeout)

    def close(self):
        """Nothing is kept open between requests: every request uses its own connection."""

    def count_tokens(self, body):
        """POST /v1/messages/count_tokens (documented as free). Returns input_tokens or raises ValueError."""
        conn = self._connect()
        try:
            conn.request("POST", "/v1/messages/count_tokens", body=json.dumps(body).encode(),
                         headers={"content-type": "application/json", "x-api-key": self.key, "anthropic-version": API_VERSION})
            resp = conn.getresponse()
            raw = resp.read().decode("utf-8", "replace")
            if resp.status != 200:
                r = Result()
                r.status, r.retry_after = resp.status, resp.getheader("retry-after")
                r.error_type, r.error = _parse_error(raw)
                f = r.fatal()
                if f:
                    raise FatalApiError(*f)
                raise ValueError("count_tokens returned %s: %s" % (resp.status, R.redact(raw[:300])))
            return int(json.loads(raw)["input_tokens"])
        except (OSError, http.client.HTTPException, KeyError, TypeError) as e:
            raise ValueError("count_tokens failed: %s" % R.redact("%s: %s" % (type(e).__name__, e)))
        finally:
            conn.close()

    def post(self, body, thread=False):
        res = Result()
        headers = {"content-type": "application/json", "accept": "text/event-stream", "x-api-key": self.key,
                   "anthropic-version": API_VERSION, "connection": "close"}
        if thread:
            headers["anthropic-beta"] = BETA
        data = json.dumps(body).encode()
        t0 = time.perf_counter()  # connection setup and the upload are inside TTFT, the same for every arm
        conn = self._connect()
        try:
            conn.request("POST", "/v1/messages", body=data, headers=headers)
            resp = conn.getresponse()
            res.status = resp.status
            if resp.status != 200:
                raw = resp.read().decode("utf-8", "replace")
                res.total = time.perf_counter() - t0
                res.retry_after = resp.getheader("retry-after")
                res.error_type, res.error = _parse_error(raw)
                res.error_code = _error_code(res.error)
                return res
            self._read_stream(resp, res, t0)
            res.total = time.perf_counter() - t0
        except Exception as e:  # network, timeout, protocol
            res.exception = R.redact("%s: %s" % (type(e).__name__, e))
        finally:
            conn.close()
            if res.total is None:
                res.total = time.perf_counter() - t0
        return res

    def _read_stream(self, resp, res, t0):
        ev = None
        while True:
            line = resp.readline()
            if not line:
                break
            line = line.decode("utf-8", "replace").rstrip("\r\n")
            if line.startswith("event:"):
                ev = line[6:].strip()
                continue
            if not line.startswith("data:"):
                continue
            try:
                d = json.loads(line[5:].strip())
            except ValueError:
                continue
            t = d.get("type", ev)
            if t == "message_start":
                m = d.get("message", {})
                res.response_id = m.get("id")
                res.usage.update({k: v for k, v in (m.get("usage") or {}).items() if isinstance(v, int)})
            elif t == "content_block_delta":
                delta = d.get("delta", {})
                if res.ttft is None:
                    res.ttft = time.perf_counter() - t0
                    res.first_kind = delta.get("type")
                if delta.get("type") == "text_delta":
                    res.text += delta.get("text", "")
            elif t == "message_delta":
                res.usage.update({k: v for k, v in (d.get("usage") or {}).items() if isinstance(v, int)})
                res.stop_reason = (d.get("delta") or {}).get("stop_reason", res.stop_reason)
            elif t == "message_stop":
                res.complete = True
                break
            elif t == "error":
                res.error = R.redact_obj(d)
                res.error_code = ((d.get("error") or {}).get("details") or {}).get("error_code")
                res.error_type = (d.get("error") or {}).get("type") if isinstance(d.get("error"), dict) else None
                break
        if not res.complete and not res.error:
            res.exception = "stream ended before message_stop"
