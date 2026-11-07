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
        self.cache = set()
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


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"   # keep-alive, chunked streaming, like the real service

    def log_message(self, *a):
        pass

    def send_json(self, status, obj):
        raw = json.dumps(obj).encode()
        self.send_response(status)
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
            return self.send_json(200, {"input_tokens": tok({"s": body.get("system"), "t": body.get("tools"), "m": body.get("messages")}) * st.count_scale})
        if self.path != "/v1/messages":
            return self.send_json(*err(404, "not_found_error", "no such route"))
        if not hdrs.get("x-api-key"):
            return self.send_json(*err(401, "authentication_error", "missing key"))
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
            if t is None or (st.expire_after is not None and time.time() - t["t"] > st.expire_after):
                return err(404, "not_found_error", "thread not found", "thread_not_found")
            if t["continued"]:
                return err(400, "invalid_request_error", "already continued", "thread_already_continued")
            bad = [k for k in FIXED if body.get(k) != t["conv"].get(k)]
            if bad:
                return err(400, "invalid_request_error", "fixed fields differ: %s" % bad, "thread_fingerprint_mismatch")
            t["continued"] = True
            conv = dict(t["conv"])
            conv["messages"] = list(conv["messages"]) + list(body["messages"])
        return 200, {"conv": conv, "tid": "cont"}

    def usage_for(self, st, conv):
        sysd = {"system": conv["system"], "tools": conv["tools"]}
        msgs = conv["messages"]
        hashes, cum, total = [], [], tok(sysd)
        for i, m in enumerate(msgs):
            total += tok(m)
            cum.append(total)
            hashes.append(hashlib.sha256(json.dumps([sysd, msgs[:i + 1]], sort_keys=True).encode()).hexdigest())
        read = 0
        with st.lock:
            for h, c in zip(hashes, cum):
                if h in st.cache:
                    read = c
            if conv.get("cache_control"):
                st.cache.add(hashes[-1])
        create = (total - read) if conv.get("cache_control") else 0
        s = st.usage_scale
        return {"input_tokens": (total - read - create) * s, "cache_creation_input_tokens": create * s,
                "cache_read_input_tokens": read * s}, total - read

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
                st.threads[mid] = {"conv": c2, "continued": False, "t": time.time()}


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
