"""Fast checks of task extraction logic that do not need a model."""
from earmark import intel as I


def _no_model(monkeypatch):
    def fail(*a, **k):
        raise RuntimeError("model unavailable")
    monkeypatch.setattr(I, "ask_json", fail)


def test_spoken_requests_always_become_my_tasks(monkeypatch):
    _no_model(monkeypatch)
    segs = [{"start": 0, "text": "I want you to take a task and add it to our tasks that I have to charge my Tesla."},
            {"start": 6, "text": "Create a reminder for charging reservations that I have."}]
    out = I.command_tasks({}, segs)
    assert len(out) == 1 and out[0]["owner"] == "me" and "Tesla" in out[0]["task"]
    assert I.command_tasks({}, [{"start": 0, "text": "Remind me to put my car on charging."}])[0]["task"] == "Put my car on charging"


def test_talking_about_reminders_is_not_a_request():
    assert not I._COMMAND.search("We discussed the reminder policy for customers.")


def test_same_task_said_twice_is_kept_once():
    ts = [dict(task="Provide final numbers", owner="Imran", t=65, done=False),
          dict(task="Send numbers", owner="Imran", t=75, done=False),
          dict(task="Send the signed contract to procurement", owner="Leo", t=137, done=False),
          dict(task="Sending the signed contract to procurement", owner="Leo", t=138, done=True)]
    out = I.dedupe_tasks(ts)
    assert len(out) == 2
    assert out[1]["done"] and out[1]["task"] == "Send the signed contract to procurement"


def test_reply_to_a_named_person_is_theirs():
    assert I._addressed_owner("Priya, are we on track for the twentieth?", "Mostly. I'll chase the vendor for it.", "me") == "Priya"
