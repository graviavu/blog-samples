"""Fake decision server (loopback, no model, no network beyond 127.0.0.1). Speaks both shapes the adapter knows.
Deterministic keyword scoring. Counts requests so tests can prove a dry run made none.
Failure injection: state containing 'FAIL500' -> HTTP 500; 'BADSHAPE' -> body without a choice;
'BADPROBS' -> probabilities that do not sum to 1."""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

KEYS = {"urgent": ["urgent", "suspend", "incident", "alert", "disk", "charge", "today", "5pm", "security", "payment"],
        "ignore": ["sale", "unsubscribe", "cart", "survey", "notifications", "winner", "prize", "promo"],
        "opus": ["architecture", "security", "review", "payments"], "haiku": ["summary", "digest", "rename", "format", "boilerplate"]}
COUNT = {"n": 0}


def answer(state, instructions, opts):
    s = state.lower()
    sc = {o: 1.0 + sum(k in s for k in KEYS.get(o, [])) for o in opts}
    if "least suitable" in instructions.lower():
        sc = {o: 1.0 / v for o, v in sc.items()}
    z = sum(sc.values())
    p = {o: sc[o] / z for o in opts}
    best = max(opts, key=lambda o: (p[o], -list(opts).index(o)))
    k = len(opts)
    return {"choice": best, "probabilities": p, "confidence": (p[best] - 1 / k) / (1 - 1 / k)}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        COUNT["n"] += 1
        req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
        if self.path == "/v1/systemone":
            q = req["questions"]["q"]
            state, instr, opts, wrap = str(req["state"]), q["instructions"], q["criteria"], True
        else:
            state, instr, opts, wrap = str(req["state"]), req["instructions"], req["options"], False
        code, out = 200, answer(state, instr, opts)
        if "FAIL500" in state:
            code, out = 500, {"error": "boom"}
        elif "BADSHAPE" in state:
            out = {"nothing": 1}
        elif "BADPROBS" in state:
            out["probabilities"] = {o: 0.9 for o in opts}
        body = {"model": "fake", "answers": {"q": out}} if wrap and code == 200 and "choice" in out else out
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b)


def start():
    COUNT["n"] = 0
    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_port}"
