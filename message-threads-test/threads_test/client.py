"""Minimal Messages API client: http.client + hand-parsed SSE. The key goes in a header, never in argv or a file."""
import http.client
import json
import re
import socket
import threading
import time
import urllib.parse

from . import redact as R

API_VERSION = "2026-10-21"  # from the docs cURL example (DOCS-NOTES.md)
BETA = "message-threads-2026-08-12"
SEND_CHUNK = 16384   # bytes per send when the upload is measured or paced. The socket keeps the OS default send buffers: setting
                     # SO_SNDBUF would turn off send-buffer auto-tuning on macOS/BSD and cap throughput at about one buffer per round trip.


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
    if status in (200, 400, 403, 429) and _MONEY_WORDS.search(text or ""):   # 200: an error event inside an open stream
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
        self.cache_creation = {}  # usage.cache_creation split (ephemeral_5m_input_tokens, ephemeral_1h_input_tokens) when reported
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
        self.body_bytes = None   # size of the request body that was sent
        self.connect_s = None    # seconds from the start of the request until DNS, TCP and TLS setup was done (measure_upload only)
        self.body_sent_s = None  # seconds from the start of the request until the last body byte was handed to the kernel (measure_upload only)
        self.deadline_hit = False  # the per-request wall-clock deadline passed; the client ended the request (never resent)
        self.aborted = False     # the client closed the stream on purpose (abort_after_delta)

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
        return kind, "HTTP %s %s%s" % (self.status, R.redact(self.error_type or "no error type"), (": " + R.redact(msg)[:160]) if msg else "")

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
    def __init__(self, base_url, key, timeout=600, allow_host=None, deadline=None):
        """timeout bounds one socket operation (connect, one read). deadline (seconds, None = none) bounds a whole post() on the
        wall clock: when it passes, the client shuts the connection down and the Result says deadline_hit. Nothing is resent."""
        self.scheme, self.host, self.port = parse_base(base_url, allow_host)
        self.key = key
        self.timeout = timeout
        self.deadline = deadline
        R.add_secret(key)

    def _connect(self, timeout=None):
        cls = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        return cls(self.host, self.port, timeout=timeout or self.timeout)

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

    def _send_body(self, conn, data, rate_bps, t0, end=None):
        """Headers are already sent. Hands the body to the socket in chunks. rate_bps paces it on the client (a token bucket on
        wall-clock time) to imitate a slow uplink; None means as fast as the socket takes it. Nothing outside this process
        is changed: no firewall, no traffic shaper, nothing to restore. Returns seconds since t0 when the last byte was handed to the
        kernel (with the default send buffers, that can be before it left the machine)."""
        start = time.perf_counter()
        sent = 0
        for i in range(0, len(data), SEND_CHUNK):
            if end is not None and time.perf_counter() >= end:
                raise TimeoutError("request deadline passed during the upload")
            chunk = data[i:i + SEND_CHUNK]
            conn.send(chunk)
            sent += len(chunk)
            if rate_bps:
                wait = start + sent * 8.0 / rate_bps - time.perf_counter()
                if end is not None:
                    wait = min(wait, end - time.perf_counter())
                if wait > 0:
                    time.sleep(wait)
        return time.perf_counter() - t0

    @staticmethod
    def _watchdog(conn, res, seconds):
        """Ends the request when the wall-clock deadline passes: shuts the socket down so a blocked read returns at once."""
        def fire():
            res.deadline_hit = True
            sock = conn.sock
            if sock is not None:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        t = threading.Timer(max(0.0, seconds), fire)
        t.daemon = True
        return t

    def post(self, body, thread=False, measure_upload=False, rate_bps=None, abort_after_delta=False):
        """measure_upload (implied by rate_bps) connects first, then sends the body in chunks, and records body_bytes, connect_s and
        body_sent_s. The socket keeps the OS default send buffers, so body_sent_s is when the client handed the last byte to the
        kernel, not when the server received it. abort_after_delta closes the connection after the first content delta,
        before message_stop (a dropped stream). With all three off the request is the same bytes as before these options existed.
        A Client deadline ends the request on the wall clock (deadline_hit); it is never resent."""
        res = Result()
        headers = {"content-type": "application/json", "accept": "text/event-stream", "x-api-key": self.key,
                   "anthropic-version": API_VERSION, "connection": "close"}
        if thread:
            headers["anthropic-beta"] = BETA
        data = json.dumps(body).encode()
        res.body_bytes = len(data)
        t0 = time.perf_counter()  # connection setup and the upload are inside TTFT, the same for every arm
        end = t0 + self.deadline if self.deadline else None
        conn = self._connect(min(self.timeout, self.deadline) if self.deadline else None)
        dog = None
        try:
            if measure_upload or rate_bps:
                conn.connect()
                res.connect_s = time.perf_counter() - t0
                if end is not None:
                    dog = self._watchdog(conn, res, end - time.perf_counter())
                    dog.start()
                conn.putrequest("POST", "/v1/messages")
                for k, v in dict(headers, **{"content-length": str(len(data))}).items():
                    conn.putheader(k, v)
                conn.endheaders()
                res.body_sent_s = self._send_body(conn, data, rate_bps, t0, end)
            else:
                if end is not None:
                    conn.connect()
                    dog = self._watchdog(conn, res, end - time.perf_counter())
                    dog.start()
                conn.request("POST", "/v1/messages", body=data, headers=headers)
            sock = conn.sock
            resp = conn.getresponse()
            if dog is not None and conn.sock is None:
                conn.sock = sock   # http.client hands a "connection: close" socket to the response; keep it for the watchdog
            res.status = resp.status
            if resp.status != 200:
                raw = resp.read().decode("utf-8", "replace")
                res.total = time.perf_counter() - t0
                res.retry_after = resp.getheader("retry-after")
                res.error_type, res.error = _parse_error(raw)
                res.error_code = _error_code(res.error)
                return res
            self._read_stream(resp, res, t0, abort_after_delta)
            res.total = time.perf_counter() - t0
        except Exception as e:  # network, timeout, protocol
            res.exception = R.redact("%s: %s" % (type(e).__name__, e))
        finally:
            if dog is not None:
                dog.cancel()
            conn.close()
            if res.total is None:
                res.total = time.perf_counter() - t0
            # A request that finished (complete, cut on purpose, or an HTTP error answer) is kept even if the timer fired just after.
            if end is not None and not res.complete and not res.aborted and res.status in (None, 200) \
                    and (res.deadline_hit or time.perf_counter() >= end):
                res.deadline_hit = True
                res.exception = "request deadline of %gs passed; the client ended it and did not resend it" % self.deadline
            else:
                res.deadline_hit = False
        return res

    @staticmethod
    def _merge_cc(res, usage):
        cc = (usage or {}).get("cache_creation")
        if isinstance(cc, dict):
            res.cache_creation.update({k: v for k, v in cc.items() if isinstance(v, int)})

    def _read_stream(self, resp, res, t0, abort_after_delta=False):
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
                self._merge_cc(res, m.get("usage"))
            elif t == "content_block_delta":
                delta = d.get("delta", {})
                if res.ttft is None:
                    res.ttft = time.perf_counter() - t0
                    res.first_kind = delta.get("type")
                if delta.get("type") == "text_delta":
                    res.text += delta.get("text", "")
                if abort_after_delta:
                    res.aborted = True
                    return
            elif t == "message_delta":
                res.usage.update({k: v for k, v in (d.get("usage") or {}).items() if isinstance(v, int)})
                self._merge_cc(res, d.get("usage"))
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
