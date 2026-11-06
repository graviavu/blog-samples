"""Deterministic filler text built locally. It is synthetic prose about a made-up workshop; no real data."""
import random

WORDS = ("amber anchor basin bridge cable candle canvas copper cradle dagger delta ember engine fabric ferry flint forge garden "
         "gasket harbor hinge island jigsaw kettle ladder lantern ledger magnet marble meadow needle orchard paddle pebble "
         "pillar quartz rafter ribbon saddle shovel spindle tackle timber valley vessel walnut wicker window yarn zipper "
         "bolt brace chisel clamp dowel fuse gauge hammer lathe mallet nozzle pulley rivet spanner socket valve washer").split()

CHUNK_TOKENS = 4000      # size of one history message
QUESTION_TOKENS = 40


def sentence(rng):
    n = rng.randint(7, 14)
    w = [rng.choice(WORDS) for _ in range(n)]
    return (" ".join(w)).capitalize() + "."


def text(seed, n_chars):
    rng = random.Random(seed)
    out, size = [], 0
    while size < n_chars:
        s = sentence(rng)
        out.append(s)
        size += len(s) + 1
    return " ".join(out)[:n_chars]


def build_history(salt, target_tokens, chars_per_token):
    """Alternating user/assistant messages, starting with user and ending with assistant, about target_tokens long.
    The salt is the first line, so every arm and cell has a prefix no other request shares (no accidental cache hits)."""
    n = max(2, round(target_tokens / CHUNK_TOKENS))
    if n % 2:
        n += 1
    per = max(40, int(target_tokens * chars_per_token / n))
    msgs = []
    for i in range(n):
        body = text("%s/%d" % (salt, i), per)
        if i == 0:
            body = "Session %s. Workshop notes follow.\n%s" % (salt, body)
        msgs.append({"role": "user" if i % 2 == 0 else "assistant", "content": body})
    return msgs


def question(k):
    return "Question %d: in one short sentence, say what the notes above are about." % k
