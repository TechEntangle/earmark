"""Understanding conversations: notes, tasks, task follow-up, day summaries.

Providers (Settings > Intelligence):
  local      a language model running on this Mac with MLX (default: Qwen3.5 4B). Nothing leaves the Mac.
  ollama     a model served by Ollama on this Mac.
  openai     OpenAI API (needs a key). Transcript text is sent to OpenAI.
  anthropic  Anthropic API (needs a key). Transcript text is sent to Anthropic.
  fake       deterministic stand-in for tests (EARMARK_FAKE_LLM=1).

Every call asks for JSON and is parsed defensively; long transcripts are processed in parts
and merged, so a three-hour meeting works on a small local model.
"""
from __future__ import annotations

import json
import os
import re
import threading
import time
import urllib.request
from datetime import date, datetime, timedelta
from typing import Callable, Optional

LOCAL_MODELS = {
    "mlx-community/Qwen3.5-4B-MLX-4bit": "Qwen3.5 4B: fast, 3 GB (recommended)",
    "mlx-community/Qwen3.5-9B-MLX-4bit": "Qwen3.5 9B: smarter, 6 GB, needs 16 GB memory",
}
DEFAULT_LOCAL = "mlx-community/Qwen3.5-4B-MLX-4bit"
CHUNK_CHARS = 9000            # ~12 min of speech per part for long meetings

_lock = threading.Lock()       # one generation at a time
_local: dict = {}


# ---------------------------------------------------------------- providers
class LLMError(RuntimeError):
    pass


def _local_available() -> bool:
    try:
        import mlx_lm  # noqa: F401
        return True
    except Exception:
        return False


def ensure_local_runtime():
    if _local_available():
        return
    import importlib, subprocess, sys
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "mlx-lm"], check=True)
    importlib.invalidate_caches()


def _gen_local(model_id: str, system: str, user: str, max_tokens: int) -> str:
    ensure_local_runtime()
    from mlx_lm import generate, load
    from mlx_lm.sample_utils import make_sampler
    from .pipeline import limit_mlx_cache
    limit_mlx_cache()
    if model_id not in _local:
        _local.clear()
        _local[model_id] = load(model_id)
    model, tok = _local[model_id]
    msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
    try:
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
    except TypeError:
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)
    return generate(model, tok, prompt=prompt, max_tokens=max_tokens, sampler=make_sampler(temp=0.1), verbose=False)


def unload_local():
    _local.clear()
    from .pipeline import free_memory
    free_memory()


def _post(url: str, body: dict, headers: dict, timeout: int = 300) -> dict:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", **headers})
    try:
        ctx = None
        if url.startswith("https:"):
            from .speakers import _ssl_context
            ctx = _ssl_context()
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="ignore")[:300]
        raise LLMError(f"{e.code} from {url.split('/')[2]}: {detail}")
    except urllib.error.URLError as e:
        raise LLMError(f"could not reach {url.split('/')[2]}: {e.reason}")


def generate_text(cfg: dict, system: str, user: str, max_tokens: int = 1200) -> str:
    p = cfg.get("intel_provider", "local")
    if os.environ.get("EARMARK_FAKE_LLM") == "1":
        p = "fake"
    with _lock:
        if p == "local":
            return _gen_local(cfg.get("local_model") or DEFAULT_LOCAL, system, user, max_tokens)
        if p == "ollama":
            r = _post(f"{cfg['ollama_host']}/api/chat", {
                "model": cfg["ollama_model"], "stream": False, "format": "json",
                "options": {"temperature": 0.1, "num_ctx": 32768},
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}, {})
            return r["message"]["content"]
        if p == "openai":
            if not cfg.get("openai_key"):
                raise LLMError("add an OpenAI API key in Settings")
            r = _post("https://api.openai.com/v1/chat/completions", {
                "model": cfg.get("openai_model") or "gpt-4.1-mini", "temperature": 0.1,
                "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]},
                {"Authorization": f"Bearer {cfg['openai_key']}"})
            return r["choices"][0]["message"]["content"]
        if p == "anthropic":
            if not cfg.get("anthropic_key"):
                raise LLMError("add an Anthropic API key in Settings")
            r = _post("https://api.anthropic.com/v1/messages", {
                "model": cfg.get("anthropic_model") or "claude-haiku-5-5", "max_tokens": max_tokens,
                "temperature": 0.1, "system": system,
                "messages": [{"role": "user", "content": user}]},
                {"x-api-key": cfg["anthropic_key"], "anthropic-version": "2023-06-01"})
            return "".join(b.get("text", "") for b in r.get("content", []))
        if p == "fake":
            return _fake(system, user)
        raise LLMError("intelligence is turned off")


def parse_json(text: str):
    """Best-effort JSON from model output: strips fences, prose and trailing commas."""
    t = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
    t = re.sub(r"^```(?:json)?|```$", "", t, flags=re.M).strip()
    start = min([i for i in (t.find("{"), t.find("[")) if i >= 0], default=-1)
    if start < 0:
        raise ValueError("no JSON in model output")
    end = max(t.rfind("}"), t.rfind("]"))
    t = t[start:end + 1]
    for attempt in (t, re.sub(r",\s*([}\]])", r"\1", t)):
        try:
            return json.loads(attempt)
        except json.JSONDecodeError:
            continue
    raise ValueError("model returned malformed JSON")


def ask_json(cfg: dict, system: str, user: str, max_tokens: int = 1500):
    out = generate_text(cfg, system, user, max_tokens)
    try:
        return parse_json(out)
    except ValueError:
        out = generate_text(cfg, system + "\nReturn ONLY one valid JSON object. No prose, no code fences.", user, max_tokens)
        return parse_json(out)


# ---------------------------------------------------------------- prompts
def _today_line(when: datetime) -> str:
    return f"The recording started {when.strftime('%A %d %B %Y at %H:%M')}."


NOTES_SYSTEM = """You turn transcripts from a wearable voice recorder into precise notes.
The person wearing the recorder is "me". Lines are [mm:ss] timestamps followed by speech. When a line starts with "Name:", that person said it
("me:" is the wearer); trust those labels. Otherwise work out who is speaking from the back-and-forth
(a reply to a request is usually the person asked).

Return JSON:
{
 "title": "specific title, max 8 words, no date",
 "kind": "meeting | call | conversation | note_to_self | ambient",
 "summary": "2-4 sentences: what it was about and what came out of it",
 "key_points": ["..."],
 "decisions": ["decisions actually agreed"],
 "tasks": [{"task": "specific, self-contained action starting with a verb, naming what it is about",
            "owner": "me | a person's first name | unknown",
            "due_text": "the deadline exactly as said, e.g. 'by Thursday', 'tomorrow morning', or null",
            "done": false,
            "quote": "short verbatim words from the transcript that support this task",
            "t": "mm:ss where it was said"}],
 "people": ["first names mentioned or present"],
 "topics": ["2-5 short topic tags"]
}
Rules:
- Lines starting with ◆ contain commitment or completion language. Check EVERY ◆ line: most produce a task
  (including the wearer's own "I'll ..." commitments) or report one as finished.
- Only real commitments or requests: someone agrees to do something, is asked to, or says they will. Not ideas or wishes.
- Inside task text, refer to the wearer as "me" (e.g. "Send the loss numbers to me"), never "the wearer".
- When a line addresses someone by name ("Priya, ..."), the next reply is usually that person.
- Write each task so it makes sense on its own a week later, e.g. "Push the device-cluster block rule into ThreatMetrix",
  not "Push the rule".
- If something was reported as already finished in this conversation, include it with "done": true.
- owner is "me" when the speaker commits and you cannot tell they are someone else, or when the wearer is clearly the one asked.
- For deadlines, copy the words that were said into due_text; do not calculate dates.
- Lines starting with ★ are moments the wearer EARMARKED by tapping the recorder: treat them as important.
  Always cover them in key_points. If the wearer says something like "remind me to ..." or "note to self ..."
  around a ★, make it a task owned by "me".
- Never invent tasks, names or dates. Empty lists are fine. kind "ambient" means background talk with nothing to act on."""

PART_SYSTEM = """You read one part of a long transcript from a wearable voice recorder and extract notes for this part only.
The wearer is "me". Lines starting with ★ were earmarked as important by the wearer; always cover them, and turn
"remind me to ..." near a ★ into a task for "me". Return JSON with keys: "summary" (2-3 sentences), "key_points", "decisions",
"tasks" (same task format as below), "people", "topics".
Task format: {"task","owner","due_text","done","quote","t"}, owner "me"/first name/"unknown", due_text = deadline words as said.
Lines starting with ◆ contain commitment or completion language: check every one.
Only real commitments or requests; self-contained task wording. Never invent."""

MERGE_SYSTEM = """You merge notes from consecutive parts of ONE long recording into final notes.
Return the same JSON as for a single conversation: title, kind, summary (3-6 sentences for the whole recording),
key_points, decisions, tasks, people, topics. Merge duplicate tasks (keep the most specific wording, latest deadline,
earliest quote). If a later part says a task was finished, set "done": true. Never invent."""

LINES_SYSTEM = """You check lines from a transcript of a wearable voice recorder for tasks. The wearer is "me".
Each item gives one LINE plus the line BEFORE and AFTER it. A "Name:" prefix says who spoke ("me:" is the wearer);
trust it. Without one, when the BEFORE line addresses someone by name ("Priya, can you ...", "Imran, where are we?"), the LINE is usually that person replying.
For every item return what the LINE contains:
  "task": someone commits to or is asked to do something (including the wearer's own "I'll ..." or "remind me to ...")
  "done": someone reports that a piece of work is already finished
  "none": anything else
Return JSON: {"items": [{"n": <item number>, "kind": "task|done|none",
  "task": "specific self-contained action starting with a verb (for done: the work that was finished)",
  "owner": "me | first name | unknown", "due_text": "deadline words as said, or null"}]}
Write "me" (not "the wearer") inside task text when it refers to the wearer. Never invent."""

COMMAND_SYSTEM = """The wearer of a voice recorder just spoke to their notes app, asking it to save a to-do or reminder.
Turn what they asked for into to-do items. Return JSON:
{"tasks": [{"task": "specific action starting with a verb, written for the wearer (use 'my', not 'your')",
            "due_text": "deadline words as said, or null"}]}
One item per separate thing to do. Leave out the request itself ("add a task", "create a reminder"). Never invent."""

# Spoken instructions to Earmark itself: "remind me to ...", "add a task ...", "create a reminder for ...".
_COMMAND = re.compile(r"\b(remind me|set (a|me a) reminder|create (a |an )?(task|reminder|to-?do)|make (a |an )?(task|reminder|to-?do|note)|"
                      r"add (a |an |this |it |that )?(task|reminder|to-?do|note)?\s*(to|in|on)?\s*(my|our|the)?\s*(tasks?|to-?dos?|list|reminders?)|"
                      r"add (a |an )?(task|reminder|to-?do)|note to self|put (it|this|that) on (my|our|the) (list|tasks?))\b", re.I)
_COMMAND_STRIP = re.compile(r"^.*?\b(?:remind me (?:to|about)?|reminder (?:to|for|about)|tasks? (?:to|for|that)|to-?dos? (?:to|for|that)|"
                            r"note to self:?|(?:list|tasks|reminders?) that)\s*(?:i (?:have|need|must|got) to\s*)?", re.I)


def command_tasks(cfg: dict, segments: list) -> list:
    """Requests spoken to Earmark always become the wearer's tasks. The model words them; if it can't,
    the request line itself is kept, so a spoken reminder is never lost."""
    out, used = [], set()
    for i, sg in enumerate(segments):
        if i in used or not _COMMAND.search(sg.get("text", "")):
            continue
        group = [i]                                           # include the next lines said straight after
        while group[-1] + 1 < len(segments) and len(group) < 4 and \
                (segments[group[-1] + 1].get("start") or 0) - (sg.get("start") or 0) <= 25:
            group.append(group[-1] + 1)
        used.update(group)
        said = " ".join(segments[j]["text"] for j in group)
        items = []
        try:
            r = ask_json(cfg, COMMAND_SYSTEM, said, 400)
            items = [t for t in (r.get("tasks") or []) if isinstance(t, dict) and str(t.get("task", "")).strip()]
        except Exception:
            items = []
        if not items:
            text = _COMMAND_STRIP.sub("", sg["text"]).strip(" .,") or sg["text"]
            items = [{"task": text[:1].upper() + text[1:], "due_text": None}]
        for t in items:
            out.append({"task": t["task"], "owner": "me", "due_text": t.get("due_text"), "done": False,
                        "quote": said[:240], "t": sg.get("start"), "origin": "spoken"})
    return out


FOLLOWUP_SYSTEM = """You keep a to-do list up to date from new conversations.
Given OPEN TASKS (with ids) and NEW NOTES from a conversation, return JSON:
{"completed": [{"id": 12, "evidence": "short verbatim quote showing it is finished"}],
 "duplicates": [{"new": 0, "id": 12}]}
- completed: only when the conversation clearly says that open task is finished.
- duplicates: a new task (by its index in NEW TASKS) that is the same piece of work as an open task.
Be conservative; when unsure, leave it out."""

DAY_SYSTEM = """You write a short end-of-day brief for the wearer of a voice recorder, from the day's conversation notes.
Return JSON:
{"headline": "one line, max 14 words, the most important thing about the day",
 "summary": "3-5 sentences in second person ('You met ...')",
 "highlights": [{"text": "a notable moment or outcome", "session": <id of the conversation>}],
 "decisions": ["key decisions of the day"],
 "people": ["who you spoke with"]}
Prefer substance over chit-chat. Never invent."""


EARMARK_BEFORE_S, EARMARK_AFTER_S = 20, 30
_CUE = re.compile(r"\b(i'll|i will|i'm going to|i am going to|i can do|i need to|we need to|let me|can you|could you|"
                  r"would you|please|make sure|remind me|note to self|i have to|i've got to|i must|i should|don't forget|"
                  r"(add|put|create|make|set)\b[^.?!]{0,30}\b(task|reminder|to-?do|note)s?|owns?|take care of|follow up|by (today|tonight|"
                  r"tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next|end of)|"
                  r"(it's|that's|is) done|already (sent|did|done|finished)|i (sent|finished|completed|submitted|did))\b", re.I)


def _transcript_text(segments: list, marks: Optional[list] = None) -> str:
    lines = []
    for s in segments:
        m, sec = divmod(int(s.get("start", 0)), 60)
        tag = f" (translated from {s['from']})" if s.get("from") else ""
        star = "★ " if marks and any(mk - EARMARK_BEFORE_S <= s.get("start", 0) <= mk + EARMARK_AFTER_S for mk in marks) else ""
        cue = "◆ " if _CUE.search(s["text"]) else ""
        who = f"{s['who']}: " if s.get("who") else ""
        lines.append(f"[{m:02d}:{sec:02d}] {star}{cue}{who}{s['text']}{tag}")
    return "\n".join(lines)


def _split(lines: str, size: int) -> list[str]:
    parts, cur, n = [], [], 0
    for ln in lines.splitlines():
        if cur and n + len(ln) > size:
            parts.append("\n".join(cur))
            cur, n = [], 0
        cur.append(ln)
        n += len(ln) + 1
    if cur:
        parts.append("\n".join(cur))
    return parts



# ---------------------------------------------------------------- deadlines
_WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
_MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
           "october", "november", "december"]


def resolve_due(text: Optional[str], ref: date) -> Optional[str]:
    """Turn a spoken deadline into a date, relative to the day it was said. Small models get
    date arithmetic wrong, so they only report the words; this does the maths.
    Returns YYYY-MM-DD or None when the phrase has no clear date."""
    if not text:
        return None
    t = " " + re.sub(r"[^a-z0-9 ]", " ", str(text).lower()) + " "
    t = re.sub(r"\s+", " ", t)
    if re.search(r" (today|tonight|this evening|this afternoon|end of (the )?day|eod|by close|this morning) ", t):
        return ref.isoformat()
    if re.search(r" (tomorrow|tmrw) ", t):
        return (ref + timedelta(days=1)).isoformat()
    if " day after tomorrow " in t:
        return (ref + timedelta(days=2)).isoformat()
    m = re.search(r" in (\d+|a|one|two|three|four|five|six|seven) (day|days|week|weeks) ", t)
    if m:
        n = {"a": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7}.get(m.group(1)) or int(m.group(1))
        return (ref + timedelta(days=n * (7 if m.group(2).startswith("week") else 1))).isoformat()
    for i, wd in enumerate(_WEEKDAYS):
        if f" {wd} " not in t:
            continue
        ahead = (i - ref.weekday()) % 7          # days until the next such weekday (0 = today)
        if f" next {wd} " in t:
            # "next Friday" said on a Tuesday is the Friday of next week; said on a Saturday, the coming one
            ahead = ahead + 7 if 0 < ahead and i > ref.weekday() else (ahead or 7)
        elif ahead == 0 and f" this {wd} " not in t and " today " not in t:
            ahead = 7
        return (ref + timedelta(days=ahead)).isoformat()
    if re.search(r" (end of (the |this )?week|this week|by the weekend|this weekend) ", t):
        return (ref + timedelta(days=(4 - ref.weekday()) % 7)).isoformat()
    if re.search(r" (next week|early next week) ", t):
        return (ref + timedelta(days=7 - ref.weekday())).isoformat()          # Monday next week
    if re.search(r" end of (the |this )?month ", t):
        nxt = (ref.replace(day=28) + timedelta(days=4)).replace(day=1)
        return (nxt - timedelta(days=1)).isoformat()
    m = re.search(r" (\d{1,2})(st|nd|rd|th)? (of )?(" + "|".join(_MONTHS) + ") ", t) or \
        re.search(r" (" + "|".join(_MONTHS) + r") (\d{1,2})(st|nd|rd|th)? ", t)
    if m:
        g = m.groups()
        day_n, month = (int(g[0]), _MONTHS.index(g[3]) + 1) if g[0].isdigit() else (int(g[1]), _MONTHS.index(g[0]) + 1)
        try:
            d = date(ref.year, month, day_n)
            return (d if d >= ref - timedelta(days=30) else date(ref.year + 1, month, day_n)).isoformat()
        except ValueError:
            return None
    m = re.search(r" the (\d{1,2})(st|nd|rd|th) ", t)
    if m:
        n = int(m.group(1))
        try:
            d = ref.replace(day=n)
            if d < ref:
                d = (ref.replace(day=28) + timedelta(days=4)).replace(day=n)
            return d.isoformat()
        except ValueError:
            return None
    return None


# ---------------------------------------------------------------- public api
def conversation_notes(cfg: dict, segments: list, started_at: int,
                       progress: Optional[Callable[[float, str], None]] = None, marks: Optional[list] = None) -> dict:
    when = datetime.fromtimestamp(started_at)
    text = _transcript_text(segments, marks)
    from . import vocab as VOC
    words = VOC.prompt_line(cfg.get("vocabulary", ""))
    head = _today_line(when) + (" " + words if words else "") + "\n\nTranscript:\n"
    parts = _split(text, CHUNK_CHARS)
    if len(parts) == 1:
        if progress:
            progress(0.1, "reading the conversation")
        notes = ask_json(cfg, NOTES_SYSTEM, head + text, 2000)
    else:
        part_notes = []
        for i, p in enumerate(parts):
            if progress:
                progress(i / (len(parts) + 1), f"reading part {i + 1} of {len(parts)}")
            pn = ask_json(cfg, PART_SYSTEM, f"{_today_line(when)} This is part {i + 1} of {len(parts)}.\n\n{p}", 1500)
            part_notes.append(pn)
        if progress:
            progress(len(parts) / (len(parts) + 1), "combining the parts")
        notes = ask_json(cfg, MERGE_SYSTEM, _today_line(when) + "\n\nPart notes:\n" +
                         json.dumps(part_notes, ensure_ascii=False), 2500)
    if progress:
        progress(0.85, "checking every commitment")
    try:
        lt = line_tasks(cfg, segments)
    except Exception:
        lt = []
    try:
        lt = command_tasks(cfg, segments) + lt
    except Exception:
        pass
    if isinstance(notes, dict):
        own = [t for t in (notes.get("tasks") or []) if isinstance(t, dict) and t.get("task")]
        try:
            notes["tasks"] = _merge_tasks(lt, own)
        except Exception:                                    # never lose the notes over a merge problem
            notes["tasks"] = own + lt
    return normalise_notes(notes, started_at)


def line_tasks(cfg: dict, segments: list) -> list:
    """Classify each line with commitment/completion language, one small decision at a time."""
    idx = [i for i, sg in enumerate(segments) if _CUE.search(sg.get("text", ""))]
    out = []
    for start in range(0, len(idx), 12):                       # batches keep prompts short
        batch = idx[start:start + 12]
        items = []
        for k, i in enumerate(batch):
            def said(j):
                sg = segments[j]
                return (f"{sg['who']}: " if sg.get("who") else "") + sg["text"]
            items.append({"n": k, "BEFORE": said(i - 1) if i > 0 else "",
                          "LINE": said(i),
                          "AFTER": said(i + 1) if i + 1 < len(segments) else ""})
        r = ask_json(cfg, LINES_SYSTEM, json.dumps({"items": items}, ensure_ascii=False), 1500)
        for it in (r.get("items") or []) if isinstance(r, dict) else []:
            if not isinstance(it, dict) or it.get("kind") not in ("task", "done"):
                continue
            n = it.get("n")
            if not isinstance(n, int) or not 0 <= n < len(batch) or not str(it.get("task", "")).strip():
                continue
            sg = segments[batch[n]]
            owner = it.get("owner") or "unknown"
            before = segments[batch[n] - 1]["text"] if batch[n] > 0 else ""
            owner = _addressed_owner(before, sg["text"], owner)
            if sg.get("who") and _FIRST_PERSON.search(sg["text"]) and it["kind"] == "task":
                owner = sg["who"]                              # the speaker is known: "I'll ..." is theirs
            out.append({"task": it["task"], "owner": owner, "due_text": it.get("due_text"),
                        "done": it["kind"] == "done", "quote": sg["text"][:240], "t": sg.get("start")})
    return out


_ADDRESS = re.compile(r"(?:^|[.?!]\s+)([A-Z][a-z]{2,})(?:,|\?)")
_FIRST_PERSON = re.compile(r"\b(i'll|i will|i can|i'm going to|i am going to|i sent|i did|i finished|i've)\b", re.I)
_NOT_NAMES = {"Okay", "Yes", "Great", "Good", "Sure", "Thanks", "Alright", "Right", "Well", "So", "And", "But", "Also",
              "First", "Second", "Third", "Last", "Mostly", "Agreed", "Then", "Now", "Hi", "Hello", "Everyone"}


def _addressed_owner(before: str, line: str, owner: str) -> str:
    """'Priya, are we on track?' followed by 'I'll chase the vendor' -> the task is Priya's.
    Only overrides a model answer of me/unknown, and only for a first-person reply."""
    if (owner or "unknown").lower() not in ("me", "unknown") or not _FIRST_PERSON.search(line):
        return owner
    names = [m for m in _ADDRESS.findall(before) if m not in _NOT_NAMES]
    return names[-1] if names else owner


def _merge_tasks(primary: list, extra: list) -> list:
    """Combine the line-by-line pass (finds more, reliable quotes and times) with the notes pass
    (better wording), then remove duplicates inside this one conversation."""
    merged = []
    for t in primary:
        best = max(extra, key=lambda e: similar(e["task"], t["task"]), default=None)
        if best and similar(best["task"], t["task"]) >= 0.3 and \
                (best.get("owner") or "unknown").lower() in ((t.get("owner") or "unknown").lower(), "unknown", "me") and \
                len(best["task"]) > len(t["task"]) and not t.get("done"):
            t = {**t, "task": best["task"]}                    # keep line quote/time, use the fuller wording
        merged.append(t)
    for t in extra:
        if not any(similar(t["task"], p["task"]) >= 0.45 for p in merged):
            merged.append(t)
    return dedupe_tasks(merged)


def dedupe_tasks(tasks: list) -> list:
    """Within one conversation a task is often said twice (request, then 'yes, I'll ...'), or asked about
    and reported done. Keep one: a finished version wins; otherwise the more specific wording."""
    tasks = [{**t, "t": _secs(t.get("t"))} for t in tasks]
    tasks = sorted(tasks, key=lambda x: (x["t"] is None, x["t"] or 0))
    keep: list = []
    for t in tasks:
        dup = None
        for k in keep:
            same_owner = (k.get("owner") or "").lower() == (t.get("owner") or "").lower()
            close = k.get("t") is not None and t.get("t") is not None and abs(k["t"] - t["t"]) <= 45
            sim = similar(k["task"], t["task"])
            if sim >= 0.5 or (same_owner and close and sim >= 0.2):
                dup = k
                break
        if dup is None:
            keep.append(dict(t))
            continue
        if t.get("done") and not dup.get("done"):
            dup.update(done=True, quote=t.get("quote") or dup.get("quote"))
            continue                                         # keep the original imperative wording
        if len(t["task"]) > len(dup["task"]):
            dup["task"] = t["task"]
        dup["due_text"] = dup.get("due_text") or t.get("due_text")
    return keep


def normalise_notes(n: dict, started_at: int) -> dict:
    ref = datetime.fromtimestamp(started_at).date()
    if not isinstance(n, dict):
        n = {}
    def strs(v):
        return [str(x).strip() for x in (v or []) if str(x).strip()] if isinstance(v, list) else []
    tasks = []
    for t in n.get("tasks") or []:
        if not isinstance(t, dict) or not str(t.get("task", "")).strip():
            continue
        due_text = (str(t.get("due_text")).strip() if t.get("due_text") not in (None, "", "null") else None)
        due = resolve_due(due_text, ref)        # never trust a model's date arithmetic
        text = str(t["task"]).strip().rstrip(".")
        text = text[:1].upper() + text[1:]
        tasks.append({"task": text,
                      "owner": (str(t.get("owner") or "unknown").strip() or "unknown"),
                      "due": due, "due_text": due_text,
                      "done": bool(t.get("done")), "quote": (t.get("quote") or "").strip()[:240],
                      "t": _secs(t.get("t"))})
    kind = str(n.get("kind") or "conversation").strip().lower().replace(" ", "_")
    if kind not in ("meeting", "call", "conversation", "note_to_self", "ambient"):
        kind = "conversation"
    return {"title": (str(n.get("title") or "").strip() or None), "kind": kind,
            "summary": str(n.get("summary") or "").strip(), "key_points": strs(n.get("key_points")),
            "decisions": strs(n.get("decisions")), "tasks": tasks, "people": strs(n.get("people")),
            "topics": strs(n.get("topics"))[:6]}


def _secs(v) -> Optional[float]:
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        m = re.match(r"(?:(\d+):)?(\d+):(\d+)", v.strip())
        if m:
            h, mi, s = int(m.group(1) or 0), int(m.group(2)), int(m.group(3))
            return float(h * 3600 + mi * 60 + s)
    return None


def follow_up(cfg: dict, open_tasks: list, notes: dict) -> dict:
    """Which open tasks this conversation completes, and which new tasks duplicate open ones."""
    if not open_tasks:
        return {"completed": [], "duplicates": []}
    payload = {"OPEN TASKS": [{"id": t["id"], "task": t["text"], "owner": t["owner"]} for t in open_tasks[:60]],
               "NEW NOTES": {"summary": notes["summary"], "key_points": notes["key_points"],
                             "NEW TASKS": [{"index": i, "task": t["task"], "owner": t["owner"], "done": t["done"],
                                            "quote": t["quote"]} for i, t in enumerate(notes["tasks"])]}}
    r = ask_json(cfg, FOLLOWUP_SYSTEM, json.dumps(payload, ensure_ascii=False), 800)
    by_id = {t["id"]: t for t in open_tasks}

    def same_person(a, b):
        a, b = (a or "unknown").lower(), (b or "unknown").lower()
        return a == b or "unknown" in (a, b)
    # A small model sometimes pairs unrelated tasks; require real word overlap and a compatible owner.
    comp = [c for c in (r.get("completed") or []) if isinstance(c, dict) and c.get("id") in by_id
            and similar(by_id[c["id"]]["text"], str(c.get("evidence", ""))) >= 0.2]
    dup = [d for d in (r.get("duplicates") or []) if isinstance(d, dict) and d.get("id") in by_id
           and isinstance(d.get("new"), int) and 0 <= d["new"] < len(notes["tasks"])
           and similar(by_id[d["id"]]["text"], notes["tasks"][d["new"]]["task"]) >= 0.3
           and same_person(by_id[d["id"]]["owner"], notes["tasks"][d["new"]]["owner"])]
    return {"completed": comp, "duplicates": dup}


def day_brief(cfg: dict, day: date, sessions: list) -> dict:
    items = [{"session": s["id"], "time": datetime.fromtimestamp(s["started_at"]).strftime("%H:%M"),
              "minutes": round(s["duration_s"] / 60), "title": s["title"], "kind": s["kind"],
              "summary": s["notes"].get("summary"), "decisions": s["notes"].get("decisions"),
              "key_points": s["notes"].get("key_points", [])[:5]} for s in sessions]
    r = ask_json(cfg, DAY_SYSTEM, f"Day: {day.strftime('%A %d %B %Y')}\n\nConversations:\n" +
                 json.dumps(items, ensure_ascii=False), 1200)
    valid = {s["id"] for s in sessions}
    hl = [h for h in (r.get("highlights") or []) if isinstance(h, dict) and h.get("text")]
    for h in hl:
        if h.get("session") not in valid:
            h["session"] = None
    return {"headline": str(r.get("headline") or "").strip(), "summary": str(r.get("summary") or "").strip(),
            "highlights": hl[:8], "decisions": [str(x) for x in (r.get("decisions") or [])][:8],
            "people": [str(x) for x in (r.get("people") or [])][:12]}


def similar(a: str, b: str) -> float:
    """Word-overlap similarity, a cheap backstop for duplicate tasks."""
    wa, wb = set(re.findall(r"[a-z0-9]+", a.lower())) - _STOP, set(re.findall(r"[a-z0-9]+", b.lower())) - _STOP
    return len(wa & wb) / max(1, len(wa | wb))


_STOP = {"the", "a", "an", "to", "for", "of", "and", "on", "in", "by", "with", "me", "my", "i", "it", "this", "that"}


def status(cfg: dict) -> dict:
    p = cfg.get("intel_provider", "local")
    if os.environ.get("EARMARK_FAKE_LLM") == "1":
        return {"provider": "fake", "ready": True, "detail": "simulated model (tests)"}
    if p == "off":
        return {"provider": p, "ready": False, "detail": "turned off"}
    if p == "local":
        from . import pipeline as PL
        repo = cfg.get("local_model") or DEFAULT_LOCAL
        have = PL._hf_cached(repo, "*.safetensors")
        return {"provider": p, "ready": _local_available() and have, "model": repo,
                "detail": "ready" if have and _local_available() else "downloads on first use"}
    if p == "openai":
        return {"provider": p, "ready": bool(cfg.get("openai_key")), "detail": "key set" if cfg.get("openai_key") else "needs an API key"}
    if p == "anthropic":
        return {"provider": p, "ready": bool(cfg.get("anthropic_key")), "detail": "key set" if cfg.get("anthropic_key") else "needs an API key"}
    if p == "ollama":
        from . import pipeline as PL
        ok = cfg.get("ollama_model") in PL.ollama_models(cfg["ollama_host"])
        return {"provider": p, "ready": ok, "detail": "ready" if ok else "Ollama not running or model missing"}
    return {"provider": p, "ready": False, "detail": "unknown provider"}


# ---------------------------------------------------------------- fake model for tests
def _fake(system: str, user: str) -> str:
    time.sleep(0.2)
    if system is NOTES_SYSTEM or system.startswith(NOTES_SYSTEM[:40]) or system is MERGE_SYSTEM:
        d = (date.today() + timedelta(days=2)).isoformat()
        tasks = []
        if "vendor contract" in user:
            tasks.append({"task": "Send the vendor contract to procurement", "owner": "Rahul", "due": d,
                          "due_text": "by Thursday", "done": False, "quote": "Rahul will send the vendor contract by Thursday", "t": "00:04"})
        if "launch plan" in user:
            tasks.append({"task": "Share the pilot launch plan with the team", "owner": "me", "due": None,
                          "due_text": None, "done": False, "quote": "Let's review the launch plan for the pilot", "t": "00:00"})
        return json.dumps({"title": "Pilot launch review", "kind": "meeting",
                           "summary": "Reviewed the pilot launch plan. Agreed to hold the budget; Rahul owns the vendor contract.",
                           "key_points": ["Launch plan reviewed", "Budget unchanged"],
                           "decisions": ["Keep the budget at the current level"], "tasks": tasks,
                           "people": ["Rahul"], "topics": ["pilot", "budget"]})
    if system is FOLLOWUP_SYSTEM:
        payload = json.loads(user)
        dups = []
        for i, nt in enumerate(payload["NEW NOTES"]["NEW TASKS"]):
            for ot in payload["OPEN TASKS"]:
                if similar(nt["task"], ot["task"]) > 0.6:
                    dups.append({"new": i, "id": ot["id"]})
                    break
        return json.dumps({"completed": [], "duplicates": dups})
    if system.startswith("You answer questions about the user's own recorded conversations"):
        return json.dumps({"answer": "Rahul is sending the vendor contract to procurement by Thursday.", "used": [1]})
    if system is DAY_SYSTEM:
        return json.dumps({"headline": "Pilot launch reviewed; budget held flat",
                           "summary": "You reviewed the pilot launch plan and agreed to keep the budget unchanged. Rahul is sending the vendor contract.",
                           "highlights": [{"text": "Budget held at the current level", "session": None}],
                           "decisions": ["Keep the budget at the current level"], "people": ["Rahul"]})
    return json.dumps({"summary": "part", "key_points": [], "decisions": [], "tasks": [], "people": [], "topics": []})
