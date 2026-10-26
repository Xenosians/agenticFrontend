"""Account settings use exact server receipts, with isolated APIs and no real sessions/mail."""
import os
from pathlib import Path
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST


def sessions():
    return [{"session_id": identity, "user_agent": label, "created_at": "2026-10-26T01:00:00Z",
             "last_seen_at": "2026-10-26T02:00:00Z", "expires_at": "2030-01-01T00:00:00Z",
             "revoked_at": None, "current": identity == "fixture-session"}
            for identity, label in (("fixture-session", "Current fixture browser"),
                                    ("other-session", "Other fixture browser"))]


class AccountSettingsTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.preferences = {"preferences": {"task_completed": True}}
        self.settings_status = 200
        self.save_receipt = None
        self.revoke_receipt = {"status": "revoked", "revoked_count": 1}
        self.session_rows = sessions()
        self.writes = []
        self.revocations = []
        self.pending = []
        self.hold_read = False
        self.hold_write = False
        self.hold_revoke = False
        self.owner = "fixture-owner"
        super().setUp()
        self.page.set_default_timeout(5000)

    def tearDown(self):
        for route in self.pending:
            route.abort()
        self.pending.clear()
        super().tearDown()

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        bundle = os.getenv("ACCOUNT_TEST_BUNDLE")
        if bundle and request.url.startswith(self.base + "/") and path == "/js/app.js":
            route.fulfill(content_type="application/javascript", body=Path(bundle).read_text())
            return
        if request.url.startswith(self.base + "/api/"):
            if path in {"/api/v1/auth/me", "/api/v1/auth/login"}:
                route.fulfill(json={"user": {"user_id": self.owner, "email": "owner@example.test",
                    "display_name": "Fixture Owner", "role": "user"},
                    "session_id": "fixture-session" if self.owner == "fixture-owner" else "new-session",
                    "csrf_token": "fixture-csrf"})
                return
            if path == "/api/v1/auth/logout":
                route.fulfill(json={"status": "logged_out"})
                return
            if path == "/api/v1/auth/preferences":
                if request.method == "PUT":
                    self.writes.append({"payload": request.post_data_json,
                                        "csrf": request.headers.get("x-csrf-token")})
                    if self.hold_write:
                        self.pending.append(route)
                        return
                    self.preferences = {"preferences": request.post_data_json}
                    route.fulfill(json=self.save_receipt if self.save_receipt is not None else self.preferences)
                elif self.hold_read:
                    self.pending.append(route)
                else:
                    route.fulfill(status=self.settings_status, json=self.preferences)
                return
            if path == "/api/v1/auth/sessions":
                route.fulfill(json={"sessions": self.session_rows})
                return
            if path == "/api/v1/auth/sessions/revoke-others":
                self.revocations.append({"method": request.method, "csrf": request.headers.get("x-csrf-token")})
                if self.hold_revoke:
                    self.pending.append(route)
                    return
                if self.revoke_receipt == {"status": "revoked", "revoked_count": 1}:
                    self.session_rows[1]["revoked_at"] = "2026-10-26T03:00:00Z"
                route.fulfill(json=self.revoke_receipt)
                return
            if path == "/api/v1/auth/sessions/other-session/revoke":
                self.revocations.append({"method": request.method, "csrf": request.headers.get("x-csrf-token")})
                route.fulfill(json={"status": "revoked", "session_id": "wrong-session"})
                return
        super().route(route)

    def open_account(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+k")
        self.page.locator(".command-center-row").filter(
            has=self.page.get_by_text("Account settings and sessions", exact=True)).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Account")
        expect(self.page.locator(".account-session-row")).to_have_count(2)

    def assert_safe(self):
        self.assertEqual(self.errors, [])
        self.assertEqual(self.submissions, [])

    def test_saved_preference_and_revocation_receipt_are_used(self):
        self.open_account()
        choice = self.page.get_by_role("checkbox", name="Task completion emails", exact=True)
        expect(choice).to_be_checked()
        choice.uncheck()
        self.page.get_by_role("button", name="Save notification setting", exact=True).click()
        expect(self.page.get_by_text("Notification setting saved.", exact=True)).to_be_visible()
        self.assertEqual(self.writes, [{"payload": {"task_completed": False}, "csrf": "fixture-csrf"}])
        self.page.get_by_role("button", name="Revoke other sessions", exact=True).click()
        expect(self.page.get_by_text("1 other session(s) revoked. This session stays signed in.", exact=True)).to_be_visible()
        expect(self.page.locator(".account-session-row").filter(has_text="Other fixture browser")).to_contain_text("Revoked")
        expect(self.page.locator(".account-session-row").filter(has_text="Current fixture browser")).to_contain_text("Current")
        self.assertEqual(self.revocations, [{"method": "POST", "csrf": "fixture-csrf"}])
        self.assert_safe()

    def test_unknown_preference_never_shows_a_default_choice(self):
        self.preferences = {"preferences": {"task_completed": "false"}}
        self.open_account()
        expect(self.page.locator(".account-notifications .account-error")).to_contain_text("could not be loaded")
        expect(self.page.get_by_role("checkbox", name="Task completion emails", exact=True)).to_have_count(0)
        self.assertEqual(self.writes, [])
        self.assert_safe()

    def test_pending_save_cannot_be_duplicated_or_reloaded(self):
        self.hold_write = True
        self.open_account()
        self.page.get_by_role("checkbox", name="Task completion emails", exact=True).uncheck()
        self.page.get_by_role("button", name="Save notification setting", exact=True).click()
        expect(self.page.get_by_role("button", name="Saving setting…", exact=True)).to_be_disabled()
        expect(self.page.get_by_role("button", name="Reload settings", exact=True)).to_be_disabled()
        self.page.get_by_role("button", name="Saving setting…", exact=True).dispatch_event("click")
        self.assertEqual(len(self.writes), 1)
        self.pending.pop().fulfill(json={"preferences": {"task_completed": False}})
        expect(self.page.get_by_text("Notification setting saved.", exact=True)).to_be_visible()
        self.assert_safe()

    def test_wrong_save_receipt_requires_readback_and_does_not_resend(self):
        self.save_receipt = {"preferences": {"task_completed": True}}
        self.open_account()
        self.page.get_by_role("checkbox", name="Task completion emails", exact=True).uncheck()
        self.page.get_by_role("button", name="Save notification setting", exact=True).click()
        expect(self.page.locator(".account-notifications .account-error")).to_contain_text("did not match")
        expect(self.page.get_by_text("Notification setting saved.", exact=True)).to_have_count(0)
        expect(self.page.get_by_role("button", name="Save notification setting", exact=True)).to_have_count(0)
        self.page.get_by_role("button", name="Reload settings", exact=True).click()
        expect(self.page.get_by_role("checkbox", name="Task completion emails", exact=True)).not_to_be_checked()
        self.assertEqual(len(self.writes), 1)
        self.assert_safe()

    def test_unconfirmed_bulk_revoke_requires_refresh_before_another_decision(self):
        self.revoke_receipt = {"status": "accepted", "revoked_count": 1}
        self.open_account()
        self.page.get_by_role("button", name="Revoke other sessions", exact=True).click()
        expect(self.page.locator(".account-session-panel .account-error")).to_contain_text("not confirmed")
        expect(self.page.get_by_role("button", name="Revoke other sessions", exact=True)).to_be_disabled()
        self.page.get_by_role("button", name="Revoke other sessions", exact=True).dispatch_event("click")
        self.assertEqual(len(self.revocations), 1)
        self.page.locator(".account-session-panel").get_by_role("button", name="Refresh", exact=True).click()
        expect(self.page.get_by_role("button", name="Revoke other sessions", exact=True)).to_be_enabled()
        self.assertEqual(len(self.revocations), 1)
        self.assert_safe()

    def test_wrong_single_session_receipt_does_not_claim_revoked(self):
        self.open_account()
        other = self.page.locator(".account-session-row").filter(has_text="Other fixture browser")
        other.get_by_role("button", name="Revoke", exact=True).click()
        expect(self.page.locator(".account-session-panel .account-error")).to_contain_text("not confirmed")
        expect(other.get_by_text("Revoked", exact=True)).to_have_count(0)
        self.assertEqual(len(self.revocations), 1)
        self.assert_safe()

    def test_old_owner_read_cannot_populate_a_new_session(self):
        self.hold_read = True
        self.open_account()
        self.assertEqual(len(self.pending), 1)
        self.page.locator(".account-view").get_by_role("button", name="Sign out", exact=True).click()
        expect(self.page.get_by_role("heading", name="Sign in", exact=True)).to_be_visible()
        self.owner = "second-owner"
        self.hold_read = False
        self.preferences = {"preferences": {"task_completed": False}}
        self.page.get_by_placeholder("you@example.com").fill("second@example.test")
        self.page.get_by_placeholder("Password", exact=True).fill("fixture-password")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Account")
        self.page.get_by_role("button", name="Reload settings", exact=True).click()
        expect(self.page.get_by_role("checkbox", name="Task completion emails", exact=True)).not_to_be_checked()
        self.pending.pop().fulfill(json={"preferences": {"task_completed": True}})
        expect(self.page.get_by_role("checkbox", name="Task completion emails", exact=True)).not_to_be_checked()
        self.assert_safe()

    def test_account_text_contrast_and_mobile_layout(self):
        self.open_account()
        expect(self.page.get_by_role("checkbox", name="Task completion emails", exact=True)).to_be_checked()
        for width in (1440, 390):
            self.page.set_viewport_size({"width": width, "height": 900})
            for selector in (".account-view .run-label", ".account-mail-choice span", ".account-setting-help"):
                self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5, (width, selector))
            self.assertFalse(self.page.evaluate("document.documentElement.scrollWidth > document.documentElement.clientWidth"))
        self.assert_safe()


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(AccountSettingsTests(name) for name in loader.getTestCaseNames(AccountSettingsTests)
                             if name in AccountSettingsTests.__dict__)


if __name__ == "__main__":
    unittest.main()
