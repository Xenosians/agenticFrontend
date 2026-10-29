"""Sign-in and registration: verification is a timed step of registration, held by the server.

Isolated fixtures only; no real accounts or mail. The browser keeps nothing: the
fixture server's verification cookie is the only state, as with the backend.
"""
import json
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST


class AuthScreenTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.signed_in = False
        self.pending = None  # Server-side verification step for this browser.
        self.wait = 2
        self.resends = []
        self.login_posts = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if not request.url.startswith(self.base + "/api/v1/auth/"):
            super().route(route)
            return
        if path == "/api/v1/auth/me":
            if self.signed_in:
                super().route(route)
            else:
                route.fulfill(status=401, json={"error": "authentication_required"})
        elif path == "/api/v1/auth/register":
            self.pending = {"status": "pending", "resend_after_seconds": self.wait, "email_hint": "n•••@example.test"}
            route.fulfill(status=201, json={"user": {"user_id": "new-owner", "email": "new@example.test"}, "verification_required": True,
                                            "mail_delivery": "sent", **{k: v for k, v in self.pending.items()
                                                                       if k != "status"}})
        elif path == "/api/v1/auth/login":
            self.login_posts.append(request.post_data_json)
            self.pending = {"status": "pending", "resend_after_seconds": 0, "email_hint": "n•••@example.test"}
            route.fulfill(status=403, json={"error": "email_not_verified", "resend_after_seconds": 0,
                                            "email_hint": "n•••@example.test"})
        elif path == "/api/v1/auth/verification":
            if self.pending is None:
                route.fulfill(status=404, json={"error": "verification_not_pending",
                                                "message": "No account is waiting for verification in this browser.",
                                                "retryable": False})
            else:
                route.fulfill(json=self.pending)
        elif path == "/api/v1/auth/resend-verification":
            self.resends.append(request.post_data or "")
            self.pending = {**self.pending, "resend_after_seconds": 2 * self.wait}
            route.fulfill(status=202, json={"status": "sent", "mail_delivery": "sent",
                                            "resend_after_seconds": 2 * self.wait,
                                            "email_hint": "n•••@example.test"})
        else:
            route.fulfill(status=404, json={"error": "unexpected_fixture_request"})

    def open_sign_in(self):
        self.page.goto(self.base + "/", wait_until="networkidle")
        expect(self.page.get_by_role("heading", name="Sign in", exact=True)).to_be_visible()

    def register(self):
        self.page.get_by_role("button", name="Create account", exact=True).click()
        self.page.get_by_label("Display name").fill("New Owner")
        self.page.get_by_label("Email").fill("new@example.test")
        self.page.get_by_label("Password").fill("correct horse battery staple")
        self.page.get_by_role("button", name="Register", exact=True).click()
        expect(self.page.get_by_role("heading", name="Verify your email", exact=True)).to_be_visible()

    def assert_nothing_stored(self):
        stored = self.page.evaluate("[localStorage.length, sessionStorage.length, document.cookie]")
        self.assertEqual(stored, [0, 0, ""])

    def test_sign_in_offers_no_resend(self):
        self.open_sign_in()
        expect(self.page.get_by_role("button", name="Resend verification email")).to_have_count(0)
        expect(self.page.get_by_text("Resend verification")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_registration_waits_then_resends_once_with_a_longer_wait(self):
        self.open_sign_in()
        self.register()
        expect(self.page.get_by_text("n•••@example.test")).to_be_visible()
        resend = self.page.get_by_role("button", name="Resend verification email", exact=True)
        expect(resend).to_be_disabled()
        expect(self.page.locator(".auth-countdown")).to_contain_text("2 s")
        expect(resend).to_be_enabled(timeout=4000)
        resend.click()
        expect(self.page.locator(".auth-notice")).to_contain_text("new verification email was sent")
        expect(resend).to_be_disabled()
        expect(self.page.locator(".auth-countdown")).to_contain_text("4 s")
        self.assertEqual([json.loads(body or "{}") for body in self.resends], [{}])  # Cookie-bound: no address sent.
        self.assert_nothing_stored()
        self.assertEqual(self.errors, [])

    def test_reload_resumes_the_server_wait_instead_of_restarting_it(self):
        self.open_sign_in()
        self.register()
        self.page.reload(wait_until="networkidle")
        expect(self.page.get_by_role("heading", name="Verify your email", exact=True)).to_be_visible()
        expect(self.page.get_by_role("button", name="Resend verification email", exact=True)).to_be_disabled()
        self.assert_nothing_stored()

    def test_unverified_sign_in_opens_the_verification_step(self):
        self.open_sign_in()
        self.page.get_by_label("Email").fill("new@example.test")
        self.page.get_by_label("Password").fill("correct horse battery staple")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        expect(self.page.get_by_role("heading", name="Verify your email", exact=True)).to_be_visible()
        expect(self.page.get_by_role("button", name="Resend verification email", exact=True)).to_be_enabled()
        self.page.get_by_role("button", name="Back to sign in", exact=True).click()
        expect(self.page.get_by_role("heading", name="Sign in", exact=True)).to_be_visible()
        expect(self.page.get_by_role("button", name="Resend verification email")).to_have_count(0)

    def test_malformed_success_does_not_claim_a_verification_email_was_sent(self):
        self.wait = 0
        self.open_sign_in()
        self.register()
        self.page.route("**/api/v1/auth/resend-verification", lambda route: route.fulfill(status=202, json={}))
        self.page.get_by_role("button", name="Resend verification email", exact=True).click()
        expect(self.page.locator(".auth-error")).to_contain_text("outcome was not confirmed")
        expect(self.page.locator(".auth-notice")).to_have_count(0)

    def test_malformed_registration_does_not_claim_an_account_was_created(self):
        self.open_sign_in()
        self.page.route("**/api/v1/auth/register", lambda route: route.fulfill(status=201, json={}))
        self.page.get_by_role("button", name="Create account", exact=True).click()
        self.page.get_by_label("Display name").fill("New Owner")
        self.page.get_by_label("Email").fill("new@example.test")
        self.page.get_by_label("Password").fill("correct horse battery staple")
        self.page.get_by_role("button", name="Register", exact=True).click()
        expect(self.page.locator(".auth-error")).to_contain_text("Account creation was not confirmed")
        expect(self.page.get_by_role("heading", name="Verify your email", exact=True)).to_have_count(0)

    def test_auth_text_is_readable_at_desktop_and_phone_widths(self):
        self.open_sign_in()
        self.register()
        for width in (1440, 390):
            self.page.set_viewport_size({"width": width, "height": 900})
            for selector in (".auth-subtitle", ".auth-countdown", ".auth-actions button"):
                self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5, (width, selector))
                size = self.page.evaluate("s => parseFloat(getComputedStyle(document.querySelector(s)).fontSize)",
                                          selector)
                self.assertGreaterEqual(size, 12, (width, selector))
            self.assertFalse(self.page.evaluate(
                "document.documentElement.scrollWidth > document.documentElement.clientWidth"))


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(AuthScreenTests(name) for name in loader.getTestCaseNames(AuthScreenTests)
                              if name in AuthScreenTests.__dict__)


if __name__ == "__main__":
    unittest.main()
