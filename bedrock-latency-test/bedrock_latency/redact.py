"""Redaction for every line the script prints or stores. The token itself is added at start-up."""
import re

_SECRETS = []
_PATTERNS = [
    (re.compile(r"ABSK[A-Za-z0-9+/=_\-]{8,}"), "<key>"),
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]{6,}"), "<key>"),
    (re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{12,}\b"), "<key>"),
    (re.compile(r"(?i)(bearer|x-api-key:?|authorization:?)\s+[^\s\"',}]+"), r"\1 <redacted>"),
    (re.compile(r"arn:aws[a-z\-]*:[^\s\"',}]+"), "<arn>"),
    (re.compile(r"\b(msg|req|org|ws|workspace|acct|account|usr|user|toolu|apikey)_(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{6,}"), "<id>"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    (re.compile(r"(?<![0-9.])\d{12}(?![0-9])"), "<acct>"),
]


def add_secret(s):
    if s and len(s) >= 6 and s not in _SECRETS:
        _SECRETS.append(s)


def redact(text):
    text = str(text)
    for s in _SECRETS:
        text = text.replace(s, "<key>")
    for rx, rep in _PATTERNS:
        text = rx.sub(rep, text)
    return text


_DROP = ("request_id", "requestid", "x-amzn-requestid")


def redact_obj(o):
    if isinstance(o, str):
        return redact(o)
    if isinstance(o, dict):
        return {k: redact_obj(v) for k, v in o.items() if str(k).lower() not in _DROP}
    if isinstance(o, list):
        return [redact_obj(v) for v in o]
    return o
