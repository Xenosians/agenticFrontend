"""Search across saved chats (FR-078), Hermes-style: the backend searches every
saved conversation the user owns; the page lists matches and opens one.

The open chat's loaded messages are still searched locally. Isolated HTTP
fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_chat_search.py
"""
import base64
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
            elif "rollback" in query.lower():
                # The backend returns the whole saved request; here the match
                # sits far past the end of one line of the result card.
                results = [
                    {"chat_id": "fixture-second", "title": "Second fixture chat", "matched": "message",
                     "excerpt": "The overnight deployment of the billing service ran for most of the "
                                "maintenance window, the health checks stayed red on two of the three "
                                "regions, the on-call engineer paged the database team twice, and after "
                                "the error budget for the week was spent the change board approved a "
                                "rollback", "updated_at": None},
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
        # The words that matched are marked in the excerpt, as in Hermes.
        expect(result.locator("mark")).to_have_text(["VPN"])
        # A result card and the empty state beside it share one inset.
        insets = self.page.evaluate("""() => [
            getComputedStyle(document.querySelector('.chat-search-result')).paddingLeft,
            getComputedStyle(document.querySelector('.chat-search-heading + .empty-card')).paddingLeft]""")
        self.assertEqual(insets[0], insets[1])
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
        expect(self.page.locator(".search-result mark")).to_have_text(["First chat"])
        # The local section names the chat it searched, at every width.
        expect(self.page.locator(".chat-search-heading").last).to_have_text("In this chat · First fixture chat")
        self.assertEqual(self.errors, [])

    def test_a_match_late_in_a_long_saved_message_stays_in_view(self):
        search = self.open_search()
        search.fill("rollback")
        excerpt = self.page.locator(".chat-search-result .search-text")
        expect(excerpt.locator("mark")).to_have_text(["rollback"])
        # The line starts shortly before the match, marked as cut, so the
        # matched word is inside the card instead of past its ellipsis.
        expect(excerpt).to_contain_text("…")
        visible = self.page.evaluate("""() => {
            const line = document.querySelector('.chat-search-result .search-text').getBoundingClientRect();
            const mark = document.querySelector('.chat-search-result .search-text mark').getBoundingClientRect();
            return mark.right <= line.right + 0.5 && mark.left >= line.left - 0.5;
        }""")
        self.assertTrue(visible, "the matched word is cut off by the result card")
        self.assertEqual(self.errors, [])

    def test_clearing_the_query_clears_saved_chat_results(self):
        search = self.open_search()
        search.fill("VPN")
        expect(self.page.locator(".chat-search-result")).to_have_count(1)
        self.page.get_by_role("button", name="Clear search", exact=True).click()
        expect(self.page.locator(".chat-search-result")).to_have_count(0)
        expect(self.page.locator(".chat-search-status")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_the_search_field_is_one_box_with_one_clear_button(self):
        search = self.open_search()
        search.fill("VPN")
        self.assertTrue(search.evaluate("node => node.matches(':focus-visible')"))
        field = self.page.evaluate("""() => {
            const input = getComputedStyle(document.querySelector('#chatSearch'));
            const box = getComputedStyle(document.querySelector('.search-box'));
            return {inputOutline: input.outlineStyle, boxRing: box.outlineStyle !== 'none'};
        }""")
        # Focus is shown once, on the rounded field, not as a square inside it.
        self.assertEqual(field, {"inputOutline": "none", "boxRing": True})
        # The browser's own clear glyph is not drawn beside the app's Clear
        # button. Computed styles cannot read that pseudo-element, so measure
        # the pixels at the input's right edge: a drawn glyph is near white.
        box = search.bounding_box()
        edge = self.page.screenshot(clip={"x": box["x"] + box["width"] - 30, "y": box["y"],
                                          "width": 28, "height": box["height"]})
        brightest = self.page.evaluate("""async (data) => {
            const image = new Image();
            image.src = 'data:image/png;base64,' + data;
            await image.decode();
            const canvas = new OffscreenCanvas(image.width, image.height);
            const context = canvas.getContext('2d');
            context.drawImage(image, 0, 0);
            const pixels = context.getImageData(0, 0, image.width, image.height).data;
            let max = 0;
            for (let index = 0; index < pixels.length; index += 4) {
                max = Math.max(max, (pixels[index] + pixels[index + 1] + pixels[index + 2]) / 3);
            }
            return max;
        }""", base64.b64encode(edge).decode())
        self.assertLess(brightest, 128, "a native clear glyph is drawn inside the search field")
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(ChatSearchTests(name) for name in loader.getTestCaseNames(ChatSearchTests)
                             if name in ChatSearchTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
