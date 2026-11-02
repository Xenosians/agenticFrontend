"""The capabilities documentation page (FR-081): its own page, outside the workspace.

docs.html lists what Janus can do by the service it touches, read from the trusted
catalog for the signed-in user, with each service's setup state. It has no
workspace rail or chat; it opens from the workspace Help, and the workspace keeps
its own rail. A signed-out visitor is sent to sign in, never shown a guessed list.
Isolated HTTP fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_docs_page.py
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_capabilities_page import CAPABILITIES, INTEGRATIONS, ROLES
from test_statusbar import CONTRAST
from test_workspace_context import CATALOG


class DocsPageTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog.update(capabilities=copy.deepcopy(CAPABILITIES), specialist_roles=copy.deepcopy(ROLES))
        self.integrations = copy.deepcopy(INTEGRATIONS)
        self.signed_in = True
        self.mutations = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/api/"):
            if request.method != "GET":
                self.mutations.append(path)
            if path == "/api/v1/auth/me" and not self.signed_in:
                route.fulfill(status=401, json={"error": "unauthenticated"})
                return
            if path == "/api/v1/extensions":
                route.fulfill(json=self.catalog)
                return
            if path == "/api/v1/integrations":
                route.fulfill(json=self.integrations)
                return
        super().route(route)

    def open_docs(self):
        self.page.goto(self.base + "/docs.html", wait_until="networkidle")
        expect(self.page.get_by_role("heading", name="What Janus can do", exact=True)).to_be_visible()

    def group(self, name):
        return self.page.locator(".capability-group").filter(
            has=self.page.locator(".capability-group-name", has_text=name))

    def test_the_page_lists_operations_by_service_outside_the_workspace(self):
        self.open_docs()
        expect(self.page).to_have_title("Janus · Capabilities")
        expect(self.page.locator(".capability-group")).to_have_count(3)
        directory = self.group("Fixture directory")
        expect(directory.locator("summary")).to_contain_text("Needs setup")
        expect(directory.locator("summary")).to_contain_text("Missing FIXTURE_HOST, FIXTURE_BIND_PASSWORD")
        directory.locator("summary").click()
        expect(directory.locator(".capability-row")).to_have_count(3)
        expect(self.page.locator(".capability-summary")).to_have_text("5 operations · 2 need approval")
        # A documentation page: no workspace rail, chat list or composer.
        for selector in (".sidebar", ".rail-navigation", "#messageInput"):
            expect(self.page.locator(selector)).to_have_count(0)
        expect(self.page.get_by_role("link", name="Back to the workspace", exact=True)).to_have_attribute("href", "./")
        self.assertGreaterEqual(self.page.evaluate(CONTRAST, ".capability-group-meta"), 4.5)
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.errors, [])

    def test_search_finds_operations_and_services(self):
        self.open_docs()
        search = self.page.get_by_role("searchbox", name="Search capabilities", exact=True)
        search.fill("identity")
        expect(self.page.locator(".capability-row:visible")).to_have_count(2)
        search.fill("no such fixture operation")
        expect(self.page.locator(".capability-empty")).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_a_signed_out_visitor_is_sent_to_sign_in(self):
        self.signed_in = False
        self.page.goto(self.base + "/docs.html", wait_until="networkidle")
        expect(self.page.locator(".docs-signed-out")).to_contain_text("Sign in to see what Janus can do for you")
        expect(self.page.get_by_role("link", name="Sign in", exact=True)).to_have_attribute("href", "./")
        expect(self.page.locator(".capability-group")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_the_workspace_help_links_to_the_page(self):
        self.open_first_chat()
        self.page.get_by_role("menubar", name="Application menu").get_by_role("menuitem", name="Help", exact=True).click()
        self.page.get_by_role("menu", name="Help", exact=True).get_by_role(
            "menuitem", name="Capabilities documentation", exact=True).click()
        expect(self.page).to_have_url(self.base + "/docs.html")
        expect(self.page.get_by_role("heading", name="What Janus can do", exact=True)).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_narrow_screens_do_not_overflow(self):
        self.page.set_viewport_size({"width": 390, "height": 760})
        self.open_docs()
        self.group("Fixture directory").locator("summary").click()
        overflow = self.page.evaluate("() => document.documentElement.scrollWidth > window.innerWidth")
        self.assertFalse(overflow)
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(DocsPageTests(name) for name in loader.getTestCaseNames(DocsPageTests)
                             if name in DocsPageTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
