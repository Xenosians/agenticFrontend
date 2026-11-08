"""Temporary password hand-over: the person who asked for an approved account
reveals its temporary password once, inside Janus, after confirming their own
password. The new person's mailbox does not exist yet, so nothing is mailed.

Isolated HTTP fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_credential_handover.py
"""
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST

CREDENTIAL = "0123456789abcdef0123456789abcdef"
SECRET = "Fixture-Temporary-Secret!42"


class CredentialHandoverTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.reveal_requests = []
        self.reveal_answers = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/api/"):
            if path == "/api/v2/chats/fixture-first/history":
                route.fulfill(json={"messages": [
                    {"role": "user", "content": "First chat history", "job_id": "fixture-job", "status": "completed"},
                    {"role": "assistant", "content": "Fixture job response", "job_id": "fixture-job",
                     "status": "completed", "credential_handover": {"credential_id": CREDENTIAL}},
                ]})
                return
            if path == f"/api/v2/jobs/fixture-job/credentials/{CREDENTIAL}/reveal" and request.method == "POST":
                self.reveal_requests.append({"body": request.post_data_json,
                                             "csrf": request.headers.get("x-csrf-token")})
                status, body = self.reveal_answers.pop(0)
                route.fulfill(status=status, json=body)
                return
        super().route(route)

    def open_answer(self):
        self.open_first_chat()
        # The saved job read replaces the answer; the hand-over offer comes from history.
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()

    def start_reveal(self, password):
        self.page.get_by_role("button", name="Reveal temporary password", exact=True).click()
        reveal = self.page.get_by_role("button", name="Reveal", exact=True)
        expect(reveal).to_be_disabled()
        self.page.get_by_label("Your Janus password", exact=True).fill(password)
        expect(reveal).to_be_enabled()
        reveal.click()

    def test_the_requester_reveals_the_temporary_password_once(self):
        self.reveal_answers.append((200, {
            "credential_id": CREDENTIAL, "temporary_password": SECRET, "must_change_at_first_sign_in": True,
            "subject": {"kind": "directory_account", "user_id": "jdoe", "email": "jdoe@itsm.test"}}))
        self.open_answer()
        toggle_contrast = self.page.evaluate(CONTRAST, ".credential-handover-toggle")
        self.assertGreaterEqual(toggle_contrast, 4.5)
        self.start_reveal("my own password")
        value = self.page.locator(".credential-handover-value")
        expect(value).to_have_text(SECRET)
        expect(self.page.locator(".credential-handover-secret")).to_contain_text("for jdoe")
        expect(self.page.locator(".credential-handover-secret")).to_contain_text("change it at first sign-in")
        self.assertGreaterEqual(self.page.evaluate(CONTRAST, ".credential-handover-value"), 4.5)
        self.assertEqual(self.reveal_requests, [{"body": {"password": "my own password"}, "csrf": "fixture-csrf"}])
        # Closing clears the password from the page; it is not offered again here.
        self.page.get_by_role("button", name="Done", exact=True).click()
        expect(value).to_have_count(0)
        expect(self.page.get_by_text(SECRET)).to_have_count(0)
        expect(self.page.locator(".credential-handover-notice")).to_have_text("Revealed once and closed.")
        self.assertEqual(self.errors, [])

    def test_a_wrong_password_or_a_used_credential_is_explained_and_nothing_is_shown(self):
        self.reveal_answers += [
            (401, {"error": "invalid_credentials"}),
            (410, {"error": "credential_already_revealed"}),
        ]
        self.open_answer()
        self.start_reveal("wrong")
        error = self.page.locator(".credential-handover-error")
        expect(error).to_have_text("That is not your Janus password.")
        expect(self.page.get_by_label("Your Janus password", exact=True)).to_have_value("")
        self.page.get_by_label("Your Janus password", exact=True).fill("my own password")
        self.page.get_by_role("button", name="Reveal", exact=True).click()
        expect(error).to_contain_text("already revealed")
        expect(self.page.locator(".credential-handover-value")).to_have_count(0)
        self.assertEqual(len(self.reveal_requests), 2)
        self.assertEqual(self.errors, [])

    def test_the_revealed_password_reads_unambiguously_on_desktop_and_phone(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.reveal_answers.append((200, {"credential_id": CREDENTIAL, "temporary_password": SECRET,
                                              "subject": {"kind": "directory_account", "user_id": "jdoe"}}))
            self.open_answer()
            self.start_reveal("my own password")
            value = self.page.locator(".credential-handover-value")
            expect(value).to_have_text(SECRET)
            # One line box: a wrapped secret is ambiguous at its hyphens.
            lines = value.evaluate("""(node) => {
                const range = document.createRange();
                range.selectNodeContents(node);
                return new Set([...range.getClientRects()].map((rect) => Math.round(rect.top))).size;
            }""")
            self.assertEqual(lines, 1, f"the password wraps at {width}px")
            panel = self.page.locator(".credential-handover-secret").bounding_box()
            self.assertLessEqual(panel["x"] + panel["width"], width, f"the panel overflows at {width}px")
            # Its copy action is told apart from the answer's own Copy.
            expect(self.page.get_by_role("button", name="Copy password", exact=True)).to_be_visible()
            self.page.reload(wait_until="networkidle")
        self.assertEqual(self.errors, [])

    def test_approving_an_account_offers_the_hand_over_without_a_reload(self):
        proposal = {"tool": "account_create", "approval_id": "fixture-approval",
                    "arguments": {"given_name": "Jo", "family_name": "Doe"}}
        approved = {"contract_version": 2, "job_id": "fixture-new", "status": "completed",
                    "proposed_tool": proposal,
                    "result": {"answer": "Corporate account jdoe was created.",
                               "approval_execution": {
                                   "approval_id": "fixture-approval", "protocol_status": "processed",
                                   "execution_status": "succeeded", "approval_status": "approved",
                                   "replayed": False, "error": None,
                                   "result": {"ok": True, "user_id": "jdoe", "credential_id": CREDENTIAL}}}}

        def submit(route):
            payload = route.request.post_data_json
            route.fulfill(json={"job_id": "fixture-new", "status": "waiting_approval",
                                "submission_id": payload["submission_id"]})

        def job(route):
            if route.request.method == "POST" and route.request.url.endswith("/approve"):
                route.fulfill(json=approved)
            elif route.request.method == "POST" and route.request.url.endswith("/reveal"):
                self.reveal_requests.append(route.request.post_data_json)
                route.fulfill(json={"credential_id": CREDENTIAL, "temporary_password": SECRET,
                                    "subject": {"kind": "directory_account", "user_id": "jdoe"}})
            else:
                route.fulfill(json={"contract_version": 2, "job_id": "fixture-new", "status": "waiting_approval",
                                    "proposed_tool": proposal, "result": {"answer": "Approval required"}})

        self.open_answer()
        self.page.route("**/api/v1/jobs", submit)
        self.page.route("**/api/v2/jobs/fixture-new**", job)
        composer = self.page.locator("#messageInput")
        composer.fill("Create an account for Jo Doe")
        composer.press("Enter")
        self.page.get_by_role("button", name="Approve action", exact=True).click()
        answer = self.page.locator(".message-row.assistant", has_text="Corporate account jdoe was created.")
        expect(answer.get_by_role("button", name="Reveal temporary password", exact=True)).to_be_visible()
        # Both answers offer their own; the new one reveals its own credential.
        expect(self.page.get_by_role("button", name="Reveal temporary password", exact=True)).to_have_count(2)
        answer.get_by_role("button", name="Reveal temporary password", exact=True).click()
        answer.get_by_label("Your Janus password", exact=True).fill("my own password")
        answer.get_by_role("button", name="Reveal", exact=True).click()
        expect(answer.locator(".credential-handover-value")).to_have_text(SECRET)
        self.assertEqual(self.reveal_requests, [{"password": "my own password"}])
        self.assertEqual(self.errors, [])

    def test_cancel_sends_nothing(self):
        self.open_answer()
        self.page.get_by_role("button", name="Reveal temporary password", exact=True).click()
        self.page.get_by_label("Your Janus password", exact=True).fill("typed but not sent")
        self.page.get_by_role("button", name="Cancel", exact=True).click()
        expect(self.page.get_by_label("Your Janus password", exact=True)).to_have_count(0)
        expect(self.page.get_by_role("button", name="Reveal temporary password", exact=True)).to_be_visible()
        self.assertEqual(self.reveal_requests, [])
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(CredentialHandoverTests(name)
                              for name in loader.getTestCaseNames(CredentialHandoverTests)
                              if name in CredentialHandoverTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
