"""Crawl a site into reference knowledge (SRS 1.9 FR-083/FR-085), with isolated HTTP fixtures.

The machine's Lua profile decides which sites may be crawled, and the catalog lists
them. The Data tab offers only those sites; the AI service fetches the pages and
admits the text like an upload, as reference knowledge only.
Run after rebuilding: python tests/test_knowledge_crawl.py
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST
from test_workspace_context import CATALOG

SITES = ["https://docs.example.org", "http://wiki.lan:8090"]


class KnowledgeCrawlTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog["crawl_sources"] = list(SITES)
        self.mutations = []
        self.crawl_reply = {"id": "c" * 32, "kind": "dataset", "purpose": "rag", "state": "ready", "version": 1}
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        if urlparse(request.url).path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            if request.method == "GET":
                route.fulfill(json=self.catalog)
                return
            body = request.post_data_json
            self.mutations.append(body)
            if isinstance(self.crawl_reply, tuple):
                route.fulfill(status=self.crawl_reply[0], json=self.crawl_reply[1])
            else:
                route.fulfill(json=self.crawl_reply)
            return
        super().route(route)

    def open_crawl(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        self.page.locator(".plugin-tabs").get_by_role("button", name="Data & automation", exact=True).click()
        toggle = self.page.get_by_role("button", name="Crawl a site", exact=True)
        expect(toggle).to_have_attribute("aria-expanded", "false")
        toggle.click()
        expect(toggle).to_have_attribute("aria-expanded", "true")

    def fill_dataset(self):
        self.page.get_by_placeholder("Dataset name", exact=True).fill("VPN runbooks")
        self.page.get_by_placeholder("Internal / owned", exact=True).fill("Internal use")
        self.page.locator(".dataset-review input").check()

    def start_page(self):
        return self.page.get_by_role("textbox", name="Start page", exact=True)

    def crawl_button(self):
        return self.page.locator(".dataset-crawl").get_by_role("button", name="Crawl and save", exact=True)

    def test_only_the_sites_this_machine_declares_are_offered(self):
        self.open_crawl()
        listed = self.page.locator(".dataset-crawl-sites li")
        expect(listed).to_have_text(SITES)
        expect(self.start_page()).to_have_value(SITES[0] + "/")
        self.assertEqual(self.errors, [])

    def test_crawling_saves_reference_knowledge_with_the_dataset_fields(self):
        self.open_crawl()
        self.fill_dataset()
        self.start_page().fill("https://docs.example.org/vpn/")
        with self.page.expect_response(lambda response: urlparse(response.url).path == "/api/v1/extensions"
                                       and response.request.method == "POST"):
            self.crawl_button().click()
        self.assertEqual(self.mutations, [{"action": "dataset_crawl", "payload": {
            "url": "https://docs.example.org/vpn/", "name": "VPN runbooks", "license": "Internal use",
            "purpose": "rag", "reviewed": True}}])
        expect(self.page.locator(".plugin-notice")).to_contain_text("Saved.")

    def test_a_start_page_outside_the_declared_sites_is_never_sent(self):
        self.open_crawl()
        self.fill_dataset()
        for outside in ("https://docs.example.org.evil.test/", "https://elsewhere.example/"):
            self.start_page().fill(outside)
            expect(self.crawl_button()).to_be_disabled()
            expect(self.page.locator(".dataset-crawl .dataset-transform-note[role=alert]")).to_have_text(
                "Choose a page on one of the sites listed above.")
        self.crawl_button().dispatch_event("click")
        self.page.wait_for_timeout(300)
        self.assertEqual(self.mutations, [])

    def test_a_refused_crawl_shows_its_reason_and_saves_nothing(self):
        self.crawl_reply = (422, {"error": "extension_request_rejected", "detail": {
            "code": "crawl_found_no_text",
            "message": "No readable text was found at that address; nothing was saved."}})
        self.open_crawl()
        self.fill_dataset()
        self.crawl_button().click()
        expect(self.page.locator(".plugin-notice.error")).to_contain_text(
            "No readable text was found at that address; nothing was saved. (crawl_found_no_text)")

    def test_without_declared_sites_no_crawl_is_offered(self):
        self.catalog["crawl_sources"] = []
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        self.page.locator(".plugin-tabs").get_by_role("button", name="Data & automation", exact=True).click()
        expect(self.page.get_by_role("button", name="Upload dataset", exact=True)).to_be_visible()
        expect(self.page.get_by_role("button", name="Crawl a site", exact=True)).to_have_count(0)

    def test_crawl_text_meets_wcag_aa_contrast_without_overflow(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_crawl()
            for selector in (".dataset-crawl .dataset-transform-note", ".dataset-crawl-sites li"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            overflow = self.page.evaluate(
                "document.documentElement.scrollWidth > document.documentElement.clientWidth")
            self.assertFalse(overflow, f"horizontal overflow at {width}px")


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(KnowledgeCrawlTests(name) for name in loader.getTestCaseNames(KnowledgeCrawlTests)
                             if name in KnowledgeCrawlTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
