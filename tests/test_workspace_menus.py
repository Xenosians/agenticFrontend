"""Application menu and normal composer contracts on isolated HTTP fixtures."""
import json
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect
from test_chat_navigation import ChatNavigationTests


class WorkspaceMenuTests(ChatNavigationTests):
    required_operations = None

    def route(self, route):
        if urlparse(route.request.url).path == "/config.js":
            config = {"backendBaseUrl": self.base, "pollIntervalMs": 10}
            if self.required_operations is not None:
                config["requiredOperations"] = self.required_operations
            route.fulfill(content_type="application/javascript",
                          body="window.AGENTIC_CONFIG = Object.freeze(" + json.dumps(config) + ");")
            return
        super().route(route)

    def menu(self, name):
        return self.page.get_by_role("menubar", name="Application menu").get_by_role("menuitem", name=name, exact=True)

    def test_normal_composer_hides_required_operations_without_removing_capabilities(self):
        self.open_first_chat()
        expect(self.page.get_by_role("button", name="Required operations", exact=True)).to_have_count(0)
        self.menu("View").click()
        self.page.get_by_role("menu", name="View", exact=True).get_by_role("menuitem", name="Capabilities", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Capabilities")
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_only_exact_boolean_explicitly_enables_reviewed_operations(self):
        for value in (False, "true", 1):
            self.required_operations = value
            self.page.goto(self.base + "/", wait_until="networkidle")
            expect(self.page.locator("#messageInput")).to_be_visible()
            expect(self.page.get_by_role("button", name="Required operations", exact=True)).to_have_count(0)
        self.required_operations = True
        self.page.reload(wait_until="networkidle")
        expect(self.page.get_by_role("button", name="Required operations", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [])

    def test_keyboard_menu_navigation_and_escape_restore_trigger(self):
        self.open_first_chat()
        trigger = self.menu("File")
        trigger.focus()
        trigger.press("ArrowDown")
        popup = self.page.get_by_role("menu", name="File", exact=True)
        expect(popup.get_by_role("menuitem", name="New chat", exact=True)).to_be_focused()
        self.page.keyboard.press("End")
        expect(popup.get_by_role("menuitem", name="Models and datasets", exact=True)).to_be_focused()
        self.page.keyboard.press("ArrowRight")
        expect(self.menu("Edit")).to_be_focused()
        expect(self.page.get_by_role("menu", name="Edit", exact=True)).to_be_visible()
        self.page.keyboard.press("Escape")
        expect(self.page.get_by_role("menu", name="Edit", exact=True)).to_have_count(0)
        expect(self.menu("Edit")).to_be_focused()
        self.assertEqual(self.submissions, [])

    def test_edit_search_and_help_use_real_actions_without_dispatch(self):
        self.open_first_chat()
        self.menu("Edit").click()
        self.page.get_by_role("menu", name="Edit", exact=True).get_by_role("menuitem", name="Search chats", exact=True).click()
        expect(self.page.locator("#chatSearch")).to_be_focused()
        self.menu("Help").click()
        self.page.get_by_role("menu", name="Help", exact=True).get_by_role("menuitem").click()
        expect(self.page.locator(".workspace-help")).to_be_visible()
        expect(self.page.locator("#messageInput")).to_have_count(0)
        self.page.get_by_role("button", name="Back to workspace", exact=True).click()
        expect(self.page.locator(".workspace-help")).to_have_count(0)
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_outside_click_and_tab_dismiss_and_mobile_menus_fit(self):
        self.open_first_chat()
        self.menu("File").click()
        self.page.locator(".workspace-title h1").click()
        expect(self.page.get_by_role("menu", name="File", exact=True)).to_have_count(0)
        self.menu("View").click()
        self.page.keyboard.press("Tab")
        expect(self.page.get_by_role("menu", name="View", exact=True)).to_have_count(0)
        self.page.set_viewport_size({"width": 390, "height": 844})
        for name in ("File", "Edit", "View", "Help"):
            self.menu(name).click()
            box = self.page.get_by_role("menu", name=name, exact=True).bounding_box()
            self.assertGreaterEqual(box["x"], 0)
            self.assertLessEqual(box["x"] + box["width"], 390)
            self.assertFalse(self.page.evaluate("document.documentElement.scrollWidth > innerWidth + 1"))
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(WorkspaceMenuTests(name) for name in loader.getTestCaseNames(WorkspaceMenuTests)
                              if name in WorkspaceMenuTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
