"""The Capabilities page (FR-081, NFR-036): what Janus can do, by the service it touches.

Every row comes from the trusted capability catalog: grouped under the service
whose setup it needs, named in words with a one-line summary, labelled read or
change, and marked when a change needs approval. Groups start collapsed so the
page opens on the services and their setup; a search opens every matching group.
Isolated HTTP fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_capabilities_page.py
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST
from test_workspace_context import CATALOG


def capability(name, owners, effect, approval, description, provider="fixture-directory"):
    return {"id": name, "description": description, "effect": effect, "permission": effect,
            "risk": "read" if effect == "read" else "write", "requires_approval": approval,
            "resource_type": "fixture", "agent_names": owners, "grounded_arguments": [],
            "required_arguments": [], "parameters": {}, "success_continuations": [],
            "provider": provider}


CAPABILITIES = [
    capability("fixture_identity_create", ["fixture-identity"], "mutation", True,
               "Create a directory identity. Use only the fields the user supplied."),
    capability("fixture_identity_read", ["fixture-identity"], "read", False,
               "Read only, changes nothing: read a directory identity. Never changes it."),
    capability("fixture_issue_create", ["fixture-issues", "fixture-provider-issues"], "mutation", True,
               "Create an issue in a project.", provider="fixture-issues"),
    capability("fixture_unowned", [], "read", False, "A capability no specialist serves."),
    capability("fixture_workspace_list", ["fixture-identity"], "read", False, "List a workspace folder.",
               provider="fixture-local"),
    # Long enough to wrap at phone width, so the break rule is exercised.
    capability("fixture_directory_group_membership_bulk_reconcile", ["fixture-identity"], "read", False,
               "Compare directory group membership in bulk."),
]
# Setup readiness from the AI service's configuration (FR-081): never a provider check.
INTEGRATIONS = {"integrations": [
    {"id": "fixture-directory", "name": "Fixture directory", "kind": "provider", "state": "not_configured",
     "configured": False, "missing": ["FIXTURE_HOST", "FIXTURE_BIND_PASSWORD"], "mode": "read_write",
     "capabilities": ["fixture_identity_create", "fixture_identity_read",
                      "fixture_directory_group_membership_bulk_reconcile", "fixture_unowned"]},
    {"id": "fixture-issues", "name": "Fixture issues", "kind": "provider", "state": "simulated",
     "configured": False, "missing": [], "mode": "read_write", "capabilities": ["fixture_issue_create"]},
    {"id": "fixture-local", "name": "Fixture workspace", "kind": "local", "state": "configured",
     "configured": True, "missing": [], "mode": "read_write", "capabilities": ["fixture_workspace_list"]},
]}
ROLES = [
    {"id": "fixture-identity", "description": "Directory accounts.", "local_model": "fixture-local"},
    {"id": "fixture-issues", "description": "Issue tracking.", "local_model": "fixture-local"},
    {"id": "fixture-provider-issues", "description": "Provider issues.", "local_model": "fixture-local"},
]


class CapabilitiesPageTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog.update(capabilities=copy.deepcopy(CAPABILITIES), specialist_roles=copy.deepcopy(ROLES))
        self.integrations = copy.deepcopy(INTEGRATIONS)
        self.integration_status = 200
        self.mutations = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            if request.method == "GET":
                route.fulfill(json=self.catalog)
            else:
                self.mutations.append(request.post_data_json)
                route.fulfill(status=500, json={"detail": "unexpected fixture mutation"})
            return
        if path == "/api/v1/integrations" and request.url.startswith(self.base + "/api/"):
            if self.integration_status != 200:
                route.fulfill(status=self.integration_status, json={"error": "integration_status_unavailable"})
            else:
                route.fulfill(json=self.integrations)
            return
        super().route(route)

    def open_capabilities(self):
        self.open_first_chat()
        self.page.locator(".sidebar").get_by_role("button", name="Capabilities", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Capabilities")

    def group(self, name):
        return self.page.locator(".capability-group").filter(
            has=self.page.locator(".capability-group-name", has_text=name))

    def open_group(self, name):
        group = self.group(name)
        group.locator("summary").click()
        expect(group).to_have_attribute("open", "")
        return group

    def row(self, name):
        return self.page.locator(".capability-row").filter(
            has=self.page.get_by_text(name, exact=True))

    def test_operations_are_grouped_by_service_with_effect_and_approval(self):
        self.open_capabilities()
        expect(self.page.locator(".capability-group")).to_have_count(3)
        directory = self.group("Fixture directory")
        # The service shows its setup state and what it offers before it is opened.
        expect(directory.locator("summary")).to_contain_text("Needs setup")
        expect(directory.locator("summary")).to_contain_text("3 operations")
        expect(directory.locator("summary")).to_contain_text("1 needs approval")
        expect(directory).not_to_have_attribute("open", "")
        expect(directory.locator(".capability-row").first).to_be_hidden()
        self.open_group("Fixture directory")
        expect(directory.locator(".capability-row")).to_have_count(3)
        create = self.row("Fixture identity create")
        expect(create).to_contain_text("Change")
        expect(create).to_contain_text("Needs approval")
        read = self.row("Fixture identity read")
        expect(read).to_contain_text("Read")
        expect(read).not_to_contain_text("Needs approval")
        # A shared operation is listed once, under its service.
        issues = self.open_group("Fixture issues")
        expect(issues.locator(".capability-row")).to_have_count(1)
        expect(issues.locator("summary")).to_contain_text("Simulated")
        # Nothing serves this one, so it is not offered as a workspace operation.
        expect(self.page.get_by_text("Fixture unowned", exact=True)).to_have_count(0)
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_rows_show_a_one_line_summary_not_internal_names(self):
        self.open_capabilities()
        self.open_group("Fixture directory")
        read = self.row("Fixture identity read")
        # The first sentence, without the read-only lead the Read tag already shows.
        expect(read.locator(".capability-copy span")).to_have_text("Read a directory identity.")
        create = self.row("Fixture identity create")
        expect(create.locator(".capability-copy span")).to_have_text("Create a directory identity.")
        # Internal identifiers stay out of the page text: no snake_case ids, no specialist names.
        page = self.page.locator(".capabilities-view")
        for internal in ("fixture_identity_create", "fixture-identity", "fixture-provider-issues", "specialist"):
            expect(page).not_to_contain_text(internal)
        self.assertEqual(self.errors, [])

    def test_search_opens_matching_groups_and_finds_names_summaries_services_and_ids(self):
        self.open_capabilities()
        search = self.page.get_by_role("searchbox", name="Search capabilities", exact=True)
        search.fill("identity")
        expect(self.page.locator(".capability-row:visible")).to_have_count(2)
        expect(self.group("Fixture directory")).to_have_attribute("open", "")
        expect(self.page.locator(".capability-group")).to_have_count(1)
        search.fill("fixture issues")
        expect(self.page.locator(".capability-row:visible")).to_have_count(1)
        search.fill("fixture_issue_create")
        expect(self.page.locator(".capability-row:visible")).to_have_count(1)
        search.fill("in bulk")
        expect(self.page.locator(".capability-row:visible")).to_have_count(1)
        search.fill("no such fixture operation")
        expect(self.page.locator(".capability-row")).to_have_count(0)
        expect(self.page.locator(".capability-empty")).to_be_visible()
        # Clearing the search returns to the collapsed overview.
        search.fill("")
        expect(self.page.locator(".capability-group[open]")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_counts_summarise_the_catalog(self):
        self.open_capabilities()
        summary = self.page.locator(".capability-summary")
        expect(summary).to_have_text("5 operations · 2 need approval")
        self.open_group("Fixture directory")
        # Secondary text stays readable against the near-black page (WCAG AA, 4.5:1).
        for selector in (".capability-summary", ".capability-copy span", ".capability-group-meta"):
            with self.subTest(selector=selector):
                self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
        self.assertEqual(self.errors, [])

    def test_palette_and_narrow_screens_reach_the_page(self):
        self.page.set_viewport_size({"width": 390, "height": 760})
        self.open_first_chat()
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Capabilities")
        self.page.keyboard.press("Enter")
        expect(self.page.locator(".workspace-title h1")).to_have_text("Capabilities")
        self.open_group("Fixture directory")
        expect(self.row("Fixture identity create")).to_be_visible()
        overflow = self.page.evaluate("() => document.documentElement.scrollWidth > window.innerWidth")
        self.assertFalse(overflow)
        # Operation names wrap only between words, never mid-word; the long
        # fixture name must actually wrap here for this to mean anything.
        breaks = self.page.evaluate("""() => [...document.querySelectorAll('.capability-copy strong')].flatMap((node) => {
            const text = node.textContent, range = document.createRange(), result = [];
            const tops = [...text].map((_, index) => {
                range.setStart(node.firstChild, index); range.setEnd(node.firstChild, index + 1);
                return Math.round(range.getBoundingClientRect().top);
            });
            for (let index = 1; index < text.length; index++) {
                if (tops[index] > tops[index - 1]) result.push(text[index - 1]);
            }
            return result;
        })""")
        self.assertTrue(breaks, "the long fixture name did not wrap at phone width")
        self.assertTrue(all(char == " " for char in breaks), breaks)
        # A service line wraps between its parts, never inside "1 needs approval".
        parts = self.page.evaluate("""() => [...document.querySelectorAll('.capability-meta-part')]
            .map((node) => node.getClientRects().length)""")
        self.assertTrue(parts and all(count == 1 for count in parts), parts)
        # Operations sit visibly inside their service.
        indent = self.page.evaluate("""() => {
            const group = document.querySelector('.capability-group[open]');
            const name = group.querySelector('.capability-group-name').getBoundingClientRect().left;
            const row = group.querySelector('.capability-copy strong').getBoundingClientRect().left;
            return row - name;
        }""")
        self.assertGreaterEqual(indent, 20)
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

    def test_each_service_shows_its_setup_state_and_missing_settings(self):
        self.open_capabilities()
        directory = self.group("Fixture directory")
        expect(directory.locator("summary .capability-tag.strong")).to_have_text("Needs setup")
        # The settings to supply are stated with the service, before it is opened.
        expect(directory.locator("summary")).to_contain_text("Missing FIXTURE_HOST, FIXTURE_BIND_PASSWORD")
        expect(self.group("Fixture issues").locator("summary")).to_contain_text("Simulated")
        # Only states that ask for attention are labelled, and only Needs setup is emphasised.
        expect(self.page.locator(".capability-group summary .capability-tag.strong")).to_have_count(1)
        workspace = self.group("Fixture workspace")
        expect(workspace.locator("summary")).to_contain_text("1 operation")
        expect(workspace.locator("summary .capability-tag")).to_have_count(0)
        expect(self.page.locator(".capabilities-view")).not_to_contain_text("Configured")
        # Configuration is not a provider check, and the page says so where setup is shown.
        expect(self.page.locator(".capabilities-view")).to_contain_text("not tested live")
        expect(self.page.locator(".capabilities-view")).not_to_contain_text("Healthy")
        contrast = self.page.evaluate(CONTRAST, ".capability-group-meta")
        self.assertGreaterEqual(contrast, 4.5)
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.errors, [])

    def test_setup_that_cannot_be_read_is_stated_and_never_shown_as_set_up(self):
        self.integration_status = 503
        self.open_capabilities()
        view = self.page.locator(".capabilities-view")
        expect(view).to_contain_text("Setup status could not be read.")
        # The operations are still listed, but no service claims a setup state.
        directory = self.open_group("Fixture directory")
        expect(self.row("Fixture identity create")).to_be_visible()
        expect(directory.locator("summary")).not_to_contain_text("Configured")
        expect(directory.locator("summary")).not_to_contain_text("Needs setup")
        self.assertEqual(self.errors, [])

    def test_refresh_reads_setup_again(self):
        self.integration_status = 503
        self.open_capabilities()
        view = self.page.locator(".capabilities-view")
        expect(view).to_contain_text("Setup status could not be read.")
        self.integration_status = 200
        view.get_by_role("button", name="Check setup again", exact=True).click()
        expect(self.group("Fixture directory").locator("summary")).to_contain_text("Needs setup")
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(CapabilitiesPageTests(name) for name in loader.getTestCaseNames(CapabilitiesPageTests)
                             if name in CapabilitiesPageTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
