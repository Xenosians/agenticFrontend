"""Browser regressions for the built frontend, using isolated HTTP fixtures.

No application service, credentials or ITSM provider is used. Run after rebuilding
the frontend with a Python runtime that has Playwright Chromium installed:
    python tests/test_chat_navigation.py
"""

import functools
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect, sync_playwright


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
        self.page = self.context.new_page()
        self.pending_history = []
        self.submissions = []
        self.errors = []
        self.omit_workflow_ack_once = False
        self.page.on("pageerror", lambda error: self.errors.append(str(error)))
        self.page.route("**/*", self.route)

    def tearDown(self):
        for route in self.pending_history:
            route.abort()
        self.context.close()

    def route(self, route):
        request = route.request
        url = urlparse(request.url)
        path = url.path
        if request.url.startswith(self.base + "/") and not path.startswith("/api/"):
            if path == "/config.js":
                route.fulfill(content_type="application/javascript", body=(
                    "window.AGENTIC_CONFIG = Object.freeze({backendBaseUrl:"
                    + json.dumps(self.base) + ",pollIntervalMs:10});"
                ))
            else:
                route.continue_()
            return

        # Unexpected origins never reach a real API, even if config regresses.
        if not request.url.startswith(self.base + "/api/"):
            route.abort()
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

    def test_navigation_preserves_recovery_of_pinned_submission(self):
        identity = "62bb7d94-4b65-44cc-8bd1-b01b61241c17"
        record = {"version": 1, "backend": self.base, "owner": "fixture-owner",
                  "chat_id": "fixture-second", "submission_id": identity,
                  "message": "Previously submitted fixture request"}
        key = "janus.pending-submission.v1:" + json.dumps(
            [self.base, "fixture-owner", "fixture-second"], separators=(",", ":"))
        self.context.add_init_script(
            f"sessionStorage.setItem({json.dumps(key)}, {json.dumps(json.dumps(record))});")
        self.open_first_chat()
        self.begin_second_chat()
        self.assertEqual(self.submissions, [])
        self.release_second_chat()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [{"chat_id": "fixture-second", "message": record["message"],
                                             "submission_id": identity}])
        self.assertIsNone(self.page.evaluate("key => sessionStorage.getItem(key)", key))
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
        self.assertEqual(self.page.evaluate("Object.keys(sessionStorage).filter(k => k.startsWith('janus.pending-submission.v1:')).length"), 1)
        recover.click()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(len(self.submissions), 2)
        self.assertEqual(self.submissions[0], self.submissions[1])
        self.assertEqual(self.page.evaluate("Object.keys(sessionStorage).filter(k => k.startsWith('janus.pending-submission.v1:')).length"), 0)
        self.assertEqual(self.errors, [])

    def test_recovery_keeps_the_exact_saved_operations_instead_of_building_another_request(self):
        identity = "1ab9024f-9bd4-421b-912c-38d73b71f084"
        workflow = {"version": 1, "steps": [{"id": "first", "capability": "fixture_issue_create",
                    "grounded_arguments": {"project": [" Exact project "]}, "after_success_of": None}]}
        record = {"version": 1, "backend": self.base, "owner": "fixture-owner", "chat_id": "fixture-second",
                  "submission_id": identity, "message": "Previously reviewed request", "workflow_contract": workflow}
        key = "janus.pending-submission.v1:" + json.dumps(
            [self.base, "fixture-owner", "fixture-second"], separators=(",", ":"))
        self.context.add_init_script(
            f"sessionStorage.setItem({json.dumps(key)}, {json.dumps(json.dumps(record))});")
        self.open_first_chat()
        self.begin_second_chat()
        self.release_second_chat()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [{"chat_id": "fixture-second", "message": record["message"],
                                           "submission_id": identity, "workflow_contract": workflow}])
        self.assertIsNone(self.page.evaluate("key => sessionStorage.getItem(key)", key))
        self.assertEqual(self.errors, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
