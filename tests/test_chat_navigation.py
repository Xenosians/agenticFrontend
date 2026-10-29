"""Browser regressions for the built frontend, using isolated HTTP fixtures.

No application service, credentials or ITSM provider is used. Run after rebuilding
the frontend with a Python runtime that has Playwright Chromium installed:
    python tests/test_chat_navigation.py
"""

import functools
import copy
import hashlib
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import unittest
import uuid
from urllib.parse import urlparse, parse_qs

from playwright.sync_api import expect, sync_playwright

# Records localStorage/sessionStorage writes, script cookie writes and IndexedDB
# opens. Server cookies arrive as HttpOnly Set-Cookie headers and are not seen here.
BROWSER_WRITE_RECORDER = """(() => {
  const writes = [];
  Object.defineProperty(globalThis, "__browserWrites", {value: writes});
  for (const name of ["setItem", "removeItem", "clear"]) {
    const original = Storage.prototype[name];
    Storage.prototype[name] = function (...args) {
      writes.push(name + ":" + (this === globalThis.localStorage ? "localStorage" : "sessionStorage"));
      return original.apply(this, args);
    };
  }
  const cookie = Object.getOwnPropertyDescriptor(Document.prototype, "cookie");
  Object.defineProperty(Document.prototype, "cookie", {configurable: true,
    get() { return cookie.get.call(this); },
    set(value) { writes.push("cookie"); cookie.set.call(this, value); }});
  if (globalThis.indexedDB) {
    const open = indexedDB.open.bind(indexedDB);
    indexedDB.open = (...args) => { writes.push("indexedDB"); return open(...args); };
  }
})();"""


class QuietStaticHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


class ChatNavigationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        public = Path(__file__).resolve().parents[1] / "public"
        handler = functools.partial(QuietStaticHandler, directory=str(public))
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        cls.server.daemon_threads = True
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(headless=True)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.context = self.browser.new_context()
        self.context.add_init_script("window.WebSocket = undefined;")
        # The frontend keeps nothing in the browser: record every storage or
        # cookie write so each test can prove there were none.
        self.context.add_init_script(BROWSER_WRITE_RECORDER)
        self.page = self.context.new_page()
        self.pending_history = []
        self.submissions = []
        self.errors = []
        self.omit_workflow_ack_once = False
        self.intent_slots = {}
        self.intent_posts = []
        self.lose_reservation_once = False
        self.intent_ack_status = 200
        self.page.on("pageerror", lambda error: self.errors.append(str(error)))
        self.page.route("**/*", self.route)

    def tearDown(self):
        for route in self.pending_history:
            route.abort()
        try:
            if not self.page.is_closed() and self.page.url.startswith(self.base):
                self.assertEqual(self.page.evaluate("globalThis.__browserWrites || []"), [],
                                 "the frontend wrote to browser storage or cookies")
        finally:
            self.context.close()

    def route(self, route):
        request = route.request
        url = urlparse(request.url)
        path = url.path
        if request.url.startswith(self.base + "/") and not path.startswith("/api/"):
            if path == "/config.js":
                route.fulfill(content_type="application/javascript", body=(
                    "window.AGENTIC_CONFIG = Object.freeze({backendBaseUrl:"
                    + json.dumps(self.base) + ",pollIntervalMs:10,requiredOperations:true});"
                ))
            else:
                route.continue_()
            return

        # Unexpected origins never reach a real API, even if config regresses.
        if not request.url.startswith(self.base + "/api/"):
            route.abort()
            return

        if path.startswith("/api/v1/submission-intents"):
            self.route_intent(route)
            return

        if path == "/api/v1/auth/me":
            data = {
                "user": {"user_id": "fixture-owner", "email": "owner@example.test",
                         "display_name": "Fixture Owner", "role": "user"},
                "session_id": "fixture-session", "csrf_token": "fixture-csrf",
            }
        elif path == "/api/health":
            data = {"status": "ok", "ai_service": {"reachable": True, "healthy": True, "ready": True}}
        elif path == "/api/v1/integrations":
            data = {"integrations": []}
        elif path == "/api/v1/extensions":
            data = {"resources": [], "selected": {}, "role_assignments": {}, "local_profiles": [],
                    "capabilities": [
                        {"id": "fixture_identity_create", "agent_names": ["fixture-identity"],
                         "grounded_arguments": ["login"], "success_continuations": ["fixture_issue_create"]},
                        {"id": "fixture_identity_read", "agent_names": ["fixture-identity"],
                         "grounded_arguments": ["login"], "success_continuations": []},
                        {"id": "fixture_issue_create", "agent_names": ["fixture-issues", "fixture-provider-issues"],
                         "grounded_arguments": ["project", "issue_type"], "success_continuations": []},
                        {"id": "fixture_unowned", "agent_names": [], "grounded_arguments": []},
                    ]}
        elif path == "/api/v1/chats":
            data = {"chats": [
                {"chat_id": "fixture-first", "title": "First fixture chat"},
                {"chat_id": "fixture-second", "title": "Second fixture chat"},
            ]}
        elif path == "/api/v2/chats/fixture-first/history":
            data = {"messages": [{"role": "user", "content": "First chat history"}]}
        elif path == "/api/v2/chats/fixture-second/history":
            self.pending_history.append(route)
            self.page.evaluate("globalThis.navigationFixturePending = true")
            return  # Explicitly delayed until the test releases navigation.
        elif path == "/api/v1/jobs" and request.method == "POST":
            payload = request.post_data_json
            self.submissions.append(payload)
            data = {"job_id": "fixture-job", "status": "completed", "submission_id": payload["submission_id"]}
            if "workflow_contract" in payload:
                if self.omit_workflow_ack_once:
                    self.omit_workflow_ack_once = False
                else:
                    data["workflow_contract"] = payload["workflow_contract"]
                    data["workflow_contract_hash"] = "f" * 64
        elif path == "/api/v2/jobs/fixture-job":
            data = {"contract_version": 2, "job_id": "fixture-job", "status": "completed",
                    "result": {"answer": "Fixture job response"}}
            if self.submissions and "workflow_contract" in self.submissions[-1]:
                data["workflow_contract"] = self.submissions[-1]["workflow_contract"]
                data["workflow_contract_hash"] = "f" * 64
        else:
            route.fulfill(status=404, json={"error": "unexpected_fixture_request"})
            return
        route.fulfill(json=data)

    def route_intent(self, route):
        """Independent HTTP fixture for the server coordination contract.

        Actual storage/receipt authority is tested against SurrealDB in Phoenix;
        this fixture lets the built UI exercise lost replies and reloads.
        """
        request = route.request
        query = parse_qs(urlparse(request.url).query)
        body = request.post_data_json if request.method == "POST" else {
            "kind": query.get("kind", [None])[0], "target_id": query.get("target_id", [None])[0]}
        kind, target = body["kind"], body["target_id"]
        owner = getattr(self, "owner", "fixture-owner")
        key = (owner, kind, target)
        current = self.intent_slots.get(key)
        slot = lambda row: {"schema": "submission-intent-slot.v1", "kind": kind,
                            "target_id": target, "intent": copy.deepcopy(row)}
        if request.method == "GET":
            route.fulfill(json=slot(current))
            return
        self.intent_posts.append(copy.deepcopy(body))
        if urlparse(request.url).path.endswith("/acknowledge"):
            if not current or current["intent_id"] != body["intent_id"]:
                route.fulfill(status=409, json={"error": "submission_intent_conflict"})
                return
            if self.intent_ack_status != 200:
                route.fulfill(status=self.intent_ack_status, json={"error": "submission_intent_unavailable"})
                return
            current["state"] = "acknowledged"
            current["receipt"] = {"submission_id": current["request"]["submission_id"]}
            route.fulfill(json=slot(current))
            return
        proposal, expected = body["request"], body["expected_id"]
        if current and current["state"] == "pending":
            original = {k: v for k, v in current["request"].items() if k != "submission_id"}
            if original != proposal or current["previous_id"] != expected:
                route.fulfill(status=409, json={"error": "submission_intent_conflict"})
                return
        elif (current and current["intent_id"] != expected) or (not current and expected is not None):
            route.fulfill(status=409, json={"error": "submission_intent_conflict"})
            return
        elif len(json.dumps(proposal.get("workflow_contract"), ensure_ascii=False).encode()) > 32768:
            # Phoenix refuses an encoded contract above 32 KiB before storing anything.
            route.fulfill(status=422, json={"error": "invalid_submission_intent"})
            return
        else:
            identity = uuid.uuid4().hex
            payload = {**copy.deepcopy(proposal), "submission_id": identity if kind == "learning" else str(uuid.uuid4())}
            current = {"intent_id": identity, "previous_id": expected, "kind": kind, "target_id": target,
                       "state": "pending", "request": payload, "receipt": None,
                       "context": copy.deepcopy(self.records[target]) if kind == "workflow" else None,
                       "request_sha256": hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()}
            self.intent_slots[key] = current
        if self.lose_reservation_once:
            self.lose_reservation_once = False
            route.abort()
        else:
            route.fulfill(json=slot(current))

    def open_first_chat(self):
        self.page.goto(self.base + "/", wait_until="networkidle")
        expect(self.page.get_by_text("First chat history", exact=True)).to_be_visible()

    def begin_second_chat(self):
        self.page.locator(".chat-nav-title", has_text="Second fixture chat").click()
        # The navigation request is captured by the local fixture handler.
        self.page.wait_for_function("globalThis.navigationFixturePending === true")
        self.assertEqual(len(self.pending_history), 1)

    def release_second_chat(self):
        self.pending_history.pop().fulfill(json={
            "messages": [{"role": "user", "content": "Second chat history"}],
        })
        expect(self.page.get_by_text("Second chat history", exact=True)).to_be_visible()

    def test_navigation_blocks_keyboard_and_button_without_losing_draft(self):
        self.open_first_chat()
        composer = self.page.locator("#messageInput")
        composer.fill("Draft for the selected chat")
        self.begin_second_chat()

        composer.press("Enter")
        # Also exercise the handler itself, independently of native disabled UI.
        self.page.get_by_role("button", name="Send message", exact=True).dispatch_event("click")
        expect(composer).to_have_value("Draft for the selected chat")
        expect(self.page.get_by_role("button", name="Send message", exact=True)).to_be_disabled()
        self.assertEqual(self.submissions, [])

        self.release_second_chat()
        send = self.page.get_by_role("button", name="Send message", exact=True)
        expect(send).to_be_enabled()
        send.click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(len(self.submissions), 1)
        self.assertEqual(self.submissions[0]["chat_id"], "fixture-second")
        self.assertEqual(self.submissions[0]["message"], "Draft for the selected chat")
        self.assertEqual(self.errors, [])

    def lose_acknowledgement_in_second_chat(self, message, operations=None):
        """Sends from the second chat, loses its acknowledgement and returns to the first."""
        def lose_once(route):
            self.submissions.append(route.request.post_data_json)
            self.page.unroute("**/api/v1/jobs", lose_once)
            route.abort()  # The POST may have been saved; its answer never arrives.

        self.open_first_chat()
        self.begin_second_chat()
        self.release_second_chat()
        if operations:
            operations()
        self.page.route("**/api/v1/jobs", lose_once)
        self.page.locator("#messageInput").fill(message)
        self.page.get_by_role("button", name="Send message", exact=True).click()
        expect(self.page.get_by_role("button", name="Check saved submission", exact=True)).to_be_visible()
        self.page.locator(".chat-nav-title", has_text="First fixture chat").click()
        expect(self.page.get_by_text("First chat history", exact=True)).to_be_visible()
        return self.submissions[0]

    def check_saved_submission(self, first):
        """Reopening never sends; only the explicit check re-sends the server-held request."""
        check = self.page.get_by_role("button", name="Check saved submission", exact=True)
        expect(check).to_be_visible()
        self.assertEqual(self.submissions, [first])
        check.click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [first, first])

    def test_navigation_preserves_recovery_of_pinned_submission(self):
        first = self.lose_acknowledgement_in_second_chat("Previously submitted fixture request")
        self.begin_second_chat()
        self.release_second_chat()
        self.check_saved_submission(first)
        self.assertEqual(self.errors, [])

    def add_required_identity(self):
        self.page.get_by_role("button", name="Required operations", exact=True).click()
        operation = self.page.get_by_role("combobox", name="Required operation", exact=True)
        operation.select_option("fixture_identity_create")
        self.page.get_by_role("textbox", name="Exact login", exact=True).fill(" Exact account ")
        self.page.get_by_role("button", name="Add required operation", exact=True).click()
        expect(self.page.locator(".required-operation-target")).to_have_text("login:  Exact account ")

    def test_reviewed_operations_and_dependencies_survive_keyboard_submission(self):
        self.open_first_chat()
        self.add_required_identity()
        operation = self.page.get_by_role("combobox", name="Required operation", exact=True)
        self.assertEqual(operation.locator('option[value="fixture_identity_read"]').count(), 0)
        self.assertEqual(operation.locator('option[value="fixture_unowned"]').count(), 0)
        operation.select_option("fixture_issue_create")
        self.page.get_by_role("textbox", name="Exact project", exact=True).fill("ALPHA")
        self.page.get_by_role("textbox", name="Exact issue_type", exact=True).fill("Task")
        self.page.get_by_role("combobox", name="Success dependency", exact=True).select_option("step_1")
        self.page.get_by_role("button", name="Add required operation", exact=True).click()
        expect(self.page.locator(".required-operations-summary .required-operation")).to_have_count(2)
        self.page.get_by_role("button", name="Remove fixture_identity_create", exact=True).click()
        expect(self.page.get_by_role("alert")).to_have_text("Remove the dependent operation first.")
        composer = self.page.locator("#messageInput")
        composer.fill("Create the specified identity and then the issue.")
        composer.press("Enter")
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        expected = {"version": 1, "steps": [
            {"id": "step_1", "capability": "fixture_identity_create",
             "grounded_arguments": {"login": [" Exact account "]}, "after_success_of": None},
            {"id": "step_2", "capability": "fixture_issue_create",
             "grounded_arguments": {"project": ["ALPHA"], "issue_type": ["Task"]}, "after_success_of": "step_1"},
        ]}
        self.assertEqual(len(self.submissions), 1)
        self.assertEqual(self.submissions[0]["workflow_contract"], expected)
        self.page.get_by_role("button", name="Completed", exact=True).click()
        expect(self.page.locator(".required-operations-review .required-operation")).to_have_count(2)
        expect(self.page.get_by_text("login:  Exact account ", exact=True)).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_operation_drafts_do_not_leak_into_another_chat(self):
        self.open_first_chat()
        self.add_required_identity()
        self.begin_second_chat()
        self.release_second_chat()
        expect(self.page.get_by_role("button", name="Required operations", exact=True)).to_be_visible()
        self.page.locator("#messageInput").fill("A separate request")
        self.page.get_by_role("button", name="Send message", exact=True).click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertNotIn("workflow_contract", self.submissions[0])
        self.assertEqual(self.errors, [])

    def test_missing_contract_ack_retains_original_submission_for_explicit_recovery(self):
        self.open_first_chat()
        self.add_required_identity()
        self.omit_workflow_ack_once = True
        self.page.locator("#messageInput").fill("Create the reviewed identity")
        self.page.get_by_role("button", name="Send message", exact=True).click()
        recover = self.page.get_by_role("button", name="Check saved submission", exact=True)
        expect(recover).to_be_visible()
        self.assertEqual(len(self.submissions), 1)
        recover.click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(len(self.submissions), 2)
        self.assertEqual(self.submissions[0], self.submissions[1])
        self.assertEqual(self.errors, [])

    def test_a_request_refused_before_admission_is_released_and_reported(self):
        self.open_first_chat()
        self.page.route("**/api/v1/jobs", self.refuse_before_admission)
        self.page.locator("#messageInput").fill("A request Phoenix refuses")
        self.page.get_by_role("button", name="Send message", exact=True).click()
        expect(self.page.get_by_text("Request could not be completed.", exact=True)).to_be_visible()
        expect(self.page.get_by_text("The request was rejected.", exact=False)).to_be_visible()
        expect(self.page.get_by_role("button", name="Check saved submission", exact=True)).to_have_count(0)
        self.page.unroute("**/api/v1/jobs", self.refuse_before_admission)
        self.page.locator("#messageInput").fill("A corrected request")
        self.page.get_by_role("button", name="Send message", exact=True).click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual([row["message"] for row in self.submissions],
                         ["A request Phoenix refuses", "A corrected request"])
        self.assertEqual(self.errors, [])

    def refuse_before_admission(self, route):
        """Phoenix's refusal of the exact reserved request releases its slot."""
        self.submissions.append(route.request.post_data_json)
        slot = next(row for row in self.intent_slots.values() if row["state"] == "pending")
        slot["state"], slot["receipt"] = "rejected", {"error": "chat_not_found"}
        route.fulfill(status=404, json={"error": "chat_not_found"})

    def test_submission_identity_is_allocated_by_the_server_without_browser_uuid(self):
        self.context.add_init_script("Object.defineProperty(globalThis.crypto, 'randomUUID', {value: undefined});")
        self.open_first_chat()
        composer = self.page.locator("#messageInput")
        composer.fill("  Keep this unsent request  ")
        self.page.get_by_role("button", name="Send message", exact=True).click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(len(self.submissions), 1)
        self.assertEqual(self.submissions[0]["submission_id"], next(iter(self.intent_slots.values()))["request"]["submission_id"])
        self.assertEqual(self.errors, [])

    def test_a_reload_after_a_lost_acknowledgement_restores_identity_without_sending(self):
        first = self.lose_acknowledgement_in_second_chat("Request whose answer was lost")
        self.page.reload(wait_until="networkidle")
        self.begin_second_chat()
        self.release_second_chat()
        expect(self.page.get_by_role("button", name="Check saved submission", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [first])
        self.page.get_by_role("button", name="Check saved submission", exact=True).click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [first, first])
        self.assertEqual(self.errors, [])

    def test_lost_reservation_reply_survives_reload_without_dispatch(self):
        self.open_first_chat()
        self.lose_reservation_once = True
        self.page.locator("#messageInput").fill("Read a reviewed inventory")
        self.page.get_by_role("button", name="Send message", exact=True).click()
        expect(self.page.get_by_text("No new request was sent.", exact=False)).to_be_visible()
        original = copy.deepcopy(next(iter(self.intent_slots.values()))["request"])
        self.assertEqual(self.submissions, [])
        self.page.reload(wait_until="networkidle")
        check = self.page.get_by_role("button", name="Check saved submission", exact=True)
        expect(check).to_be_visible()
        self.assertEqual(self.submissions, [])
        check.click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [original])

    def test_oversized_required_operations_keep_the_message_without_posting(self):
        self.open_first_chat()
        self.page.get_by_role("button", name="Required operations", exact=True).click()
        self.page.get_by_role("combobox", name="Required operation", exact=True).select_option("fixture_identity_create")
        self.page.get_by_role("textbox", name="Exact login", exact=True).fill("\n".join(["界" * 1024] * 16))
        self.page.get_by_role("button", name="Add required operation", exact=True).click()
        composer = self.page.locator("#messageInput")
        composer.fill("Keep this message while I revise the exact targets")
        composer.press("Enter")
        expect(composer).to_have_value("Keep this message while I revise the exact targets")
        expect(self.page.get_by_text(
            "No new request was sent. The server refused this request as invalid. Review it before sending.",
            exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.intent_slots, {})
        self.assertEqual(self.errors, [])

    def test_recovery_and_delayed_ack_preserve_an_independent_composer_draft(self):
        held = []

        def interrupt_then_hold(route):
            self.submissions.append(route.request.post_data_json)
            if len(self.submissions) == 1:
                route.abort()  # Simulate an acknowledgement lost after POST.
            else:
                held.append(route)

        self.open_first_chat()
        self.page.route("**/api/v1/jobs", interrupt_then_hold)
        composer = self.page.locator("#messageInput")
        composer.fill("The originally prepared request")
        self.page.get_by_role("button", name="Send message", exact=True).click()
        recover = self.page.get_by_role("button", name="Check saved submission", exact=True)
        expect(recover).to_be_visible()
        composer.fill("My independently typed next request")
        recover.click()
        self.page.wait_for_function("document.querySelector('.composer-hint').textContent.includes('Submitting request')")
        expect(composer).to_have_value("My independently typed next request")
        self.assertEqual(len(held), 1)
        composer.fill("A newer draft while recovery is pending")
        request = self.submissions[-1]
        held.pop().fulfill(json={"job_id": "fixture-job", "status": "completed",
                                "submission_id": request["submission_id"]})
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        expect(composer).to_have_value("A newer draft while recovery is pending")
        self.assertEqual(len(self.submissions), 2)
        self.assertEqual(self.submissions[0], self.submissions[1])
        self.assertEqual(self.errors, [])

    def test_delayed_submission_ack_does_not_clear_a_newer_draft(self):
        held = []

        def hold(route):
            self.submissions.append(route.request.post_data_json)
            held.append(route)

        self.open_first_chat()
        self.page.route("**/api/v1/jobs", hold)
        composer = self.page.locator("#messageInput")
        composer.fill("The request being prepared")
        composer.press("Enter")
        expect(composer).to_have_value("")
        self.assertEqual(len(held), 1)
        composer.fill("A newer draft while the first response is pending")
        held.pop().fulfill(json={"job_id": "fixture-job", "status": "completed",
                                "submission_id": self.submissions[0]["submission_id"]})
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        expect(composer).to_have_value("A newer draft while the first response is pending")
        self.assertEqual(len(self.submissions), 1)
        self.assertEqual(self.errors, [])

    def test_enter_before_the_next_frame_still_clears_the_sent_draft(self):
        self.open_first_chat()
        composer = self.page.locator("#messageInput")
        # Input and Enter in one task: no frame renders the typed text before
        # the request consumes it (a paste-and-send on a busy page).
        composer.evaluate("""element => {
            element.value = "Sent before the next frame";
            element.dispatchEvent(new Event("input", {bubbles: true}));
            element.dispatchEvent(new KeyboardEvent("keydown", {key: "Enter", bubbles: true, cancelable: true}));
        }""")
        expect(composer).to_have_value("")
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual([s["message"] for s in self.submissions], ["Sent before the next frame"])
        expect(composer).to_have_value("")
        self.assertEqual(self.errors, [])

    def test_the_composer_never_covers_the_approval_controls(self):
        proposal = {"tool": "fixture_identity_create", "approval_id": "fixture-approval",
                    "arguments": {"login": "fixture.user", "department": "IT"}}
        decisions = []

        def submit(route):
            payload = route.request.post_data_json
            self.submissions.append(payload)
            route.fulfill(json={"job_id": "fixture-job", "status": "waiting_approval",
                                "submission_id": payload["submission_id"]})

        def job(route):
            if route.request.method == "POST" and route.request.url.endswith("/approve"):
                decisions.append(route.request.post_data_json)
                route.fulfill(json={"contract_version": 2, "job_id": "fixture-job", "status": "completed",
                                    "result": {"answer": "Fixture approval executed"}})
            else:
                route.fulfill(json={"contract_version": 2, "job_id": "fixture-job", "status": "waiting_approval",
                                    "proposed_tool": proposal, "result": {"answer": "Approval required"}})

        self.page.set_viewport_size({"width": 1440, "height": 720})
        self.open_first_chat()
        self.page.route("**/api/v1/jobs", submit)
        self.page.route("**/api/v2/jobs/fixture-job**", job)
        composer = self.page.locator("#messageInput")
        composer.fill("Create the fixture identity")
        composer.press("Enter")
        approve = self.page.get_by_role("button", name="Approve action", exact=True)
        approve.scroll_into_view_if_needed()
        topmost = approve.evaluate("""button => {
            const box = button.getBoundingClientRect();
            const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
            return hit === button ? "button" : (hit && hit.className) || "nothing";
        }""")
        self.assertEqual(topmost, "button", "another element covers the Approve action button")
        approve.click(timeout=5000)
        expect(self.page.get_by_text("Fixture approval executed", exact=True)).to_be_visible()
        self.assertEqual(decisions, [{"approval_id": "fixture-approval"}])
        self.assertEqual(self.errors, [])

    def test_recovery_keeps_the_exact_saved_operations_instead_of_building_another_request(self):
        first = self.lose_acknowledgement_in_second_chat("Previously reviewed request", self.add_required_identity)
        self.assertIn("workflow_contract", first)
        self.begin_second_chat()
        self.release_second_chat()
        self.check_saved_submission(first)
        self.assertEqual(self.errors, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
