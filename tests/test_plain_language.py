"""Each view says what it is once, in words a user of the product uses.

The header names the view; the page itself explains it, once. Product text
never names implementation parts (framework, server, internal guards or
contracts), and no view repeats a list that another view owns.
Isolated HTTP fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_plain_language.py
"""
import copy
import re
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_capabilities_page import CAPABILITIES, INTEGRATIONS, ROLES
from test_workspace_context import CATALOG

# Implementation names and internal vocabulary that mean nothing to a person using the product.
INTERNAL = re.compile(r"\b(Phoenix|Karax|SemanticGuard|ToolGateway|durable|harness(es)?|owner-scoped|"
                      r"frontend-visible|backend mailer|governed|orchestration|[a-z]+(-[a-z]+)*\.v\d)\b")
VIEWS = ("Chat", "Search", "Capabilities", "Knowledge", "Operations", "System")


class PlainLanguageTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog.update(capabilities=copy.deepcopy(CAPABILITIES), specialist_roles=copy.deepcopy(ROLES),
                            connections=[{"id": "rag", "state": "ready", "contract": "owner-retrieval.v1"},
                                         {"id": "n8n", "state": "prepared", "contract": "governed-workflow.v1"}])
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/api/"):
            if path == "/api/v1/extensions" and request.method == "GET":
                route.fulfill(json=self.catalog)
                return
            if path == "/api/v1/integrations":
                route.fulfill(json=INTEGRATIONS)
                return
        super().route(route)

    def open_view(self, name):
        if name != "Chat":
            self.page.locator(".sidebar").get_by_role("button", name=name, exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text(name)

    def visible_text(self):
        return self.page.locator(".workspace").inner_text()

    def test_no_view_names_implementation_parts(self):
        self.open_first_chat()
        for name in VIEWS:
            with self.subTest(view=name):
                self.open_view(name)
                self.page.wait_for_timeout(150)
                found = sorted({match.group(0) for match in INTERNAL.finditer(self.visible_text())})
                self.assertEqual(found, [], f"{name} shows internal names")
        self.assertEqual(self.errors, [])

    def test_the_header_does_not_repeat_the_page_description(self):
        self.open_first_chat()
        for name in VIEWS:
            with self.subTest(view=name):
                self.open_view(name)
                # The header names the view; the page explains it once.
                expect(self.page.locator(".workspace-title > span:not(.workspace-chat-title)")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_settings_show_resources_once_and_no_internal_catalogs(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        rail = self.page.locator(".plugin-installed")
        expect(rail.locator(".installed-item")).to_have_count(2)
        expect(rail.locator(".plugin-installed-header")).to_contain_text("2")
        expect(rail.locator(".installed-item").filter(has_text="Fixture provider model")).to_have_count(1)
        expect(rail.locator(".installed-item").filter(has_text="Fixture runbooks")).to_have_count(1)
        # The one in use is marked where it is listed, not listed again.
        expect(rail.locator(".installed-item.in-use")).to_have_count(2)
        # The marker is readable: no row's status line is cut short.
        clipped = rail.locator(".installed-item span:not(.installed-icon)").evaluate_all(
            "nodes => nodes.filter((node) => node.scrollWidth > node.clientWidth + 1).map((node) => node.innerText)")
        self.assertEqual(clipped, [])
        for tab in ("Public", "Personal", "Data & automation"):
            with self.subTest(tab=tab):
                self.page.locator(".plugin-tabs").get_by_role("button", name=tab, exact=True).click()
                self.page.wait_for_timeout(150)
                text = self.page.locator(".plugin-library-page").inner_text()
                found = sorted({match.group(0) for match in INTERNAL.finditer(text)})
                self.assertEqual(found, [], f"{tab} shows internal names")
                # The capability list lives on the Capabilities page, not repeated here.
                self.assertNotIn("Developer capabilities", text)
                self.assertNotIn("fixture_identity_create", text)
                # Internal connection contracts are not shown as if they were things to connect.
                self.assertNotIn("Automation connections", text)
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(PlainLanguageTests(name) for name in loader.getTestCaseNames(PlainLanguageTests)
                             if name in PlainLanguageTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
