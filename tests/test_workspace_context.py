"""V19-01 workspace context, names and failure feedback in the built UI.

Isolated HTTP fixtures only: no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_workspace_context.py
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation


CATALOG = {
    "schema": "extension-catalog.v1",
    "resources": [
        {"id": "fixture-model", "kind": "model", "name": "Fixture provider model", "backend": "http",
         "model": "fixture-remote", "url": "https://provider.example.test/v1", "state": "ready"},
        {"id": "fixture-dataset", "kind": "dataset", "name": "Fixture runbooks", "purpose": "rag",
         "state": "ready", "source": "fixture", "license": "internal"},
    ],
    "selected": {"model_id": "fixture-model", "dataset_id": "fixture-dataset"},
    "role_assignments": {}, "local_profiles": [], "specialist_roles": [], "provider_presets": [],
    "connection_presets": [], "harnesses": [], "connections": [], "capabilities": [],
    "inference_option_support": [],
}

# Icon-only and unlabeled controls must expose a real accessible name.
NAMED_CONTROLS = (
    ("chat", "button", "More"),
    ("chat", "button", "Delete chat First fixture chat"),
    ("connections", "button", "Refresh connections"),
    ("connections", "searchbox", "Search plugins"),
    ("connections-personal", "combobox", "Active model"),
    ("connections-personal", "combobox", "Reference dataset"),
    ("connections-data", "button", "Import from API"),
    ("connections-add", "button", "Back to providers"),
)


class WorkspaceContextTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog_requests = 0
        self.mutations = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        if urlparse(request.url).path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            if request.method == "GET":
                self.catalog_requests += 1
                route.fulfill(json=self.catalog)
            else:
                self.mutations.append(request.post_data_json)
                route.fulfill(status=500, json={"detail": "unexpected fixture mutation"})
            return
        super().route(route)

    def open_view(self, view):
        self.open_first_chat()
        if view == "chat":
            return
        self.page.keyboard.press("Control+,")
        expect(self.page.get_by_role("heading", name="Available providers", exact=True)).to_be_visible()
        tabs = {"connections-personal": "Personal", "connections-data": "Data & automation"}
        if view in tabs:
            self.page.locator(".plugin-tabs").get_by_role("button", name=tabs[view], exact=True).click()
        elif view == "connections-add":
            self.page.locator(".plugin-add-button").click()

    def test_header_shows_the_selected_model_and_dataset(self):
        for viewport in ({"width": 1440, "height": 900}, {"width": 390, "height": 760}):
            with self.subTest(viewport=viewport):
                self.page.set_viewport_size(viewport)
                self.open_first_chat()
                context = self.page.locator(".workspace-context")
                expect(context).to_be_visible()
                expect(context).to_contain_text("Fixture provider model")
                expect(context).to_contain_text("Fixture runbooks")
                # One type scale: the header's text controls share a single size.
                sizes = self.page.evaluate("""() => [
                    '.workspace-context', '.chats-header-action', '.command-header-action',
                ].map((selector) => getComputedStyle(document.querySelector(selector)).fontSize)""")
                self.assertEqual(len(set(sizes)), 1, sizes)
                # Both names stay visible at every width; the full text is in the name.
                widths = self.page.evaluate("""() => ['model', 'dataset'].map((part) => {
                    const node = document.querySelector('.workspace-context-' + part);
                    return node ? node.getBoundingClientRect().width : 0;
                })""")
                self.assertTrue(all(width >= 24 for width in widths), widths)
                expect(context).to_have_attribute(
                    "aria-label", "Active model and dataset: Fixture provider model · Fixture runbooks")
                self.assertGreater(self.catalog_requests, 0)
                self.assertEqual(self.mutations, [])
                self.assertEqual(self.errors, [])

    def test_header_context_follows_a_changed_selection_without_a_dataset(self):
        self.catalog["selected"] = {"model_id": None, "dataset_id": None}
        self.open_first_chat()
        context = self.page.locator(".workspace-context")
        expect(context).to_contain_text("Default local models")
        expect(context).not_to_contain_text("Fixture runbooks")
        self.assertEqual(self.errors, [])

    def test_header_context_opens_the_connection_settings(self):
        self.open_first_chat()
        self.page.locator(".workspace-context").click()
        expect(self.page.get_by_role("heading", name="Personal", exact=True)).to_be_visible()
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.errors, [])

    def test_icon_and_unlabeled_controls_have_accessible_names(self):
        for view, role, name in NAMED_CONTROLS:
            with self.subTest(view=view, name=name):
                self.open_view(view)
                expect(self.page.get_by_role(role, name=name, exact=True).first).to_be_attached()
        self.assertEqual(self.errors, [])

    def test_upload_without_a_chosen_file_explains_instead_of_failing_silently(self):
        for label, message in (("Upload", "Choose a model folder first."),
                               ("Upload dataset", "Choose a text or JSONL file under 2 MB.")):
            with self.subTest(button=label):
                self.open_view("connections-data")
                self.page.get_by_role("button", name=label, exact=True).click()
                expect(self.page.locator(".plugin-notice.error")).to_contain_text(message)
                self.assertEqual(self.mutations, [])
                self.assertEqual(self.errors, [])

    def test_keyboard_focus_is_clearly_visible(self):
        self.open_first_chat()
        self.page.keyboard.press("Tab")
        outline = self.page.evaluate("""() => {
            const style = getComputedStyle(document.activeElement);
            return {style: style.outlineStyle, width: parseFloat(style.outlineWidth), color: style.outlineColor};
        }""")
        self.assertNotEqual(outline["style"], "none")
        self.assertGreaterEqual(outline["width"], 2)
        channels = [float(value) for value in outline["color"].strip("rgba()").split(",")[:3]]
        # Against the near-black workspace, a light outline meets the 3:1 non-text contrast minimum.
        self.assertGreaterEqual(min(channels), 150)
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    # Reuse the fixture lifecycle without rerunning its separate regression suite.
    return unittest.TestSuite(WorkspaceContextTests(name) for name in (
        "test_header_shows_the_selected_model_and_dataset",
        "test_header_context_follows_a_changed_selection_without_a_dataset",
        "test_header_context_opens_the_connection_settings",
        "test_icon_and_unlabeled_controls_have_accessible_names",
        "test_upload_without_a_chosen_file_explains_instead_of_failing_silently",
        "test_keyboard_focus_is_clearly_visible",
    ))


if __name__ == "__main__":
    unittest.main(verbosity=2)
