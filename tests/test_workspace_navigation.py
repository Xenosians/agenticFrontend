"""Exact row targets and keyboard flows in the built UI, with isolated APIs."""
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation


class WorkspaceNavigationTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.opened = []
        self.deleted = []
        self.revoked = []
        self.created = []
        self.chat_keys = ["first", "second", "third"]
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/api/"):
            if path == "/api/v1/chats":
                if request.method == "POST":
                    self.created.append(request.post_data_json)
                    route.fulfill(json={"chat": {"chat_id": "fixture-new", "title": "New chat"}})
                else:
                    route.fulfill(json={"chats": [
                        {"chat_id": "fixture-" + key, "title": key.title() + " fixture chat"}
                        for key in self.chat_keys]})
                return
            if path.startswith("/api/v2/chats/") and path.endswith("/history"):
                key = path.split("/")[-2].removeprefix("fixture-")
                self.opened.append(key)
                route.fulfill(json={"messages": [{"role": "user", "content": key.title() + " chat history"}]})
                return
            if path.startswith("/api/v1/chats/") and request.method == "DELETE":
                key = path.rsplit("/", 1)[1].removeprefix("fixture-")
                self.deleted.append(key)
                self.chat_keys.remove(key)
                route.fulfill(json={"status": "deleted"})
                return
            if path == "/api/v1/auth/sessions":
                route.fulfill(json={"sessions": [
                    {"session_id": "fixture-" + key, "user_agent": key.title() + " fixture browser",
                     "expires_at": "2030-01-01", "current": key == "session",
                     "revoked_at": "2026-10-25" if key in self.revoked else ""}
                    for key in ("one", "two", "three", "session")]})
                return
            if path.startswith("/api/v1/auth/sessions/") and path.endswith("/revoke"):
                key = path.split("/")[-2].removeprefix("fixture-")
                self.revoked.append(key)
                route.fulfill(json={"status": "revoked"})
                return
        super().route(route)

    def sidebar_row(self, key):
        return self.page.locator(".chat-nav-row").filter(
            has=self.page.get_by_text(key.title() + " fixture chat", exact=True))

    def assert_no_side_effects(self):
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_sidebar_open_keeps_first_middle_and_last_targets(self):
        self.open_first_chat()
        for key in ("second", "first", "third"):
            with self.subTest(key=key):
                self.sidebar_row(key).locator(".chat-nav-main").click()
                expect(self.page.get_by_text(key.title() + " chat history", exact=True)).to_be_visible()
                self.assertEqual(self.opened[-1], key)
        self.assert_no_side_effects()

    def test_sidebar_delete_confirmation_and_cancel_keep_exact_target(self):
        self.open_first_chat()
        first = self.sidebar_row("first")
        first.locator(".chat-delete").click()
        expect(first.locator(".chat-delete-confirm-yes")).to_be_visible()
        expect(self.sidebar_row("third").locator(".chat-delete-confirm-yes")).to_have_count(0)
        first.get_by_role("button", name="Cancel", exact=True).click()
        self.assertEqual(self.deleted, [])
        for key in ("first", "second", "third"):
            with self.subTest(key=key):
                row = self.sidebar_row(key)
                row.locator(".chat-delete").click()
                row.locator(".chat-delete-confirm-yes").click()
                expect(self.sidebar_row(key)).to_have_count(0)
                self.assertEqual(self.deleted[-1], key)
        self.assert_no_side_effects()

    def test_saved_chat_list_keeps_each_displayed_target(self):
        self.open_first_chat()
        for key in ("third", "first", "second"):
            with self.subTest(key=key):
                self.page.keyboard.press("Control+Alt+c")
                self.page.locator(".saved-chat-row").filter(
                    has=self.page.get_by_text(key.title() + " fixture chat", exact=True)).click()
                expect(self.page.get_by_text(key.title() + " chat history", exact=True)).to_be_visible()
                self.assertEqual(self.opened[-1], key)
        self.assert_no_side_effects()

    def test_revoke_targets_clicked_session_and_preserves_current(self):
        self.open_first_chat()
        self.page.get_by_title("More", exact=True).click()
        self.page.get_by_role("button", name="Account", exact=True).click()
        for key in ("one", "two", "three"):
            with self.subTest(key=key):
                row = self.page.locator(".account-session-row").filter(has_text=key.title() + " fixture browser")
                row.get_by_role("button", name="Revoke", exact=True).click()
                expect(row.get_by_text("Revoked", exact=True)).to_be_visible()
                self.assertEqual(self.revoked[-1], key)
        expect(self.page.locator(".account-session-row").filter(has_text="Session fixture browser")
               .get_by_text("Current", exact=True)).to_be_visible()
        expect(self.page.locator("#messageInput")).to_have_count(0)
        self.assert_no_side_effects()

    def test_commands_invoke_selected_action(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+k")
        self.page.locator(".command-center-row").filter(has=self.page.get_by_text("Search chats", exact=True)).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Search")
        self.page.keyboard.press("Control+k")
        self.page.locator(".command-center-row").filter(has=self.page.get_by_text("New chat", exact=True)).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Chat")
        self.assertEqual(len(self.created), 1)
        self.assert_no_side_effects()

    def test_palette_focus_filters_and_enter_selects_visible_action(self):
        self.open_first_chat()
        self.page.locator("#messageInput").focus()
        self.page.keyboard.press("Control+k")
        expect(self.page.locator("#commandSearch")).to_be_focused()
        self.page.keyboard.type("Search chats")
        expect(self.page.locator("#commandSearch")).to_have_value("Search chats")
        expect(self.page.locator(".command-center-row")).to_have_count(1)
        self.page.keyboard.press("Enter")
        expect(self.page.locator(".workspace-title h1")).to_have_text("Search")
        expect(self.page.locator(".search-input")).to_be_focused()
        self.assert_no_side_effects()

    def test_button_palette_escape_and_compose_restore_focus_after_render(self):
        self.open_first_chat()
        button = self.page.get_by_title("Commands (Ctrl/Cmd+K)", exact=True)
        button.click()
        expect(self.page.locator("#commandSearch")).to_be_focused()
        self.page.keyboard.press("Escape")
        expect(button).to_be_focused()
        self.page.keyboard.press("Control+Shift+f")
        expect(self.page.locator(".search-input")).to_be_focused()
        self.page.keyboard.press("Control+k")
        self.page.locator(".command-center-row").filter(has=self.page.get_by_text("Focus message composer", exact=True)).click()
        expect(self.page.locator("#messageInput")).to_be_focused()
        self.page.keyboard.press("Control+k")
        expect(self.page.locator("#commandSearch")).to_be_focused()
        self.page.keyboard.press("Escape")
        expect(self.page.locator("#messageInput")).to_be_focused()
        self.assert_no_side_effects()

    def test_navigation_dismisses_command_page(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+k")
        self.page.locator(".nav-item").filter(has=self.page.get_by_text("System", exact=True)).click()
        expect(self.page.locator(".command-center")).to_have_count(0)
        expect(self.page.locator(".workspace-title h1")).to_have_text("System")
        self.assert_no_side_effects()

    def test_palette_confirmation_ignores_ime_repeated_and_unmatched_input(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+k")
        search = self.page.locator("#commandSearch")
        search.fill("New chat")
        for flags in ({"isComposing": True}, {"repeat": True}):
            search.dispatch_event("keydown", {"key": "Enter", "bubbles": True, **flags})
            self.page.evaluate("() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
            expect(search).to_be_visible()
            self.assertEqual(self.created, [])
        search.fill("No matching fixture command")
        search.press("Enter")
        expect(search).to_be_focused()
        self.assertEqual(self.created, [])
        self.assert_no_side_effects()


def load_tests(loader, _tests, _pattern):
    # Reuse the isolated server fixture, without silently duplicating the
    # inherited navigation suite (which runs separately in the final gate).
    return unittest.TestSuite(WorkspaceNavigationTests(name) for name in loader.getTestCaseNames(WorkspaceNavigationTests)
                             if name in WorkspaceNavigationTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
