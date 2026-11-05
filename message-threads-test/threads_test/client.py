"""Minimal Messages API client: http.client + hand-parsed SSE. The key goes in a header, never in argv or a file."""
import http.client
import json
import time
import urllib.parse

from . import redact as R

API_VERSION = "2026-10-21"  # from the docs cURL example (DOCS-NOTES.md)
BETA = "message-threads-2026-08-12"


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
        self.exception = None    # network-level failure, redacted text
        self.response_id = None  # kept in memory only, never written out

    @property
    def transient(self):
        if self.exception:
            return True
        if self.status is not None and self.status == 200 and not self.complete:
            return True
        return self.status in (408, 409, 429, 500, 502, 503, 504, 529)

    @property
    def ok(self):
        return self.status == 200 and self.complete and not self.error


def is_loopback(host):
    return host in ("127.0.0.1", "localhost", "::1")


def parse_base(url):
    u = urllib.parse.urlparse(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("bad base URL")
    if u.scheme == "http" and not is_loopback(u.hostname):
        raise ValueError("refusing plain http to a non-loopback host: the key would travel unencrypted")
    return u.scheme, u.hostname, u.port or (443 if u.scheme == "https" else 80)


class Client:
    def __init__(self, base_url, key, timeout=600):
        self.scheme, self.host, self.port = parse_base(base_url)
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
                try:
                    obj = json.loads(raw)
                    err = obj.get("error", {}) if isinstance(obj, dict) else {}
                    res.error_code = (err.get("details") or {}).get("error_code")
                    res.error = R.redact_obj(obj)
                except ValueError:
                    res.error = R.redact(raw[:500])
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
                break
        if not res.complete and not res.error:
            res.exception = "stream ended before message_stop"
