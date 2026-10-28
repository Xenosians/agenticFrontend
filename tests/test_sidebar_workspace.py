"""Saved chat UX against an isolated API. No account, job or tool is dispatched."""
import unittest
from datetime import datetime, timezone
from urllib.parse import urlparse

from playwright.sync_api import expect
import test_chat_navigation as navigation


class SidebarWorkspaceTests(unittest.TestCase):
    setUpClass = navigation.ChatNavigationTests.__dict__["setUpClass"]
    tearDownClass = navigation.ChatNavigationTests.__dict__["tearDownClass"]
    tearDown = navigation.ChatNavigationTests.tearDown

    def setUp(self):
        self.chats = [
            {"chat_id": "fixture-first", "title": "First fixture chat", "updated_at": "2026-10-28T08:00:00Z", "pinned": False},
            {"chat_id": "fixture-second", "title": "Second fixture chat", "updated_at": "2026-10-27T08:00:00Z", "pinned": False},
            {"chat_id": "fixture-third", "title": "Third fixture chat", "updated_at": "2026-06-01T08:00:00Z", "pinned": True},
        ]
        self.patches = []
        self.held = []
        self.patch_mode = "confirmed"
        navigation.ChatNavigationTests.setUp(self)
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/api/"):
            if path == "/api/v1/chats" and request.method == "GET":
                route.fulfill(json={"chats": self.chats})
                return
            if path.startswith("/api/v1/chats/") and request.method == "PATCH":
                key = path.rsplit("/", 1)[1]
                patch = request.post_data_json
                self.patches.append((key, patch, request.headers.get("x-csrf-token")))
                if self.patch_mode == "held":
                    self.held.append(route)
                    return
                chat = next(chat for chat in self.chats if chat["chat_id"] == key)
                chat.update(patch)
                if self.patch_mode == "interrupted":
                    route.abort()
                elif self.patch_mode == "wrong-target":
                    route.fulfill(json={"chat": {**chat, "chat_id": "unrelated-chat"}})
                else:
                    route.fulfill(json={"chat": chat})
                return
            if path.startswith("/api/v2/chats/") and path.endswith("/history"):
                key = path.split("/")[-2].removeprefix("fixture-")
                route.fulfill(json={"messages": [{"role": "user", "content": key.title() + " chat history"}]})
                return
        navigation.ChatNavigationTests.route(self, route)

    def open(self):
        self.page.goto(self.base + "/", wait_until="networkidle")
        expect(self.page.get_by_text("First chat history", exact=True)).to_be_visible()

    def row(self, title):
        return self.page.locator(".chat-nav-row").filter(
            has=self.page.locator(".chat-nav-title", has_text=title))

    def begin_rename(self, title):
        row = self.row(title)
        row.hover()
        row.locator(".chat-rename-open").click()
        expect(row.get_by_role("textbox", name="Chat title", exact=True)).to_be_focused()
        return row

    def test_rail_chat_sections_filter_and_keyboard_focus(self):
        self.open()
        expect(self.page.locator(".workspace-rail")).to_be_visible()
        expect(self.page.locator(".chats-sidebar")).to_be_visible()
        expect(self.page.locator(".chat-date-group").first.locator(".section-label")).to_have_text("Pinned")
        expect(self.page.locator(".chat-date-group").first).to_contain_text("Third fixture chat")
        self.page.get_by_role("searchbox", name="Filter recent chats", exact=True).fill("second")
        expect(self.page.locator(".chat-nav-row")).to_have_count(1)
        expect(self.page.locator(".chat-nav-title")).to_have_text("Second fixture chat")
        self.page.get_by_role("searchbox", name="Filter recent chats", exact=True).fill("no matching entry")
        expect(self.page.get_by_text("No matching chats", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_pin_and_rename_keep_the_exact_row_and_csrf_identity(self):
        self.open()
        for index, title in enumerate(("First fixture chat", "Second fixture chat", "Third fixture chat")):
            row = self.row(title)
            row.hover()
            row.locator(".chat-pin").click()
            expected = index != 2
            expect(row.locator(".chat-pin")).to_have_attribute("title", "Unpin chat" if expected else "Pin chat")
            self.assertEqual(self.patches[-1], ("fixture-" + ("first", "second", "third")[index],
                                               {"pinned": expected}, "fixture-csrf"))
            row = self.begin_rename(title)
            row.get_by_role("textbox", name="Chat title", exact=True).fill("  Renamed " + str(index) + "  ")
            row.get_by_role("textbox", name="Chat title", exact=True).press("Enter")
            expect(self.page.locator(".chat-nav-title", has_text="Renamed " + str(index))).to_be_visible()
            self.assertEqual(self.patches[-1][1], {"title": "Renamed " + str(index)})
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_interrupted_write_requires_readback_before_another_write(self):
        self.open()
        self.patch_mode = "interrupted"
        row = self.row("Second fixture chat")
        row.hover()
        row.locator(".chat-pin").click()
        expect(self.page.get_by_role("alert")).to_contain_text("not confirmed")
        expect(row.locator(".chat-pin")).to_be_disabled()
        expect(row.locator(".chat-rename-open")).to_be_disabled()
        self.assertEqual(len(self.patches), 1)
        self.patch_mode = "confirmed"
        self.page.get_by_role("button", name="Refresh chats", exact=True).click()
        expect(self.page.get_by_role("alert")).to_have_count(0)
        expect(row.locator(".chat-pin")).to_have_attribute("title", "Unpin chat")
        self.assertEqual(len(self.patches), 1)
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_wrong_target_receipt_never_updates_the_displayed_title(self):
        self.open()
        self.patch_mode = "wrong-target"
        row = self.begin_rename("Second fixture chat")
        row.get_by_role("textbox", name="Chat title", exact=True).fill("Unconfirmed title")
        row.get_by_role("button", name="Save", exact=True).click()
        expect(self.page.get_by_role("alert")).to_contain_text("not confirmed")
        expect(self.page.locator(".chat-nav-title", has_text="Second fixture chat")).to_be_visible()
        expect(self.page.locator(".chat-nav-title", has_text="Unconfirmed title")).to_have_count(0)
        self.assertEqual(len(self.patches), 1)
        self.assertEqual(self.errors, [])

    def test_rename_composition_and_repeated_enter_do_not_submit(self):
        self.open()
        row = self.begin_rename("Second fixture chat")
        field = row.get_by_role("textbox", name="Chat title", exact=True)
        field.fill("Composed title")
        field.evaluate("el => el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', isComposing:true, bubbles:true}))")
        field.evaluate("el => el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', repeat:true, bubbles:true}))")
        field.press("Escape")
        expect(self.page.locator(".chat-rename")).to_have_count(0)
        self.assertEqual(self.patches, [])
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_late_rename_does_not_replace_the_new_foreground_chat(self):
        self.open()
        self.patch_mode = "held"
        row = self.begin_rename("First fixture chat")
        row.get_by_role("textbox", name="Chat title", exact=True).fill("Renamed in background")
        row.get_by_role("button", name="Save", exact=True).click()
        expect(row.get_by_role("button", name="Save", exact=True)).to_be_disabled()
        self.row("Second fixture chat").locator(".chat-nav-main").click()
        expect(self.page.get_by_text("Second chat history", exact=True)).to_be_visible()
        self.assertEqual(len(self.held), 1)
        self.held.pop().fulfill(json={"chat": {**self.chats[0], "title": "Renamed in background"}})
        expect(self.page.locator(".chat-nav-title", has_text="Renamed in background")).to_be_visible()
        expect(self.page.get_by_text("Second chat history", exact=True)).to_be_visible()
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_chat_scroll_and_account_remain_reachable_at_short_and_mobile_sizes(self):
        for index in range(60):
            self.chats.append({"chat_id": "fixture-extra-" + str(index), "title": "Conversation " + str(index),
                               "updated_at": "2026-10-25T08:00:00Z", "pinned": False})
        self.page.set_viewport_size({"width": 1440, "height": 640})
        self.open()
        account = self.page.get_by_role("button", name="Account settings", exact=True)
        expect(account).to_be_visible()
        self.assertTrue(account.evaluate("el => { const b=el.getBoundingClientRect(); return b.top>=0 && b.bottom<=innerHeight; }"))
        chat_nav = self.page.locator(".chat-nav-section")
        self.assertTrue(chat_nav.evaluate("el => el.scrollHeight > el.clientHeight"))
        self.page.locator(".chat-nav-main", has_text="Conversation 59").scroll_into_view_if_needed()
        expect(account).to_be_visible()
        self.page.set_viewport_size({"width": 390, "height": 844})
        expect(self.page.locator(".workspace-rail")).to_be_visible()
        expect(self.page.locator(".chats-sidebar")).not_to_be_visible()
        expect(account).to_be_visible()
        self.assertTrue(self.page.evaluate("document.documentElement.scrollWidth <= innerWidth"))
        self.assertEqual(self.errors, [])


    def test_date_groups_use_the_viewers_timezone_near_utc_midnight(self):
        self.context.close()
        self.context = self.browser.new_context(timezone_id="Asia/Jakarta")
        self.context.add_init_script("window.WebSocket = undefined;")
        self.page = self.context.new_page()
        self.page.on("pageerror", lambda error: self.errors.append(str(error)))
        self.page.route("**/*", self.route)
        self.page.clock.set_fixed_time(datetime(2026, 10, 28, 12, tzinfo=timezone.utc))
        self.chats[0]["updated_at"] = "2026-10-27T23:30:00Z"  # 28 October in Jakarta.
        self.chats[1]["updated_at"] = "2026-10-27T10:00:00Z"
        self.open()
        groups = self.page.locator(".chat-date-group")
        expect(groups.filter(has=self.page.get_by_text("Today", exact=True))).to_contain_text("First fixture chat")
        expect(groups.filter(has=self.page.get_by_text("Yesterday", exact=True))).to_contain_text("Second fixture chat")
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
