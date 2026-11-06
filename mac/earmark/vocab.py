"""Custom vocabulary: names and terms the wearer uses, spelled the way they want.

One entry per line in Settings:
    RAKBANK                         a term: fixes its case ("rakbank") and split spellings ("rak bank")
    rack bank, rag bank = RAKBANK   what the speech model writes instead, and the right spelling

The transcript is corrected word by word (timings kept), and the terms are given to the notes model so
names are spelled right in titles, notes and tasks. Same rules as the iPhone (lib/notes/vocab.dart).
"""
from __future__ import annotations

import re

_PUNCT = ".,!?;:\"'”“’)("


def parse(text: str) -> list[tuple[list[list[str]], str]]:
    """[(variants as word lists (lower case, no punctuation), right spelling)]"""
    out = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            left, right = line.split("=", 1)
            heard = [h.strip() for h in left.split(",") if h.strip()]
        else:
            right, heard = line, []
        right = right.strip()
        if not right:
            continue
        variants = [_norm_words(h) for h in heard + [right]]
        out.append(([v for v in variants if v], right))
    return out


def terms(text: str) -> list[str]:
    seen, out = set(), []
    for _, right in parse(text):
        if right.lower() not in seen:
            seen.add(right.lower())
            out.append(right)
    return out


def _norm(w: str) -> str:
    return w.strip(_PUNCT).lower()


def _norm_words(s: str) -> list[str]:
    return [x for x in (_norm(w) for w in s.split()) if x]


def _letters(ws: list[str]) -> str:
    return re.sub(r"[^a-z0-9]", "", "".join(ws))


def fix_tokens(tokens: list[str], entries) -> tuple[list[str], list[tuple[int, int]]]:
    """Corrected tokens and, for each, the span of original tokens it replaces."""
    out, spans, i = [], [], 0
    n = len(tokens)
    norm = [_norm(t) for t in tokens]
    while i < n:
        hit = None
        for variants, right in entries:
            want = _letters(_norm_words(right))
            for k in (3, 2, 1):                       # longest match first
                if i + k > n:
                    continue
                span = norm[i:i + k]
                if any(span == v for v in variants) or (want and len(want) >= 4 and _letters(span) == want):
                    hit = (k, right)
                    break
            if hit:
                break
        if hit:
            k, right = hit
            last = tokens[i + k - 1]
            trail = last[len(last.rstrip(_PUNCT)):] if last.rstrip(_PUNCT) != last else ""
            lead = tokens[i][: len(tokens[i]) - len(tokens[i].lstrip(_PUNCT))]
            out.append(lead + right + trail)
            spans.append((i, i + k))
            i += k
        else:
            out.append(tokens[i])
            spans.append((i, i + 1))
            i += 1
    return out, spans


def fix_segments(segments: list, text: str) -> list:
    """The segments with the vocabulary applied to their text and words."""
    entries = parse(text)
    if not entries:
        return segments
    for g in segments:
        words = g.get("words") or []
        if words:
            toks, spans = fix_tokens([str(w[2]) for w in words], entries)
            g["words"] = [[words[a][0], words[b - 1][1], t] for t, (a, b) in zip(toks, spans)]
            g["text"] = " ".join(toks)
        elif g.get("text"):
            g["text"] = " ".join(fix_tokens(g["text"].split(), entries)[0])
    return segments


def prompt_line(text: str) -> str:
    t = terms(text)
    return ("Names and terms the wearer uses (spell them exactly like this): " + ", ".join(t) + ".") if t else ""
