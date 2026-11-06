"""Transcripts made on the iPhone become the session's transcript on the Mac."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from earmark import phonetext as PT  # noqa: E402


def _chunk(start, secs, words):
    return {"start": start, "seconds": secs, "text": " ".join(w[2] for w in words), "words": words}


def test_segments_split_at_sentences_and_pauses_with_session_relative_times():
    t0 = 1_000_000.0
    chunks = [
        _chunk(t0, 30, [[0.5, 0.9, "Let's"], [1.0, 1.3, "start."], [1.5, 1.8, "Rahul"], [1.9, 2.2, "will"], [29.5, 29.9, "send"]]),
        _chunk(t0 + 30.02, 10, [[0.0, 0.4, "it"], [0.5, 0.9, "Thursday."], [5.0, 5.4, "Thanks"]]),
    ]
    segs = PT.segments_from_chunks(chunks, t0)
    assert [s["text"] for s in segs] == ["Let's start.", "Rahul will", "send it Thursday.", "Thanks"]
    assert segs[2]["start"] == 29.5 and segs[2]["end"] == 30.92
    assert segs[2]["words"][1] == [30.02, 30.42, "it"]


def test_phone_text_stands_only_when_it_covers_the_session():
    t0 = 2_000_000.0
    chunks = [_chunk(t0, 30, [[1, 2, "Hello."]]), _chunk(t0 + 30, 30, [[1, 2, "Again."]])]
    assert PT.transcript(chunks, t0, t0 + 60)["text"] == "Hello.\nAgain."
    assert PT.transcript(chunks[:1], t0, t0 + 60) is None, "half the session: the Mac transcribes it"
    assert PT.transcript([], t0, t0 + 60) is None


def test_chunk_without_word_timings_is_spread_evenly():
    segs = PT.segments_from_chunks([{"start": 10.0, "seconds": 4, "text": "one two three four", "words": []}], 10.0)
    assert segs[0]["text"] == "one two three four" and segs[0]["words"][3] == [3.0, 4.0, "four"]
