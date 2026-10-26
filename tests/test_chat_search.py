"""Search across saved chats (FR-078), Hermes-style: the backend searches every
saved conversation the user owns; the page lists matches and opens one.

The open chat's loaded messages are still searched locally. Isolated HTTP
fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_chat_search.py
"""
import unittest
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation


class ChatSearchTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.queries = []
        self.search_status = 200
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        url = urlparse(request.url)
        if request.url.startswith(self.base + "/api/") and url.path == "/api/v1/chats/search":
            query = parse_qs(url.query).get("q", [""])[0]
            self.queries.append(query)
            if self.search_status != 200:
                route.fulfill(status=self.search_status, json={"error": "chat_search_failed"})
                return
            results = []
            if "vpn" in query.lower():
                results = [
                    {"chat_id": "fixture-second", "title": "Second fixture chat", "matched": "message",
                     "excerpt": "Reset the VPN token for the night shift", "updated_at": None},
                ]
            route.fulfill(json={"results": results})
            return
        super().route(route)

    def open_search(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+Shift+F")
        expect(self.page.locator(".workspace-title h1")).to_have_text("Search")
        return self.page.locator("#chatSearch")

    def test_matches_from_other_saved_chats_are_listed_and_open_the_chat(self):
        search = self.open_search()
        search.fill("VPN")
        result = self.page.locator(".chat-search-result").filter(has_text="Second fixture chat")
        expect(result).to_be_visible()
        expect(result).to_contain_text("Reset the VPN token for the night shift")
        # Typing is debounced: one request for the settled query, not one per key.
        self.assertEqual(self.queries, ["VPN"])
        result.click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Chat")
        self.page.wait_for_function("globalThis.navigationFixturePending === true")
        self.release_second_chat()
        expect(self.page.get_by_text("Second chat history", exact=True)).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_no_match_and_a_failed_search_are_stated(self):
        search = self.open_search()
        search.fill("printer")
        expect(self.page.locator(".chat-search-status")).to_have_text("No saved chats match this search.")
        self.search_status = 500
        search.fill("printer offline")
        expect(self.page.locator(".chat-search-status")).to_have_text(
            "Saved chats could not be searched. Try again.")
        expect(self.page.locator(".chat-search-result")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_the_loaded_chat_is_still_searched_locally(self):
        search = self.open_search()
        search.fill("First chat")
        expect(self.page.locator(".search-result")).to_contain_text("First chat history")
        self.assertEqual(self.errors, [])

    def test_clearing_the_query_clears_saved_chat_results(self):
        search = self.open_search()
        search.fill("VPN")
        expect(self.page.locator(".chat-search-result")).to_have_count(1)
        self.page.get_by_role("button", name="Clear search", exact=True).click()
        expect(self.page.locator(".chat-search-result")).to_have_count(0)
        expect(self.page.locator(".chat-search-status")).to_have_count(0)
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(ChatSearchTests(name) for name in loader.getTestCaseNames(ChatSearchTests)
                             if name in ChatSearchTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
