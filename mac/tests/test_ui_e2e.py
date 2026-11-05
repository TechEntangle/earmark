"""End-to-end tests: the real Earmark service, a simulated pendant, a real browser.

    ./run_tests.sh            (or: python -m pytest tests -q)

The service runs with
  EARMARK_FAKE_PENDANT=1     simulated pendant: memory, live stream, button, light, clock
  EARMARK_FAKE_TRANSCRIBE=1  fixed transcript, so tests are fast and repeatable
  EARMARK_FAKE_LLM=1         fixed notes/tasks/brief instead of a language model
Everything else (database, queues, APIs, the page) is the production code path.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

import pytest
from playwright.sync_api import Page, expect, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
MOD = "Meta" if sys.platform == "darwin" else "Control"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def call(base: str, path: str, method: str = "GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def wait_for(fn, timeout=30, what="condition"):
    end, last = time.time() + timeout, None
    while time.time() < end:
        try:
            last = fn()
            if last:
                return last
        except Exception as e:
            last = e
        time.sleep(0.3)
    raise AssertionError(f"timed out waiting for {what}; last={last!r}")


@pytest.fixture(scope="module")
def server():
    home = Path(tempfile.mkdtemp(prefix="earmark-e2e-"))
    port = _free_port()
    env = dict(os.environ, EARMARK_HOME=str(home), EARMARK_PORT=str(port), EARMARK_FAKE_PENDANT="1",
               EARMARK_FAKE_TRANSCRIBE="1", EARMARK_FAKE_LLM="1", EARMARK_FAKE_OFFLINE_SECONDS="30")
    log = open(home / "service.log", "w")
    proc = subprocess.Popen([os.environ.get("EARMARK_TEST_PYTHON", sys.executable), "-m", "earmark.app"],
                            cwd=ROOT, env=env, stdout=log, stderr=log)
    base = f"http://127.0.0.1:{port}"
    try:
        wait_for(lambda: call(base, "/api/status")["pendant"]["connected"], 40, "simulated pendant to connect")
        wait_for(lambda: call(base, "/api/status")["tasks"]["all_open"] >= 2, 40, "notes and tasks from the first conversation")
        wait_for(lambda: call(base, "/api/day")["brief"], 40, "the day brief")
        yield base
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
        if proc.returncode not in (0, -15, None):
            print("\n--- service log ---\n" + (home / "service.log").read_text()[-4000:])
        shutil.rmtree(home, ignore_errors=True)


@pytest.fixture(scope="module")
def browser():
    with sync_playwright() as p:
        exe = os.environ.get("EARMARK_TEST_CHROME")
        b = p.chromium.launch(executable_path=exe, args=["--no-sandbox"]) if exe else p.chromium.launch()
        yield b
        b.close()


@pytest.fixture
def page(browser, server) -> Page:
    ctx = browser.new_context(viewport={"width": 1360, "height": 900})
    pg = ctx.new_page()
    errors = []
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.goto(server + "/#/today")
    yield pg
    ctx.close()
    assert not errors, f"JavaScript errors on the page: {errors}"


def open_tasks(server):
    return call(server, "/api/tasks?view=open")


# ---------------------------------------------------------------- Today
def test_today_shows_brief_timeline_and_tasks(page: Page):
    expect(page.locator(".brief .headline")).to_have_text("Pilot launch reviewed; budget held flat")
    expect(page.locator(".conv").first).to_contain_text("Pilot launch review")
    expect(page.locator(".conv .chip.task").first).to_have_text("2 tasks")
    expect(page.locator("#todayTasks .task")).to_have_count(2)
    expect(page.locator(".side")).to_contain_text("Keep the budget at the current level")


def test_device_card_shows_recording_and_battery(page: Page):
    expect(page.locator("#devState")).to_have_text("Recording", timeout=10_000)
    expect(page.locator("#battPct")).to_have_text("87%")
    expect(page.locator("#pulse")).to_have_class("pulse live")
    expect(page.locator("#connectBtn")).to_be_hidden()
    expect(page.locator("#navTasks")).to_have_text("1")


def test_day_tape_block_opens_the_conversation(page: Page):
    page.locator(".tape-block").first.click()
    expect(page).to_have_url(re.compile(r"#/c/\d+"))
    expect(page.locator("#ctitle")).to_have_text("Pilot launch review")


# ---------------------------------------------------------------- Conversation
def test_conversation_notes_transcript_and_player(page: Page):
    page.locator(".conv").first.click()
    expect(page.locator(".notes .sum")).to_contain_text("Reviewed the pilot launch plan")
    expect(page.locator("#ctasks .task")).to_have_count(2)
    expect(page.locator("#ctasks .quote").first).to_contain_text("“")
    expect(page.locator(".decision")).to_contain_text("Keep the budget")
    dur = page.wait_for_function("() => { const a = document.querySelector('#audio'); return a && isFinite(a.duration) && a.duration > 1 && a.duration; }", timeout=10_000).json_value()
    assert dur > 1
    page.click("button[data-tab=transcript]")
    expect(page.locator(".tline")).to_have_count(3)
    expect(page.locator(".tline .tag")).to_have_text("translated from German")
    page.locator(".tline").nth(1).click()
    page.wait_for_function("() => document.querySelector('#audio').currentTime >= 3.9")
    expect(page).to_have_url(re.compile(r"/transcript$"))


def test_task_source_link_jumps_to_the_moment(page: Page):
    link = page.locator("#todayTasks a.src", has_text="at 0:04")
    link.click()
    expect(page).to_have_url(re.compile(r"#/c/\d+/4(\.0)?$"))
    expect(page.locator(".tline.now")).to_contain_text("Rahul will send the vendor contract")
    page.wait_for_function("() => Math.abs(document.querySelector('#audio').currentTime - 4) < 0.6", timeout=10_000)


def test_rename_conversation(page: Page, server):
    page.locator(".conv").first.click()
    t = page.locator("#ctitle")
    t.click()
    page.keyboard.press(f"{MOD}+A")
    page.keyboard.type("Pilot launch review with Rahul")
    page.keyboard.press("Enter")
    expect(page.locator(".toast")).to_contain_text("Renamed")
    wait_for(lambda: any(s["title"] == "Pilot launch review with Rahul" for s in call(server, "/api/sessions")), 5, "rename saved")


# ---------------------------------------------------------------- Tasks
def test_tasks_split_mine_and_waiting_on_others(page: Page):
    page.click("[data-nav=tasks]")
    expect(page.locator("#tgroups .task")).to_have_count(1)
    expect(page.locator("#tgroups")).to_contain_text("Share the pilot launch plan")
    page.click(".seg button[data-f=others]")
    expect(page.locator("#tgroups .task")).to_have_count(1)
    expect(page.locator("#tgroups .who")).to_have_text("Rahul")
    expect(page.locator("#tgroups .due")).to_contain_text("Due")


def test_complete_task_with_undo(page: Page, server):
    page.goto(page.url.split("#")[0] + "#/tasks")
    row = page.locator("#tgroups .task").first
    tid = int(row.get_attribute("data-id"))
    row.locator("[data-act=toggle]").click()
    expect(page.locator(".toast")).to_contain_text("Task done")
    wait_for(lambda: all(t["id"] != tid for t in open_tasks(server)), 5, "task marked done")
    page.click("#toastUndo")
    wait_for(lambda: any(t["id"] == tid for t in open_tasks(server)), 5, "undo reopened the task")


def test_add_edit_and_remove_a_task(page: Page, server):
    page.goto(page.url.split("#")[0] + "#/tasks")
    page.fill("#newTask", "Book the quarterly offsite venue")
    page.fill("#newDue", "2099-01-15")
    page.press("#newTask", "Enter")
    row = page.locator(".task", has_text="Book the quarterly offsite venue")
    expect(row).to_be_visible()
    expect(page.locator(".group", has=row).locator("h3")).to_contain_text("Later")
    row.locator(".ttext").click()
    page.keyboard.press(f"{MOD}+A")
    page.keyboard.type("Book the offsite venue in Hatta")
    page.keyboard.press("Enter")
    wait_for(lambda: any(t["text"] == "Book the offsite venue in Hatta" for t in open_tasks(server)), 5, "edit saved")
    page.goto(page.url.split("#")[0] + "#/tasks")
    row = page.locator(".task", has_text="Book the offsite venue in Hatta")
    row.hover()
    row.locator("[data-act=dismiss]").click()
    expect(page.locator(".toast")).to_contain_text("Task removed")
    wait_for(lambda: all("Hatta" not in t["text"] for t in open_tasks(server)), 5, "task removed")


def test_looks_done_can_be_confirmed(page: Page, server):
    t = next(t for t in open_tasks(server) if t["owner"] == "Rahul")
    call(server, "/api/_fake/suggest_done", "POST", {"id": t["id"], "evidence": "I sent the contract this morning"})
    page.goto(page.url.split("#")[0] + "#/tasks/others")
    box = page.locator(".looks-done")
    expect(box).to_contain_text("I sent the contract this morning")
    expect(page.locator(".group h3").first).to_contain_text("Looks done")
    box.locator("[data-act=confirm]").click()
    wait_for(lambda: all(x["id"] != t["id"] for x in open_tasks(server)), 5, "confirmed as done")
    call(server, f"/api/tasks/{t['id']}", "PATCH", {"status": "open"})


# ---------------------------------------------------------------- search + keyboard
def test_command_palette_finds_a_quote_and_jumps_to_it(page: Page):
    page.keyboard.press(f"{MOD}+K")
    page.keyboard.type("vendor contract")
    item = page.locator(".pitem", has_text="Rahul will send").first
    expect(item).to_be_visible()
    expect(page.locator(".pitem mark").first).to_have_text("vendor contract")
    item.click()
    expect(page).to_have_url(re.compile(r"#/c/\d+/4(\.0)?$"))
    expect(page.locator("#overlay")).to_be_hidden()


def test_palette_commands_and_keyboard_navigation(page: Page):
    page.keyboard.press("/")
    page.keyboard.type("settings")
    page.keyboard.press("Enter")
    expect(page).to_have_url(re.compile(r"#/settings$"))
    page.locator("body").click(position={"x": 5, "y": 5})
    page.keyboard.press("g")
    page.keyboard.press("k")
    expect(page).to_have_url(re.compile(r"#/tasks$"))
    page.keyboard.press("g")
    page.keyboard.press("t")
    expect(page).to_have_url(re.compile(r"#/today$"))


# ---------------------------------------------------------------- pendant controls
def test_pause_and_double_tap_control_recording_and_light(page: Page, server):
    expect(page.locator("#devState")).to_have_text("Recording", timeout=10_000)
    page.click("#pauseBtn")
    expect(page.locator("#devState")).to_have_text("Paused")
    expect(page.locator("#pauseBtn")).to_have_text("Resume")
    wait_for(lambda: call(server, "/api/_fake/state")["led"] == 0, 10, "light off while paused")
    call(server, "/api/_fake/tap", "POST", {"kind": 2})
    expect(page.locator("#devState")).to_have_text("Recording", timeout=6_000)
    wait_for(lambda: call(server, "/api/_fake/state")["led"] == 100, 10, "light back on")
    buzzes = call(server, "/api/_fake/state")["buzzes"]
    assert [3] in buzzes and [1, 1, 1] in buzzes, f"pause/resume vibrations: {buzzes}"


def test_out_of_range_then_back(page: Page, server):
    call(server, "/api/_fake/presence", "POST", {"present": False})
    expect(page.locator("#devState")).to_have_text("Not nearby", timeout=30_000)
    expect(page.locator("#connectBtn")).to_be_visible()
    expect(page.locator("#connectBtn")).to_have_text("Sync now")
    expect(page.locator("#devSub")).to_contain_text("synced")
    call(server, "/api/_fake/presence", "POST", {"present": True})
    page.click("#connectBtn")
    expect(page.locator("#devState")).to_have_text("Recording", timeout=30_000)
    expect(page.locator("#connectBtn")).to_be_hidden()


@pytest.mark.parametrize("width", [1360, 390])
def test_header_shows_state_and_opens_search(browser, server, width):
    ctx = browser.new_context(viewport={"width": width, "height": 900})
    pg = ctx.new_page()
    pg.goto(server + "/#/tasks")
    expect(pg.locator(".top #devState")).to_be_visible(timeout=10_000)
    expect(pg.locator(".top #pauseBtn")).to_be_visible()
    if width > 1200:
        expect(pg.locator("#hRec")).to_contain_text("today")
    pg.click("#hSearch")
    expect(pg.locator("#overlay")).to_be_visible()
    ctx.close()


# ---------------------------------------------------------------- settings
def test_settings_fit_save_and_reach_the_pendant(page: Page, server):
    page.goto(page.url.split("#")[0] + "#/settings")
    page.wait_for_selector("#setForm")
    over = page.evaluate("""() => { const f = document.querySelector('#setForm').getBoundingClientRect();
        return [...document.querySelectorAll('#setForm .field *')].filter(e => e.offsetParent && e.getBoundingClientRect().right > f.right + 1).map(e => e.id || e.className); }""")
    assert over == [], f"overflowing settings: {over}"
    expect(page.locator(".prov.on")).to_contain_text("On this Mac")
    page.locator("#led_brightness").fill("40")
    expect(page.locator("#ledOut")).to_have_text("40%")
    page.click("button[type=submit]")
    expect(page.locator("#saveMsg")).to_have_text("Saved")
    wait_for(lambda: call(server, "/api/_fake/state")["led"] == 40, 10, "light at 40%")
    page.locator("#led_brightness").fill("100")
    page.click("button[type=submit]")
    wait_for(lambda: call(server, "/api/_fake/state")["led"] == 100, 10, "light back to 100%")


def test_api_keys_are_never_sent_back_to_the_page(page: Page, server):
    page.goto(page.url.split("#")[0] + "#/settings/intelligence")
    page.click(".prov[data-p=anthropic]")
    page.fill("#anthropic_key", "sk-ant-test-1234567890abcd")
    page.click("button[type=submit]")
    expect(page.locator("#saveMsg")).to_have_text("Saved")
    cfg = call(server, "/api/settings")["config"]
    assert cfg["intel_provider"] == "anthropic"
    assert "1234567890" not in cfg["anthropic_key"] and cfg["anthropic_key"].endswith("abcd")
    page.reload()
    page.click(".prov[data-p=local]")
    page.click("button[type=submit]")
    expect(page.locator("#saveMsg")).to_have_text("Saved")
    assert call(server, "/api/settings")["config"]["intel_provider"] == "local"


# ---------------------------------------------------------------- deletion
def test_deleting_a_conversation_removes_its_tasks(page: Page, server):
    sid = call(server, "/api/sessions")[-1]["id"]
    before = [t for t in open_tasks(server) if t["session_id"] == sid]
    assert before
    page.goto(page.url.split("#")[0] + f"#/c/{sid}")
    page.once("dialog", lambda d: d.accept())
    page.click("#del")
    expect(page.locator(".toast")).to_contain_text("Conversation deleted")
    wait_for(lambda: not [t for t in open_tasks(server) if t["session_id"] == sid], 5, "its tasks removed")


# ---------------------------------------------------------------- layout
@pytest.mark.parametrize("width", [1440, 1024, 820, 390])
@pytest.mark.parametrize("route", ["#/today", "#/tasks", "#/conversations", "#/settings"])
def test_no_sideways_scrolling(browser, server, width, route):
    ctx = browser.new_context(viewport={"width": width, "height": 900})
    pg = ctx.new_page()
    pg.goto(server + "/" + route)
    pg.wait_for_timeout(700)
    sw = pg.evaluate("() => [document.documentElement.scrollWidth, innerWidth, document.querySelector('.main').scrollWidth, document.querySelector('.main').clientWidth]")
    ctx.close()
    assert sw[0] <= sw[1] and sw[2] <= sw[3], f"{route} scrolls sideways at {width}px: {sw}"


def test_update_banner_when_service_is_older_than_page(browser, server):
    """Files updated but service not restarted yet: offer a restart, not broken screens."""
    ctx = browser.new_context(viewport={"width": 1360, "height": 900})
    pg = ctx.new_page()

    def old_status(route):
        st = call(server, "/api/status")
        for k in ("tasks", "intel"):
            st.pop(k, None)
        route.fulfill(status=200, content_type="application/json", body=json.dumps(st))
    pg.route("**/api/status", old_status)
    restarted = []
    pg.route("**/api/restart", lambda r: (restarted.append(1), r.fulfill(status=200, content_type="application/json", body='{"ok":true}')))
    pg.goto(server + "/#/today")
    expect(pg.locator("#update")).to_be_visible()
    expect(pg.locator("#main")).to_contain_text("One step left")
    pg.click("#updateBtn")
    expect(pg.locator("#updateBtn")).to_have_text("Restarting")
    assert restarted
    ctx.close()



# ---------------------------------------------------------------- earmarks
def test_single_tap_earmarks_the_moment_with_a_buzz(page: Page, server):
    expect(page.locator("#devState")).to_have_text("Recording", timeout=10_000)
    n0 = len(call(server, "/api/_fake/state")["buzzes"])
    marks0 = len(call(server, "/api/day")["earmarks"])
    call(server, "/api/_fake/tap", "POST", {"kind": 1})
    expect(page.locator("#devSub")).to_contain_text("Earmarked the moment", timeout=5_000)
    wait_for(lambda: call(server, "/api/_fake/state")["buzzes"][n0:] == [[2]], 5, "one medium buzz")
    assert len(call(server, "/api/day")["earmarks"]) == marks0 + 1
    expect(page.locator("#devState")).to_have_text("Recording")


def test_slow_double_tap_pauses_instead_of_earmarking(page: Page, server):
    expect(page.locator("#devState")).to_have_text("Recording", timeout=10_000)
    marks0 = len(call(server, "/api/day")["earmarks"])
    call(server, "/api/_fake/tap", "POST", {"kind": 1})
    time.sleep(0.45)                                   # too slow for the firmware's 300 ms double tap
    call(server, "/api/_fake/tap", "POST", {"kind": 1})
    expect(page.locator("#devState")).to_have_text("Paused", timeout=5_000)
    time.sleep(1.3)
    assert len(call(server, "/api/day")["earmarks"]) == marks0, "a slow double tap must not leave an earmark"
    call(server, "/api/_fake/tap", "POST", {"kind": 2})
    expect(page.locator("#devState")).to_have_text("Recording", timeout=5_000)


def test_earmarked_moment_shows_in_the_conversation(page: Page, server):
    sid = next(x["id"] for x in call(server, "/api/sessions")
               if "vendor contract" in json.dumps(call(server, f"/api/sessions/{x['id']}")))
    call(server, "/api/_fake/earmark", "POST", {"session_id": sid, "offset": 4})
    page.goto(page.url.split("#")[0] + f"#/c/{sid}")
    expect(page.locator("#moments .moment", has_text="Rahul will send the vendor contract").first).to_be_visible()
    page.locator("#moments .moment").first.click()
    page.wait_for_function("() => document.querySelector('#audio').currentTime > 0")
    page.click("button[data-tab=transcript]")
    expect(page.locator(".tline.marked").first).to_be_visible()
    page.goto(page.url.split("#")[0] + "#/today")
    expect(page.locator(".tape-mark").first).to_be_attached()
    expect(page.locator(".chip.mark").first).to_contain_text("earmark")


# ---------------------------------------------------------------- speakers
def _speaker_sessions(server, n=2):
    def ready():
        out = []
        for x in call(server, "/api/sessions"):
            d = call(server, f"/api/sessions/{x['id']}")
            if d.get("spk_status") == "done" and d.get("intel_status") == "done" and len({g.get("spk") for g in d["segments"]}) >= 2:
                out.append(d)
        return out if len(out) >= n else None
    if not ready():                                     # record another conversation while "away"
        call(server, "/api/_fake/presence", "POST", {"present": False})
        wait_for(lambda: not call(server, "/api/status")["pendant"]["connected"], 30, "pendant out of range")
        call(server, "/api/_fake/offline", "POST", {"seconds": 20})
        call(server, "/api/_fake/presence", "POST", {"present": True})
        call(server, "/api/sync", "POST", {})
    return wait_for(ready, 60, f"{n} conversations with two voices")


def test_name_speakers_fix_lines_and_recognise_them_later(page: Page, server):
    a, b = _speaker_sessions(server)[:2]
    page.goto(page.url.split("#")[0] + f"#/c/{a['id']}/transcript")
    rows = page.locator("#spkPanel .spk-row")
    expect(rows).to_have_count(2)
    # the wearer is the loudest voice: offered as "probably you"
    expect(rows.nth(0)).to_contain_text("is this you?")
    rows.nth(0).locator("[data-yes]").click()
    expect(page.locator(".spk-chip").first).to_contain_text("Me")
    # name the other voice
    inp = rows.nth(1).locator(".spk-name")
    inp.fill("Rahul")
    inp.press("Enter")
    expect(page.locator(".spk-chip", has_text="Rahul").first).to_be_visible()
    expect(page.locator("#namesNote")).to_be_visible()
    # correct one line by hand: click the first chip (selects that block), give it to Rahul
    page.locator(".spk-chip").first.click()
    expect(page.locator("#assign")).to_be_visible()
    page.fill("#asName", "Rahul")
    page.click("#asLines")
    expect(page.locator("#assign")).to_be_hidden()
    d = call(server, f"/api/sessions/{a['id']}")
    rahul = next(x["label"] for x in d["speakers"] if x["name"] == "Rahul")
    assert d["segments"][0]["spk"] == rahul
    # another conversation now recognises both voices
    page.goto(page.url.split("#")[0] + f"#/c/{b['id']}/transcript")
    expect(page.locator("#spkPanel .spk-tag", has_text="Recognised")).to_have_count(2)
    expect(page.locator(".spk-chip", has_text="Rahul").first).to_be_visible()
    # Voices in Settings: rename and forget
    page.goto(page.url.split("#")[0] + "#/settings/voices")
    expect(page.locator("#voices .vrow")).to_have_count(2)
    v = page.locator("#voices .vname").nth(1)
    v.fill("Rahul K")
    v.press("Enter")
    expect(page.locator("#voices .vname").nth(1)).to_have_value("Rahul K")
    assert any(x["name"] == "Rahul K" for x in call(server, f"/api/sessions/{b['id']}")["speakers"])
    page.once("dialog", lambda dlg: dlg.accept())
    page.locator("#voices [data-forget]").nth(1).click()
    expect(page.locator("#voices .vrow")).to_have_count(1)
    assert not any(x["name"] == "Rahul K" for x in call(server, f"/api/sessions/{b['id']}")["speakers"])


def test_split_a_line_between_two_speakers(page: Page, server):
    a = _speaker_sessions(server, 1)[0]
    n0 = len(a["segments"])
    page.goto(page.url.split("#")[0] + f"#/c/{a['id']}/transcript")
    line = page.locator(".tline").nth(1)
    line.hover()
    line.locator(".splitbtn").click()
    expect(page.locator(".split-hint")).to_be_visible()
    page.locator(".tline.splitting .w", has_text="send").click()
    expect(page.locator("#assign")).to_be_visible()
    d = call(server, f"/api/sessions/{a['id']}")
    assert len(d["segments"]) == n0 + 1
    assert d["segments"][1]["text"].endswith("will") and d["segments"][2]["text"].startswith("send")
    page.fill("#asName", "Priya")
    page.click("#asLines")
    expect(page.locator(".spk-chip", has_text="Priya")).to_be_visible()


# ---------------------------------------------------------------- phone access
def _remote(server, path, method="GET", body=None, cookie=None, form=None):
    """A request as it arrives through Tailscale serve: proxied, with another host name."""
    headers = {"Host": "mac.tail1234.ts.net", "X-Forwarded-For": "100.101.102.103", "X-Forwarded-Proto": "https",
               "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)"}
    data = None
    if form is not None:
        data = form.encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if cookie:
        headers["Cookie"] = cookie
    req = urllib.request.Request(server + path, data=data, method=method, headers=headers)

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    opener = urllib.request.build_opener(NoRedirect)
    try:
        r = opener.open(req, timeout=10)
        return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def test_phone_must_pair_and_can_be_removed(server):
    st, _, body = _remote(server, "/api/status")
    assert st == 401
    st, _, body = _remote(server, "/")
    assert st == 401 and b"6-digit code" in body
    # pairing codes can only be made on the Mac
    assert _remote(server, "/api/phone/code", "POST", {})[0] == 401
    code = call(server, "/api/phone/code", "POST", {})["code"]
    st, _, body = _remote(server, "/pair", "POST", form="code=000000" if code != "000000" else "code=111111")
    assert st == 400
    st, hdr, _ = _remote(server, "/pair", "POST", form=f"code={code}")
    assert st == 303
    cookie = hdr.get("set-cookie") or hdr.get("Set-Cookie")
    assert "HttpOnly" in cookie and "Secure" in cookie
    cookie = cookie.split(";")[0]
    assert _remote(server, "/api/status", cookie=cookie)[0] == 200
    assert _remote(server, "/pair", "POST", form=f"code={code}")[0] == 400        # one use only
    # a paired phone still cannot manage pairing
    assert _remote(server, "/api/phone", cookie=cookie)[0] == 403
    dev = call(server, "/api/phone")["devices"][0]
    assert dev["name"] == "iPhone"
    call(server, f"/api/phone/devices/{dev['id']}", "DELETE")
    assert _remote(server, "/api/status", cookie=cookie)[0] == 401


def test_phone_settings_and_audio_seek(page: Page, server):
    page.goto(page.url.split("#")[0] + "#/settings/phone")
    expect(page.locator("#phoneBox .pcard").first).to_be_visible()
    expect(page.locator("#phoneBox")).to_contain_text("Tailscale")
    sid = call(server, "/api/sessions")[0]["id"]
    req = urllib.request.Request(server + f"/api/sessions/{sid}/audio", headers={"Range": "bytes=0-99"})
    with urllib.request.urlopen(req, timeout=10) as r:          # iPhone Safari needs ranged audio to play and seek
        assert r.status == 206 and len(r.read()) == 100


# ---------------------------------------------------------------- the phone app
def _app_call(server, path, token=None, method="POST", body=None, raw=None, headers=None):
    h = {"Host": "mac.tail1234.ts.net", "X-Forwarded-For": "100.64.0.9"}
    h.update(headers or {})
    if token:
        h["Authorization"] = f"Bearer {token}"
    data = None
    if raw is not None:
        data = raw
        h["Content-Type"] = "application/octet-stream"
    elif body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(server + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def _opus_chunk(seconds: float):
    import opuslib
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from earmark import appsync, fake_pendant
    f = fake_pendant.fake()
    frames = [f.next_frame("offline") for _ in range(int(seconds * 50))]
    return appsync.pack_frames(frames)


def test_phone_app_pairs_uploads_and_takes_the_pendant(server):
    # pairing with a one-time code made on the Mac
    assert _app_call(server, "/api/app/heartbeat", body={})[0] == 401
    code = call(server, "/api/phone/code", "POST", {})["code"]
    st, r = _app_call(server, "/api/app/pair", body={"code": code, "name": "Pixel 9", "platform": "android"})
    assert st == 200 and r["token"]
    tok = r["token"]
    assert _app_call(server, "/api/app/pair", body={"code": code, "name": "x"})[0] == 400
    # the phone says it has the pendant: the Mac lets go and shows the phone's state
    st, r = _app_call(server, "/api/app/heartbeat", tok, body={"holds_pendant": True, "pendant_connected": True,
                                                                "battery": 71, "state": "recording", "session_seconds": 12})
    assert st == 200 and "settings" in r and r["last_seq"] == 0
    wait_for(lambda: (call(server, "/api/status")["pendant"].get("via") or "").startswith("Pixel 9"), 20, "Mac shows the phone holds the pendant")
    s = call(server, "/api/status")
    assert s["pendant"]["battery"] == 71 and s["phase"] in ("recording", "paused")
    # audio recorded on the phone becomes a conversation on the Mac
    n0 = len(call(server, "/api/sessions"))
    t0 = time.time() - 600
    st, r = _app_call(server, "/api/app/audio", tok, raw=_opus_chunk(8),
                      headers={"X-Earmark-Start": str(t0), "X-Earmark-Seq": "1", "X-Earmark-Codec": "21"})
    assert st == 200 and r["frames"] == 400
    # the same chunk again (a retry) is acknowledged and ignored
    st, r = _app_call(server, "/api/app/audio", tok, raw=_opus_chunk(8),
                      headers={"X-Earmark-Start": str(t0), "X-Earmark-Seq": "1", "X-Earmark-Codec": "21"})
    assert r.get("duplicate")
    # a later chunk after a long break closes the first conversation
    _app_call(server, "/api/app/audio", tok, raw=_opus_chunk(4),
              headers={"X-Earmark-Start": str(t0 + 400), "X-Earmark-Seq": "2", "X-Earmark-Codec": "21"})
    ss = wait_for(lambda: [x for x in call(server, "/api/sessions") if x.get("source") == "phone"] or None, 30, "phone session")
    assert len(call(server, "/api/sessions")) > n0
    assert abs(ss[-1]["started_at"] - t0) < 2
    # earmark and pause from the phone's button
    st, r = _app_call(server, "/api/app/event", tok, body={"type": "earmark", "at": t0 + 3})
    assert st == 200
    st, r = _app_call(server, "/api/app/event", tok, body={"type": "pause"})
    assert r["paused"] is True
    _app_call(server, "/api/app/event", tok, body={"type": "resume"})
    # the phone lets go: the Mac takes the pendant back
    _app_call(server, "/api/app/heartbeat", tok, body={"holds_pendant": False})
    call(server, "/api/sync", "POST", {})
    try:
        wait_for(lambda: not call(server, "/api/status")["pendant"].get("via") and call(server, "/api/status")["pendant"]["connected"],
                 40, "Mac reconnects to the pendant")
    except AssertionError:
        st = call(server, "/api/status")
        raise AssertionError(f"phase={st['phase']} detail={st['detail']} pendant={st['pendant']} log={[x['msg'] for x in st['log'][:10]]}")
    # bad input is refused
    assert _app_call(server, "/api/app/audio", tok, raw=b"\x00\x05ab",
                     headers={"X-Earmark-Start": str(time.time()), "X-Earmark-Seq": "9"})[0] == 400
