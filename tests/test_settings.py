"""Settings: appearance, notifications and signed-in devices, saved only through the server.

Isolated fixture APIs; no real sessions, mail or storage. The base class fails any test that
writes browser storage or cookies, or breaks the production Content Security Policy.
"""
import os
from pathlib import Path
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST

DEFAULTS = {"task_completed": True, "theme": "dark", "accent": "mono", "pinned_views": ["knowledge", "operations"]}


def sessions():
    return [{"session_id": identity, "user_agent": label, "created_at": "2026-10-26T01:00:00Z",
             "last_seen_at": "2026-10-26T02:00:00Z", "expires_at": "2030-01-01T00:00:00Z",
             "revoked_at": None, "current": identity == "fixture-session"}
            for identity, label in (("fixture-session", "Current fixture browser"),
                                    ("other-session", "Other fixture browser"))]


class SettingsTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.preferences = {"preferences": dict(DEFAULTS)}
        self.settings_status = 200
        self.save_receipt = None
        self.save_status = 200
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
                    if self.save_status != 200:
                        route.fulfill(status=self.save_status, json={"error": "preferences_save_unconfirmed"})
                        return
                    saved = dict(self.preferences["preferences"])
                    saved.update(request.post_data_json)
                    self.preferences = {"preferences": saved}
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

    def open_settings(self, section=None):
        self.open_first_chat()
        self.page.locator(".sidebar-nav").get_by_role("button", name="Settings", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Settings")
        if section:
            self.open_section(section)

    def open_section(self, name):
        self.page.get_by_role("navigation", name="Settings sections", exact=True).get_by_role(
            "link", name=name, exact=True).click()
        expect(self.page.get_by_role("region", name=name)).to_be_visible()
        if name == "Signed-in devices":
            expect(self.page.locator(".account-session-row")).to_have_count(2)

    def root(self):
        return self.page.evaluate("[document.documentElement.dataset.theme, document.documentElement.dataset.accent]")

    def expect_root(self, theme, accent=None):
        # A locator assertion polls without evaluating strings, which the production CSP forbids.
        html = self.page.locator("html")
        expect(html).to_have_attribute("data-theme", theme)
        if accent:
            expect(html).to_have_attribute("data-accent", accent)

    def radio(self, group, name):
        return self.page.get_by_role("radiogroup", name=group, exact=True).get_by_role("radio", name=name, exact=True)

    def assert_safe(self):
        self.assertEqual(self.errors, [])
        self.assertEqual(self.submissions, [])

    def test_saved_appearance_is_painted_at_sign_in(self):
        self.preferences = {"preferences": {"task_completed": True, "theme": "light", "accent": "teal"}}
        self.open_first_chat()
        self.expect_root("light", "teal")
        self.assertEqual(self.writes, [])
        self.assert_safe()

    def test_theme_and_accent_save_only_what_changed(self):
        self.open_settings("Appearance")
        self.assertEqual(self.root(), ["dark", "mono"])
        self.radio("Theme", "Light").check()
        expect(self.page.get_by_text("Theme saved.", exact=True)).to_be_visible()
        self.radio("Accent", "Violet").check()
        expect(self.page.get_by_text("Accent saved.", exact=True)).to_be_visible()
        self.assertEqual(self.root(), ["light", "violet"])
        self.assertEqual(self.writes, [{"payload": {"theme": "light"}, "csrf": "fixture-csrf"},
                                       {"payload": {"accent": "violet"}, "csrf": "fixture-csrf"}])
        # The chosen theme repaints the workspace itself, not just the attribute.
        self.assertNotEqual(self.page.evaluate("getComputedStyle(document.body).backgroundColor"), "rgb(13, 13, 13)")
        self.assert_safe()

    def test_match_system_follows_the_operating_system(self):
        self.page.emulate_media(color_scheme="light")
        self.open_settings("Appearance")
        self.radio("Theme", "Match system").check()
        expect(self.page.get_by_text("Theme saved.", exact=True)).to_be_visible()
        self.assertEqual(self.root()[0], "light")
        self.page.emulate_media(color_scheme="dark")
        self.expect_root("dark")
        self.assert_safe()

    def test_an_unconfirmed_theme_reverts_and_requires_a_reload(self):
        self.save_status = 503
        self.open_settings("Appearance")
        # click, not check(): the refused save reverts the choice, which check() would retry against.
        self.radio("Theme", "Light").click()
        expect(self.page.locator(".settings-banner .settings-error")).to_contain_text("not confirmed")
        self.assertEqual(self.root(), ["dark", "mono"])
        expect(self.page.get_by_role("radiogroup", name="Theme", exact=True)).to_have_count(1)
        expect(self.radio("Theme", "Light")).to_be_disabled()
        self.assertEqual(len(self.writes), 1)
        self.save_status = 200
        self.page.get_by_role("button", name="Reload settings", exact=True).click()
        expect(self.radio("Theme", "Dark")).to_be_checked()
        self.assert_safe()

    def test_saved_preference_and_revocation_receipt_are_used(self):
        self.open_settings("Notifications")
        choice = self.page.get_by_role("switch", name="Task completion emails", exact=True)
        expect(choice).to_be_checked()
        choice.uncheck()
        expect(self.page.get_by_text("Notification setting saved.", exact=True)).to_be_visible()
        self.assertEqual(self.writes, [{"payload": {"task_completed": False}, "csrf": "fixture-csrf"}])
        self.open_section("Signed-in devices")
        self.page.get_by_role("button", name="Sign out other devices", exact=True).click()
        expect(self.page.get_by_text("1 other session(s) revoked. This session stays signed in.", exact=True)).to_be_visible()
        expect(self.page.locator(".account-session-row").filter(has_text="Other fixture browser")).to_contain_text("Revoked")
        expect(self.page.locator(".account-session-row").filter(has_text="Current fixture browser")).to_contain_text("This browser")
        self.assertEqual(self.revocations, [{"method": "POST", "csrf": "fixture-csrf"}])
        # With no other active device left, the action is no longer offered.
        expect(self.page.get_by_role("button", name="Sign out other devices", exact=True)).to_have_count(0)
        self.assert_safe()

    def test_unknown_preference_never_shows_a_default_choice(self):
        self.preferences = {"preferences": {"task_completed": "false", "theme": "dark", "accent": "mono"}}
        self.open_settings("Notifications")
        expect(self.page.locator(".settings-banner .settings-error")).to_contain_text("could not be loaded")
        expect(self.page.get_by_role("switch", name="Task completion emails", exact=True)).to_have_count(0)
        self.open_section("Appearance")
        expect(self.radio("Theme", "Dark")).to_be_disabled()
        self.assertEqual(self.writes, [])
        self.assert_safe()

    def test_pending_save_cannot_be_duplicated(self):
        self.hold_write = True
        self.open_settings("Appearance")
        self.radio("Accent", "Teal").check()
        expect(self.radio("Accent", "Rose")).to_be_disabled()
        self.radio("Accent", "Rose").dispatch_event("click")
        self.assertEqual(len(self.writes), 1)
        self.pending.pop().fulfill(json={"preferences": {"task_completed": True, "theme": "dark", "accent": "teal"}})
        expect(self.page.get_by_text("Accent saved.", exact=True)).to_be_visible()
        self.assertEqual(self.root(), ["dark", "teal"])
        self.assert_safe()

    def test_wrong_save_receipt_requires_readback_and_does_not_resend(self):
        self.save_receipt = {"preferences": {"task_completed": True, "theme": "dark", "accent": "mono"}}
        self.open_settings("Appearance")
        # click, not check(): the mismatched receipt reverts the choice.
        self.radio("Theme", "Light").click()
        expect(self.page.locator(".settings-banner .settings-error")).to_contain_text("did not match")
        expect(self.page.get_by_text("Theme saved.", exact=True)).to_have_count(0)
        self.assertEqual(self.root(), ["dark", "mono"])
        self.page.get_by_role("button", name="Reload settings", exact=True).click()
        expect(self.radio("Theme", "Light")).to_be_checked()
        self.assertEqual(len(self.writes), 1)
        self.assert_safe()

    def test_unconfirmed_bulk_revoke_requires_refresh_before_another_decision(self):
        self.revoke_receipt = {"status": "accepted", "revoked_count": 1}
        self.open_settings("Signed-in devices")
        self.page.get_by_role("button", name="Sign out other devices", exact=True).click()
        expect(self.page.locator(".account-session-panel .settings-error")).to_contain_text("not confirmed")
        expect(self.page.get_by_role("button", name="Sign out other devices", exact=True)).to_be_disabled()
        self.page.get_by_role("button", name="Sign out other devices", exact=True).dispatch_event("click")
        self.assertEqual(len(self.revocations), 1)
        self.page.get_by_role("region", name="Signed-in devices").get_by_role("button", name="Refresh", exact=True).click()
        expect(self.page.get_by_role("button", name="Sign out other devices", exact=True)).to_be_enabled()
        self.assertEqual(len(self.revocations), 1)
        self.assert_safe()

    def test_wrong_single_session_receipt_does_not_claim_revoked(self):
        self.open_settings("Signed-in devices")
        other = self.page.locator(".account-session-row").filter(has_text="Other fixture browser")
        other.get_by_role("button", name="Sign out Other fixture browser", exact=True).click()
        expect(self.page.locator(".account-session-panel .settings-error")).to_contain_text("not confirmed")
        expect(other.get_by_text("Revoked", exact=True)).to_have_count(0)
        self.assertEqual(len(self.revocations), 1)
        self.assert_safe()

    def test_old_owner_read_cannot_populate_a_new_session(self):
        self.hold_read = True
        # The held settings read keeps the network busy, so wait for content instead of idle.
        self.page.goto(self.base + "/")
        expect(self.page.get_by_text("First chat history", exact=True)).to_be_visible()
        self.assertEqual(len(self.pending), 1)
        self.page.locator(".sidebar-nav").get_by_role("button", name="Settings", exact=True).click()
        self.page.get_by_role("region", name="Profile").get_by_role("button", name="Sign out", exact=True).click()
        expect(self.page.get_by_role("heading", name="Sign in", exact=True)).to_be_visible()
        self.assertEqual(self.root(), ["dark", "mono"])
        self.owner = "second-owner"
        self.hold_read = False
        self.preferences = {"preferences": {"task_completed": False, "theme": "light", "accent": "rose"}}
        self.page.get_by_placeholder("you@example.com").fill("second@example.test")
        self.page.get_by_placeholder("Password", exact=True).fill("fixture-password")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        self.expect_root("light", "rose")
        # The first owner's read finishes late and must not repaint the second owner's workspace.
        self.pending.pop().fulfill(json={"preferences": {"task_completed": True, "theme": "dark", "accent": "teal"}})
        self.page.wait_for_timeout(200)
        self.assertEqual(self.root(), ["light", "rose"])
        self.assert_safe()

    def test_settings_text_contrast_and_mobile_layout_in_both_themes(self):
        self.open_settings("Appearance")
        texts = {"Profile": (".settings-section-heading p", ".settings-profile dt", ".settings-breadcrumb a",
                             ".settings-nav-item:not(.active)"),
                 "Appearance": (".settings-item-copy span", ".settings-choice span", ".settings-toggle small"),
                 "Notifications": (".settings-toggle small",),
                 "Signed-in devices": (".settings-row-copy span", ".settings-badge"),
                 "Services": (".settings-row-copy span", ".settings-badge")}
        # Contrast is read once colours have settled, not mid theme transition.
        self.page.emulate_media(reduced_motion="reduce")
        for theme in ("Dark", "Light"):
            self.open_section("Appearance")
            self.radio("Theme", theme).check()
            self.expect_root(theme.lower())
            for width in (1440, 390):
                self.page.set_viewport_size({"width": width, "height": 900})
                for section, selectors in texts.items():
                    self.open_section(section)
                    for selector in selectors:
                        self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5,
                                                (theme, width, section, selector))
                    self.assertFalse(self.page.evaluate(
                        "document.documentElement.scrollWidth > document.documentElement.clientWidth"),
                        (theme, width, section))
        self.assert_safe()


    # Settings as a full page (owner decision, 19 November 03:15 WIB): a section list on the left, a
    # breadcrumb, and flat label/description rows with the control on the right (the Hermes look).
    SECTIONS = ["Profile", "Appearance", "Notifications", "Signed-in devices", "Services"]

    def section_list(self):
        return self.page.get_by_role("navigation", name="Settings sections", exact=True)

    def test_settings_is_a_page_with_a_section_list_and_a_breadcrumb(self):
        self.open_settings()
        sections = self.section_list()
        expect(sections).to_be_visible()
        links = sections.get_by_role("link")
        self.assertEqual([text.strip() for text in links.all_inner_texts()], self.SECTIONS)
        # Every entry is a Lucide icon and a name; the first is the current one.
        expect(sections.locator("svg.icon")).to_have_count(len(self.SECTIONS))
        expect(links.first).to_have_attribute("aria-current", "page")
        breadcrumb = self.page.get_by_role("navigation", name="Breadcrumb", exact=True)
        expect(breadcrumb).to_have_text("Settings›Profile")
        expect(self.page.get_by_role("region", name="Profile")).to_be_visible()
        # The list sits to the left of the page, top-aligned with it.
        nav, page = sections.bounding_box(), self.page.locator(".settings-page").bounding_box()
        self.assertLessEqual(nav["x"] + nav["width"], page["x"] + 1)
        self.assertLess(abs(nav["y"] - page["y"]), 4)
        self.assertEqual(self.errors, [])

    def test_choosing_a_section_shows_it_alone_and_names_it_in_the_breadcrumb(self):
        self.open_settings()
        self.section_list().get_by_role("link", name="Signed-in devices", exact=True).click()
        expect(self.page.get_by_role("navigation", name="Breadcrumb", exact=True)).to_have_text(
            "Settings›Signed-in devices")
        expect(self.page.get_by_role("region", name="Signed-in devices")).to_be_visible()
        expect(self.page.get_by_role("region", name="Profile")).to_have_count(0)
        expect(self.page.get_by_role("radiogroup", name="Theme", exact=True)).to_have_count(0)
        expect(self.section_list().get_by_role("link", name="Signed-in devices", exact=True)).to_have_attribute(
            "aria-current", "page")
        expect(self.section_list().get_by_role("link", name="Profile", exact=True)).not_to_have_attribute(
            "aria-current", "page")
        # The breadcrumb's first step goes back to the first section.
        self.page.get_by_role("navigation", name="Breadcrumb", exact=True).get_by_role(
            "link", name="Settings", exact=True).click()
        expect(self.page.get_by_role("region", name="Profile")).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_a_section_is_flat_rows_with_the_control_on_the_right(self):
        self.open_settings()
        self.section_list().get_by_role("link", name="Appearance", exact=True).click()
        section = self.page.get_by_role("region", name="Appearance")
        # Flat: no card around the section (Hermes separates rows by space and hairlines).
        self.assertEqual(section.evaluate("el => getComputedStyle(el).borderTopWidth"), "0px")
        for name in ("Theme", "Accent"):
            row = section.locator(".settings-item").filter(
                has=self.page.get_by_role("radiogroup", name=name, exact=True))
            label = row.locator(".settings-item-copy strong").bounding_box()
            control = row.get_by_role("radiogroup", name=name, exact=True).bounding_box()
            self.assertGreater(control["x"], label["x"] + label["width"], name)
            self.assertAlmostEqual(control["x"] + control["width"], section.bounding_box()["x"]
                                   + section.bounding_box()["width"], delta=2)
        self.assertEqual(self.errors, [])

    def test_the_service_status_link_opens_the_services_section(self):
        self.open_first_chat()
        self.page.locator(".statusbar").get_by_role("button", name="Services ready", exact=True).click()
        expect(self.page.get_by_role("region", name="Services")).to_be_visible()
        expect(self.section_list().get_by_role("link", name="Services", exact=True)).to_have_attribute(
            "aria-current", "page")
        self.assertEqual(self.errors, [])

    def test_the_account_row_opens_the_profile(self):
        self.open_settings("Services")
        self.page.get_by_role("button", name="Account settings", exact=True).click()
        expect(self.page.get_by_role("region", name="Profile")).to_be_visible()
        # The Settings row reopens the section the owner chose last.
        self.open_section("Notifications")
        self.page.locator(".sidebar-nav").get_by_role("button", name="Settings", exact=True).click()
        expect(self.page.get_by_role("region", name="Notifications")).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_on_a_phone_the_sections_are_a_row_above_the_page(self):
        self.page.set_viewport_size({"width": 390, "height": 844})
        self.open_settings()
        sections, page = self.section_list().bounding_box(), self.page.locator(".settings-page").bounding_box()
        self.assertLessEqual(sections["y"] + sections["height"], page["y"] + 1)
        self.assertFalse(self.page.evaluate("document.documentElement.scrollWidth > innerWidth"))
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(SettingsTests(name) for name in loader.getTestCaseNames(SettingsTests)
                             if name in SettingsTests.__dict__)


if __name__ == "__main__":
    unittest.main()
