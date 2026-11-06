import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from earmark import vocab as V  # noqa: E402

VOC = "RAKBANK\nrack bank, rag bank = RAKBANK\nTushar\nTTX Pro\n# a comment\n"


def test_terms_and_prompt():
    assert V.terms(VOC) == ["RAKBANK", "Tushar", "TTX Pro"]
    assert "RAKBANK, Tushar, TTX Pro" in V.prompt_line(VOC)
    assert V.prompt_line("") == ""


def test_words_are_corrected_and_keep_their_timing():
    segs = [{"text": "I spoke to rack bank today.", "words": [[0, .3, "I"], [.3, .6, "spoke"], [.6, .8, "to"],
                                                                [.8, 1, "rack"], [1, 1.2, "bank"], [1.2, 1.5, "today."]]},
            {"text": "rak bank and ttx pro, tushar.", "words": [[0, 1, "rak"], [1, 2, "bank"], [2, 3, "and"],
                                                                 [3, 4, "ttx"], [4, 5, "pro,"], [5, 6, "tushar."]]},
            {"text": "no words list here, rakbank"}]
    out = V.fix_segments(segs, VOC)
    assert out[0]["text"] == "I spoke to RAKBANK today."
    assert out[0]["words"][3] == [.8, 1.2, "RAKBANK"]
    assert out[1]["text"] == "RAKBANK and TTX Pro, Tushar."
    assert out[2]["text"] == "no words list here, RAKBANK"


def test_short_terms_only_match_exactly():
    # "Al" must not swallow every "a l…" pair; split-spelling matching needs 4+ letters
    out = V.fix_segments([{"text": "a l", "words": [[0, 1, "a"], [1, 2, "l"]]}], "Al")
    assert out[0]["text"] == "a l"
