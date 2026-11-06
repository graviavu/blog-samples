"""Local stub of POST /anthropic/v1/messages with SSE streaming, prompt-cache accounting and the thread parameter.
Written from DOCS-NOTES.md, not from the real service. Listens on 127.0.0.1 only."""
import hashlib
import http.server
import itertools
import json
import re
import threading
import time

BETA = "message-threads-2026-08-12"
FIXED = ("model", "output_config", "cache_control")


def tok(obj):
    return len(json.dumps(obj, sort_keys=True)) // 4


def err(status, etype, msg, code=None):
    d = {"type": etype, "message": msg}
    if code:
        d["details"] = {"error_code": code}
    return status, {"type": "error", "error": d, "request_id": "req_011CSHoEeqs5C35K2UUqR7Fy"}


class State:
    def __init__(self, token):
        self.token = token
        self.lock = threading.Lock()
        self.threads = {}
        self.cache = set()
        self.log = []              # (path, headers, body) of every request
        self.counter = itertools.count(1)
        self.thread_mode = "accept"    # accept | reject | ignore | err500 | no_id
        self.baseline_status = None    # force this HTTP status on plain (non-thread) requests
        self.effort_status = None      # refuse output_config with this status
        self.actions = []              # injection queue: "503", "truncate"
        self.base_delay = 0.0
        self.delay_per_token = 0.0
        self.usage_scale = 1
        self.scale_after = 0           # apply usage_scale only to requests after this many
        self.leak_token = False        # echo the token and an account id in error bodies
        self.think = False
        self.no_cache = False          # never report cache reads


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, status, obj, headers=None):
        raw = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()

    def fail(self, st, status, etype, msg, code=None):
        if st.leak_token:
            msg += " token=%s account 123456789012 arn:aws:iam::123456789012:role/x" % st.token
        s, obj = err(status, etype, msg, code)
        self.send_json(s, obj, {"x-amzn-requestid": "7f1c2d3e-0000-4000-8000-123456789abc", "x-amzn-errortype": etype})

    def do_POST(self):
        st = self.server.state
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        hdrs = {k.lower(): v for k, v in self.headers.items()}
        with st.lock:
            st.log.append((self.path, hdrs, body))
            action = st.actions.pop(0) if st.actions else None
        if self.path != "/anthropic/v1/messages":
            return self.fail(st, 404, "not_found_error", "no such route")
        presented = hdrs.get("x-api-key") or hdrs.get("authorization", "").replace("Bearer ", "")
        if presented != st.token:
            return self.fail(st, 401, "authentication_error", "bad token")
        if action == "503":
            return self.fail(st, 503, "overloaded_error", "injected")
        thread = body.get("thread")
        if not thread and st.baseline_status:
            return self.fail(st, st.baseline_status, "invalid_request_error", "baseline refused")
        if "output_config" in body and st.effort_status:
            return self.fail(st, st.effort_status, "invalid_request_error", "output_config not permitted")
        prep = self.prepare(st, body, hdrs, thread)
        if prep[0] != 200:
            return self.fail(st, *prep)
        try:
            self.stream(st, prep[1], action)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def prepare(self, st, body, hdrs, th):
        conv = {k: body.get(k) for k in FIXED}
        if th is None:
            conv["messages"] = list(body["messages"])
            return 200, {"conv": conv, "tid": None}
        if st.thread_mode == "reject":
            return 400, "invalid_request_error", "unknown parameter: thread", "unsupported_parameter"
        if st.thread_mode == "err500":
            return 500, "api_error", "internal"
        if BETA not in hdrs.get("anthropic-beta", ""):
            return 400, "invalid_request_error", "thread requires the beta header"
        if th.get("type") == "create":
            conv["messages"] = list(body["messages"])
            return 200, {"conv": conv, "tid": "new"}
        prev = th.get("previous_message_id")
        if st.thread_mode == "ignore":
            conv["messages"] = list(body["messages"])
            return 200, {"conv": conv, "tid": None}
        with st.lock:
            t = st.threads.get(prev)
            if t is None:
                return 404, "not_found_error", "thread not found", "thread_not_found"
            if t["continued"]:
                return 400, "invalid_request_error", "already continued", "thread_already_continued"
            if [k for k in FIXED if body.get(k) != t["conv"].get(k)]:
                return 400, "invalid_request_error", "fixed fields differ", "thread_fingerprint_mismatch"
            t["continued"] = True
            conv = dict(t["conv"])
            conv["messages"] = list(conv["messages"]) + list(body["messages"])
        return 200, {"conv": conv, "tid": "cont"}

    def usage_for(self, st, conv):
        msgs = conv["messages"]
        hashes, cum, total = [], [], 0
        for i, m in enumerate(msgs):
            total += tok(m)
            cum.append(total)
            hashes.append(hashlib.sha256(json.dumps(msgs[:i + 1], sort_keys=True).encode()).hexdigest())
        read = 0
        with st.lock:
            for h, c in zip(hashes, cum):
                if h in st.cache:
                    read = c
            if conv.get("cache_control"):
                st.cache.add(hashes[-1])
        if st.no_cache or not conv.get("cache_control"):
            read, create = 0, 0
        else:
            create = total - read
        s = st.usage_scale if len(st.log) > st.scale_after else 1
        return {"input_tokens": (total - read - create) * s, "cache_creation_input_tokens": create * s,
                "cache_read_input_tokens": read * s}, total - read

    def stream(self, st, prep, action):
        conv = prep["conv"]
        usage, uncached = self.usage_for(st, conv)
        mid = "msg_%024x" % next(st.counter)
        full = json.dumps(conv["messages"])
        m = re.findall(r"codeword: (PELICAN-\d+)", full)
        asked = "What is the codeword" in json.dumps(conv["messages"][-1])
        text = m[-1] if (m and asked) else "OK."
        time.sleep(st.base_delay + st.delay_per_token * uncached)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        w = self.wfile

        def ev(t, d):
            b = ("event: %s\ndata: %s\n\n" % (t, json.dumps(dict(d, type=t)))).encode()
            w.write(b"%x\r\n" % len(b) + b + b"\r\n")
            w.flush()
        ev("message_start", {"message": {"id": mid, "type": "message", "role": "assistant", "content": [], "model": conv["model"],
                                         "usage": dict(usage, output_tokens=1)}})
        ev("content_block_start", {"index": 0, "content_block": {"type": "text", "text": ""}})
        ev("ping", {})
        if st.think:
            ev("content_block_delta", {"index": 0, "delta": {"type": "thinking_delta", "thinking": "hm"}})
        ev("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": text[:3]}})
        if action == "truncate":
            self.close_connection = True
            return
        ev("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": text[3:]}})
        ev("content_block_stop", {"index": 0})
        ev("message_delta", {"delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 5 * st.usage_scale}})
        ev("message_stop", {})
        w.write(b"0\r\n\r\n")
        w.flush()
        if prep["tid"] in ("new", "cont") and st.thread_mode != "no_id":
            c2 = dict(conv)
            c2["messages"] = list(conv["messages"]) + [{"role": "assistant", "content": text}]
            with st.lock:
                st.threads[mid] = {"conv": c2, "continued": False}


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, token):
        super().__init__(("127.0.0.1", 0), Handler)
        self.state = State(token)

    @property
    def url(self):
        return "http://127.0.0.1:%d/anthropic" % self.server_address[1]

    def start(self):
        threading.Thread(target=self.serve_forever, daemon=True).start()
        return self

    def stop(self):
        self.shutdown()
        self.server_close()
