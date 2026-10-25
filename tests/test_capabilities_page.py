"""The Capabilities page (FR-081, NFR-036): Hermes-style catalog of governed ITSM operations.

Every row comes from the trusted capability catalog: grouped by owning specialist,
labelled read or change, and marked when a change needs approval. Isolated HTTP
fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_capabilities_page.py
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_workspace_context import CATALOG


def capability(name, owners, effect, approval, description):
    return {"id": name, "description": description, "effect": effect, "permission": effect,
            "risk": "read" if effect == "read" else "write", "requires_approval": approval,
            "resource_type": "fixture", "agent_names": owners, "grounded_arguments": [],
            "required_arguments": [], "parameters": {}, "success_continuations": []}


CAPABILITIES = [
    capability("fixture_identity_create", ["fixture-identity"], "mutation", True, "Create a directory identity."),
    capability("fixture_identity_read", ["fixture-identity"], "read", False, "Read a directory identity."),
    capability("fixture_issue_create", ["fixture-issues", "fixture-provider-issues"], "mutation", True,
               "Create an issue in a project."),
    capability("fixture_unowned", [], "read", False, "A capability no specialist serves."),
    # Long enough to wrap at phone width, so the break rule is exercised.
    capability("fixture_directory_group_membership_bulk_reconcile", ["fixture-identity"], "read", False,
               "Compare directory group membership in bulk."),
]
ROLES = [
    {"id": "fixture-identity", "description": "Directory accounts.", "local_model": "fixture-local"},
    {"id": "fixture-issues", "description": "Issue tracking.", "local_model": "fixture-local"},
    {"id": "fixture-provider-issues", "description": "Provider issues.", "local_model": "fixture-local"},
]


class CapabilitiesPageTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog.update(capabilities=copy.deepcopy(CAPABILITIES), specialist_roles=copy.deepcopy(ROLES))
        self.mutations = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        if urlparse(request.url).path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            if request.method == "GET":
                route.fulfill(json=self.catalog)
            else:
                self.mutations.append(request.post_data_json)
                route.fulfill(status=500, json={"detail": "unexpected fixture mutation"})
            return
        super().route(route)

    def open_capabilities(self):
        self.open_first_chat()
        self.page.locator(".sidebar").get_by_role("button", name="Capabilities", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Capabilities")

    def row(self, name):
        return self.page.locator(".capability-row").filter(
            has=self.page.get_by_text(name, exact=True))

    def test_operations_are_grouped_by_specialist_with_effect_and_approval(self):
        self.open_capabilities()
        identity = self.page.locator(".capability-group").filter(
            has=self.page.get_by_role("heading", name="fixture-identity", exact=True))
        expect(identity.locator(".capability-row")).to_have_count(3)
        create = self.row("fixture_identity_create")
        expect(create).to_contain_text("Change")
        expect(create).to_contain_text("Needs approval")
        read = self.row("fixture_identity_read")
        expect(read).to_contain_text("Read")
        expect(read).not_to_contain_text("Needs approval")
        # A shared operation is listed under every specialist that serves it.
        expect(self.row("fixture_issue_create")).to_have_count(2)
        # Nothing serves this one, so it is not offered as a workspace operation.
        expect(self.row("fixture_unowned")).to_have_count(0)
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_search_filters_by_name_description_and_specialist(self):
        self.open_capabilities()
        search = self.page.get_by_role("searchbox", name="Search capabilities", exact=True)
        search.fill("directory")
        expect(self.page.locator(".capability-row")).to_have_count(3)
        search.fill("provider-issues")
        expect(self.page.locator(".capability-row")).to_have_count(1)
        search.fill("no such fixture operation")
        expect(self.page.locator(".capability-row")).to_have_count(0)
        expect(self.page.locator(".capability-empty")).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_counts_summarise_the_catalog(self):
        self.open_capabilities()
        summary = self.page.locator(".capability-summary")
        # Distinct operations; one is served by two specialists and listed twice.
        expect(summary).to_contain_text("4 operations")
        expect(summary).to_contain_text("3 specialists")
        expect(summary).to_contain_text("2 need approval")
        expect(self.page.locator(".capability-row")).to_have_count(5)
        expect(self.row("fixture_issue_create").first).to_contain_text("Also served by fixture-provider-issues")
        # Secondary text stays readable against the near-black page (WCAG AA, 4.5:1).
        contrast = self.page.evaluate("""() => ['.developer-view-header p', '.capability-copy span'].map((selector) => {
            const channel = (value) => { value /= 255; return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4; };
            const luminance = (color) => {
                const [r, g, b] = color.match(/[0-9.]+/g).map(Number);
                return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
            };
            const node = document.querySelector(selector);
            const style = getComputedStyle(node);
            const text = luminance(style.color) * Number(style.opacity);
            const page = luminance(getComputedStyle(document.body).backgroundColor);
            return (Math.max(text, page) + 0.05) / (Math.min(text, page) + 0.05);
        })""")
        self.assertTrue(all(ratio >= 4.5 for ratio in contrast), contrast)
        self.assertEqual(self.errors, [])

    def test_palette_and_narrow_screens_reach_the_page(self):
        self.page.set_viewport_size({"width": 390, "height": 760})
        self.open_first_chat()
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Capabilities")
        self.page.keyboard.press("Enter")
        expect(self.page.locator(".workspace-title h1")).to_have_text("Capabilities")
        expect(self.row("fixture_identity_create")).to_be_visible()
        overflow = self.page.evaluate("() => document.documentElement.scrollWidth > window.innerWidth")
        self.assertFalse(overflow)
        # Operation names wrap only after an underscore, never mid-word; the
        # long fixture name must actually wrap here for this to mean anything.
        breaks = self.page.evaluate("""() => [...document.querySelectorAll('.capability-copy strong')].flatMap((node) => {
            const text = node.textContent, range = document.createRange(), result = [];
            const tops = [...text].map((_, index) => {
                const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
                let offset = index, current = walker.nextNode();
                while (offset >= current.length) { offset -= current.length; current = walker.nextNode(); }
                range.setStart(current, offset); range.setEnd(current, offset + 1);
                return Math.round(range.getBoundingClientRect().top);
            });
            for (let index = 1; index < text.length; index++) {
                if (tops[index] > tops[index - 1]) result.push(text[index - 1]);
            }
            return result;
        })""")
        self.assertTrue(breaks, "the long fixture name did not wrap at phone width")
        self.assertTrue(all(char == "_" for char in breaks), breaks)
        self.assertEqual(self.errors, [])

    def test_sidebar_marks_only_the_page_in_view(self):
        # The open chat stays marked as current, but the full highlight
        # belongs to the page in view; elsewhere the chat row is quieter.
        self.open_capabilities()
        nav = self.page.locator(".sidebar").get_by_role("button", name="Capabilities", exact=True)
        expect(nav).to_have_attribute("aria-current", "page")
        chat = self.page.locator(".chat-nav-main").filter(has_text="First fixture chat")
        expect(chat).to_have_attribute("aria-current", "true")
        backgrounds = self.page.evaluate("""() => ['.nav-item.active', '.chat-nav-main.active']
            .map((selector) => getComputedStyle(document.querySelector(selector)).backgroundColor)""")
        self.assertNotEqual(backgrounds[0], backgrounds[1], backgrounds)
        self.page.locator(".sidebar").get_by_role("button", name="Chat", exact=True).click()
        expect(chat).to_have_attribute("aria-current", "page")
        self.assertEqual(self.errors, [])

    def test_unavailable_catalog_is_stated_not_hidden(self):
        self.catalog = {"detail": "fixture outage"}
        self.open_first_chat()
        self.page.locator(".sidebar").get_by_role("button", name="Capabilities", exact=True).click()
        expect(self.page.locator(".capability-empty")).to_be_visible()
        expect(self.page.locator(".capability-row")).to_have_count(0)
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(CapabilitiesPageTests(name) for name in loader.getTestCaseNames(CapabilitiesPageTests)
                             if name in CapabilitiesPageTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
