"""Local stub of POST /v1/messages with streaming, prompt cache accounting and the thread parameter.
Written from DOCS-NOTES.md, not from the real service. Listens on 127.0.0.1 only."""
import hashlib
import http.server
import itertools
import json
import re
import threading
import time

BETA = "message-threads-2026-08-12"
FIXED = ("model", "tool_choice", "output_config", "cache_control", "thinking")


def tok(obj):
    return len(json.dumps(obj, sort_keys=True)) // 4


def err(status, etype, msg, code=None):
    d = {"type": etype, "message": msg}
    if code:
        d["details"] = {"error_code": code}
    return status, {"type": "error", "error": d, "request_id": "req_011CSHoEeqs5C35K2UUqR7Fy"}


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.threads = {}       # id -> {"conv": {...}, "continued": bool, "t": time}
        self.clock = time.time  # tests can swap in a fake clock
        self.cache = set()
        self.cache_info = {}    # hash -> [last_used, "5m"|"1h"]
        self.cache_ttl5 = None  # seconds a 5m entry survives without use (None: forever)
        self.cache_ttl1h = None
        self.ignore_1h = False  # treat ttl "1h" as "5m" (a service that does not honour it)
        self.no_refresh = False # a continue does not restart the thread's idle timer
        self.log = []           # (path, headers dict, body dict) of every request
        self.counter = itertools.count(1)
        self.actions = []       # failure injection queue: "500", "truncate"
        self.delay_per_token = 0.0   # seconds of "prefill" per uncached token
        self.base_delay = 0.0
        self.count_scale = 1
        self.usage_scale = 1         # inflate reported tokens to blow past the estimate
        self.think = False           # emit a thinking_delta first
        self.expire_after = None     # seconds; threads older than this 404
        self.ignore_thread_context = False  # a continue that answers from the new message alone
        self.reject_threads = False  # 400 on any request that carries thread (an account without the beta)
        self.reject_effort = False   # 400 on output_config.effort
        self.event = threading.Event()
        self.error_after = None      # after this many /v1/messages requests, every one fails with error_shape (credit, billing, auth ...)
        self.error_shape = None      # (status, error type, message, extra headers dict)
        self.msg_requests = 0
        self.count_error = None      # same shape, for /v1/messages/count_tokens


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"   # keep-alive, chunked streaming, like the real service

    def log_message(self, *a):
        pass

    def send_json(self, status, obj, headers=None):
        raw = json.dumps(obj).encode()
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()

    def do_POST(self):
        st = self.server.state
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        hdrs = {k.lower(): v for k, v in self.headers.items()}
        with st.lock:
            st.log.append((self.path, hdrs, body))
            idx = next(st.counter)
            action = st.actions.pop(0) if st.actions else None
        st.event.set()
        if self.path == "/v1/messages/count_tokens":
            st.count_calls = getattr(st, "count_calls", 0) + 1
            if st.count_error:
                status, etype, msg, hdrs = st.count_error
                return self.send_json(*err(status, etype, msg), headers=hdrs)
            return self.send_json(200, {"input_tokens": tok({"s": body.get("system"), "t": body.get("tools"), "m": body.get("messages")}) * st.count_scale})
        if self.path != "/v1/messages":
            return self.send_json(*err(404, "not_found_error", "no such route"))
        if not hdrs.get("x-api-key"):
            return self.send_json(*err(401, "authentication_error", "missing key"))
        with st.lock:
            st.msg_requests += 1
            n_msg = st.msg_requests
        if st.error_after is not None and n_msg > st.error_after:
            status, etype, msg, hdrs = st.error_shape
            return self.send_json(*err(status, etype, msg), headers=hdrs)
        if action == "401":
            return self.send_json(*err(401, "authentication_error", "invalid x-api-key"))
        if st.reject_threads and "thread" in body:
            return self.send_json(*err(400, "invalid_request_error", "thread: Extra inputs are not permitted"))
        if st.reject_effort and "output_config" in body:
            return self.send_json(*err(400, "invalid_request_error", "output_config.effort: not supported"))
        if action == "500":
            return self.send_json(*err(500, "api_error", "injected failure"))
        status, obj = self.prepare(st, body, hdrs)
        if status != 200:
            return self.send_json(status, obj)
        try:
            self.stream(st, obj, action)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the client went away (Ctrl-C test)

    def prepare(self, st, body, hdrs):
        th = body.get("thread")
        cc = body.get("cache_control")
        if cc is not None and cc.get("ttl", "5m") not in ("5m", "1h"):
            return err(400, "invalid_request_error", "cache_control.ttl must be 5m or 1h")
        if th and BETA not in hdrs.get("anthropic-beta", ""):
            return err(400, "invalid_request_error", "thread requires the beta header")
        if th is None:
            conv = {k: body.get(k) for k in FIXED}
            conv.update(system=body.get("system"), tools=body.get("tools"), messages=list(body["messages"]))
            return 200, {"conv": conv, "tid": None}
        if th.get("type") == "create":
            conv = {k: body.get(k) for k in FIXED}
            conv.update(system=body.get("system"), tools=body.get("tools"), messages=list(body["messages"]))
            return 200, {"conv": conv, "tid": "new"}
        if "system" in body or "tools" in body:
            return err(400, "invalid_request_error", "continue must not carry system or tools")
        prev = th.get("previous_message_id")
        if not prev:
            return err(400, "invalid_request_error", "continue needs previous_message_id")
        with st.lock:
            t = st.threads.get(prev)
            if t is None or (st.expire_after is not None and st.clock() - t["t"] > st.expire_after):
                return err(404, "not_found_error", "thread not found", "thread_not_found")
            if t["continued"]:
                return err(400, "invalid_request_error", "already continued", "thread_already_continued")
            bad = [k for k in FIXED if body.get(k) != t["conv"].get(k)]
            if bad:
                return err(400, "invalid_request_error", "fixed fields differ: %s" % bad, "thread_fingerprint_mismatch")
            t["continued"] = True
            conv = dict(t["conv"])
            conv["messages"] = list(conv["messages"]) + list(body["messages"])
            t_parent = t.get("t0", t["t"])
        return 200, {"conv": conv, "tid": "cont", "t_parent": t_parent}

    def usage_for(self, st, conv):
        sysd = {"system": conv["system"], "tools": conv["tools"]}
        msgs = conv["messages"]
        hashes, cum, total = [], [], tok(sysd)
        for i, m in enumerate(msgs):
            total += tok(m)
            cum.append(total)
            hashes.append(hashlib.sha256(json.dumps([sysd, msgs[:i + 1]], sort_keys=True).encode()).hexdigest())
        read, now = 0, st.clock()
        ttl = (conv.get("cache_control") or {}).get("ttl", "5m")
        kind = "1h" if (ttl == "1h" and not st.ignore_1h) else "5m"
        with st.lock:
            hit = None
            for h, c in zip(hashes, cum):
                if h in st.cache and self._alive(st, h, now):
                    read, hit = c, h
            if hit is not None and hit in st.cache_info:
                st.cache_info[hit][0] = now   # a read restarts the lifetime
            if conv.get("cache_control"):
                st.cache.add(hashes[-1])
                st.cache_info[hashes[-1]] = [now, kind]
        create = (total - read) if conv.get("cache_control") else 0
        s = st.usage_scale
        u = {"input_tokens": (total - read - create) * s, "cache_creation_input_tokens": create * s,
             "cache_read_input_tokens": read * s}
        if conv.get("cache_control"):
            u["cache_creation"] = {"ephemeral_5m_input_tokens": create * s if kind == "5m" else 0,
                                   "ephemeral_1h_input_tokens": create * s if kind == "1h" else 0}
        return u, total - read

    @staticmethod
    def _alive(st, h, now):
        info = st.cache_info.get(h)
        if info is None:
            return True
        ttl = st.cache_ttl1h if info[1] == "1h" else st.cache_ttl5
        return ttl is None or now - info[0] <= ttl

    def stream(self, st, prep, action):
        conv = prep["conv"]
        usage, uncached = self.usage_for(st, conv)
        mid = "msg_%024x" % next(st.counter)
        text = "Reply to %s" % json.dumps(conv["messages"][-1])[-30:].replace('"', "").replace("\\", "")
        if "codeword?" in json.dumps(conv["messages"][-1]):   # answer from the stored conversation, as a real thread would
            m = re.search(r"PELICAN-\d+", json.dumps(conv["messages"][:-1]))
            text = m.group(0) if m and not st.ignore_thread_context else "I do not know"
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
        if action in ("stream_billing", "stream_credit_words"):   # an error event inside a 200 stream
            ev("error", {"error": {"type": "billing_error" if action == "stream_billing" else "api_error", "message": "credit balance is too low"}})
            w.write(b"0\r\n\r\n")
            w.flush()
            return
        ev("content_block_start", {"index": 0, "content_block": {"type": "text", "text": ""}})
        ev("ping", {})
        if st.think:
            ev("content_block_delta", {"index": 0, "delta": {"type": "thinking_delta", "thinking": "hm"}})
        ev("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": text[:10]}})
        if action == "truncate":
            self.close_connection = True
            return  # connection closes with no message_stop and no final chunk
        ev("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": text[10:]}})
        ev("content_block_stop", {"index": 0})
        ev("message_delta", {"delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 12 * st.usage_scale}})
        ev("message_stop", {})
        w.write(b"0\r\n\r\n")
        w.flush()
        if prep["tid"] in ("new", "cont"):
            c2 = dict(conv)
            c2["messages"] = list(conv["messages"]) + [{"role": "assistant", "content": [{"type": "text", "text": text}]}]
            with st.lock:
                now = st.clock()
                t0 = prep.get("t_parent") if st.no_refresh and prep.get("t_parent") else now
                st.threads[mid] = {"conv": c2, "continued": False, "t": t0 if st.no_refresh else now, "t0": t0}


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.state = State()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server_address[1]

    def start(self):
        threading.Thread(target=self.serve_forever, daemon=True).start()
        return self

    def stop(self):
        self.shutdown()
        self.server_close()
