"""Minimal Messages API client: http.client + hand-parsed SSE. The token goes in a header, never in argv or a file."""
import http.client
import json
import time
import urllib.parse

from . import redact as R

THREADS_BETA = "message-threads-2026-08-12"
TRANSIENT = (408, 429, 500, 502, 503, 504, 529)
# Server errors that can arrive after the model has run (a gateway giving up on a long request): billing unknown, so charged.
MAYBE_BILLED = (500, 502, 504)
ALLOWED_HOST_SUFFIX = ".api.aws"


def is_loopback(host):
    return host in ("127.0.0.1", "localhost", "::1")


def parse_endpoint(url):
    u = urllib.parse.urlparse(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("bad endpoint URL")
    if u.scheme == "http" and not is_loopback(u.hostname):
        raise ValueError("refusing plain http to a non-loopback host: the token would travel unencrypted")
    if u.query or u.fragment or u.username or u.password:
        raise ValueError("endpoint must be scheme://host[:port][/prefix] only")
    return u.scheme, u.hostname, u.port or (443 if u.scheme == "https" else 80), u.path.rstrip("/")


def check_host(host, allow=None):
    """The key only goes to an AWS API host (*.api.aws), to loopback (the stub), or to the one host named with --allow-endpoint-host."""
    h = (host or "").lower().rstrip(".")
    if is_loopback(h) or (h.endswith(ALLOWED_HOST_SUFFIX) and len(h) > len(ALLOWED_HOST_SUFFIX)):
        return
    if allow and h == allow.lower().rstrip("."):
        return
    raise ValueError("refusing to send the key to %s: the host does not end in %s. If you mean it, add --allow-endpoint-host %s"
                     % (h, ALLOWED_HOST_SUFFIX, h))


def describe_error(status, raw, headers=None):
    """Sanitized, id-free description of an error response. Codes and types are kept verbatim."""
    d = {"http_status": status, "error_type": None, "error_code": None, "amzn_error_type": None, "message": None}
    if headers:
        h = {k.lower(): v for k, v in headers.items()}
        if h.get("x-amzn-errortype"):
            d["amzn_error_type"] = R.redact(h["x-amzn-errortype"])[:120]
    try:
        obj = json.loads(raw)
    except ValueError:
        d["message"] = R.redact(raw[:300])
        return d
    if isinstance(obj, dict):
        err = obj.get("error") if isinstance(obj.get("error"), dict) else obj
        et = err.get("type") if err.get("type") != "error" else None
        d["error_type"] = R.redact(et or obj.get("__type") or "")[:120] or None
        details = err.get("details") if isinstance(err.get("details"), dict) else {}
        code = details.get("error_code") or err.get("code") or obj.get("code")
        d["error_code"] = R.redact(code)[:120] if isinstance(code, str) else None
        msg = err.get("message") or obj.get("message")
        d["message"] = R.redact(msg)[:300] if isinstance(msg, str) else None
    return d


class Result:
    def __init__(self):
        self.status = None
        self.ttft = None
        self.total = None
        self.usage = {}
        self.text = ""
        self.first_kind = None
        self.complete = False
        self.error = None         # describe_error dict (HTTP error or in-stream error event)
        self.exception = None     # network-level failure, redacted text
        self.response_id = None   # kept in memory only, never written out
        self.stream_started = False
        self.sent = True          # may it have been billed? Assumed yes; post() sets False only while connecting (nothing sent yet)

    @property
    def ok(self):
        return self.status == 200 and self.complete and not self.error

    @property
    def transient(self):
        """Clear transient failures only: a network error before the body was sent (DNS failure, connection refused, TLS setup),
        or a complete overload-type HTTP response. A read timeout or a reset after the upload is never retried: the model may have run."""
        if self.exception:
            return self.status is None and not self.sent
        return self.status in TRANSIENT and not self.stream_started


class Client:
    def __init__(self, endpoint, token, auth_header="x-api-key", version="", timeout=600):
        self.scheme, self.host, self.port, self.prefix = parse_endpoint(endpoint)
        self.token = token
        self.auth_header = auth_header
        self.version = version
        self.timeout = timeout
        R.add_secret(token)

    def _conn(self):
        cls = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        return cls(self.host, self.port, timeout=self.timeout)

    def post(self, body, beta=None):
        res = Result()
        headers = {"content-type": "application/json", "accept": "text/event-stream", "connection": "close"}
        if self.auth_header == "bearer":
            headers["authorization"] = "Bearer " + self.token
        else:
            headers["x-api-key"] = self.token
        if self.version:
            headers["anthropic-version"] = self.version
        if beta:
            headers["anthropic-beta"] = beta
        body = dict(body, stream=True)
        data = json.dumps(body).encode()
        t0 = time.perf_counter()  # connection setup and upload are inside TTFT, the same for every arm
        conn = self._conn()
        try:
            res.sent = False
            conn.connect()            # DNS, TCP and TLS: a failure here means no byte of the request was sent
            res.sent = True           # from here on, any failure may come after the model ran
            conn.request("POST", self.prefix + "/v1/messages", body=data, headers=headers)
            resp = conn.getresponse()
            res.status = resp.status
            if resp.status != 200:
                raw = resp.read().decode("utf-8", "replace")
                res.total = time.perf_counter() - t0
                res.error = describe_error(resp.status, raw, dict(resp.getheaders()))
                return res
            res.stream_started = True
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
            elif t == "message_stop":
                res.complete = True
                break
            elif t == "error":
                res.error = describe_error(200, json.dumps(d))
                break
        if not res.complete and not res.error:
            res.exception = "stream ended before message_stop"
