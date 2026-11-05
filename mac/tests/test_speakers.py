"""Speaker grouping and voice matching, with synthetic voice signatures (no model needed)."""
import numpy as np
from earmark import speakers as SPK


def _voice(rng, base, n):
    return [SPK._norm(base + rng.normal(0, 0.04, len(base))) for _ in range(n)]


def test_groups_lines_by_voice():
    rng = np.random.default_rng(0)
    a, b, c = (SPK._norm(rng.normal(0, 1, 192)) for _ in range(3))
    E = np.stack(_voice(rng, a, 12) + _voice(rng, b, 8) + _voice(rng, c, 5))
    lab = SPK._average_linkage(E, SPK.CLUSTER_DIST)
    assert len(set(lab[:12])) == 1 and len(set(lab[12:20])) == 1 and len(set(lab[20:])) == 1
    assert len(set(lab)) == 3


def test_saved_voices_are_recognised_once_and_strangers_are_not():
    rng = np.random.default_rng(1)
    priya, leo, new = (SPK._norm(rng.normal(0, 1, 192)) for _ in range(3))
    people = [{"id": 1, "name": "Priya", "vec": list(priya * 40)}, {"id": 2, "name": "Leo", "vec": list(leo * 10)}]
    sp = [{"label": "S1", "vec": list(SPK._norm(priya + rng.normal(0, .03, 192))), "rms": .05, "seconds": 30, "state": "none"},
          {"label": "S2", "vec": list(SPK._norm(priya + rng.normal(0, .03, 192))), "rms": .05, "seconds": 5, "state": "none"},
          {"label": "S3", "vec": list(new), "rms": .05, "seconds": 20, "state": "none"}]
    SPK.match(sp, people)
    assert [s.get("person_id") for s in sp] == [1, None, None]     # Priya only once, the stranger stays unnamed
    assert sp[0]["state"] == "auto"


def test_loudest_voice_is_offered_as_me():
    sp = [{"label": "S1", "vec": [1, 0], "rms": .2, "seconds": 40, "state": "none"},
          {"label": "S2", "vec": [0, 1], "rms": .04, "seconds": 30, "state": "none"}]
    SPK.match(sp, [])
    assert sp[0].get("guess_me") and sp[0]["state"] == "suggested" and not sp[1].get("guess_me")
