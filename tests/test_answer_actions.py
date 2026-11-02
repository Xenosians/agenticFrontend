"""Answer actions: copy an answer, and export the open chat as Markdown.

Both happen in the browser only: nothing is sent, saved or stored. Isolated fixtures.
"""
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation

ANSWER = "Restart the **DHCP** service, then check `ipconfig /renew`."


class AnswerActionTests(navigation.ChatNavigationTests):
    def setUp(self):
        super().setUp()
        self.context.grant_permissions(["clipboard-read", "clipboard-write"], origin=self.base)
        self.page.set_default_timeout(5000)
        self.mutations = []

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/api/"):
            if request.method not in ("GET", "HEAD"):
                self.mutations.append((request.method, path))
            if path == "/api/v2/chats/fixture-first/history":
                route.fulfill(json={"messages": [
                    {"role": "user", "content": "Why can't my laptop get an address?", "job_id": "fixture-job",
                     "status": "completed"},
                    {"role": "assistant", "content": ANSWER, "job_id": "fixture-job", "status": "completed"},
                ]})
                return
            if path == "/api/v2/jobs/fixture-job":
                # A saved answer is re-read from its job, so the job carries the same text.
                route.fulfill(json={"contract_version": 2, "job_id": "fixture-job", "status": "completed",
                                    "result": {"answer": ANSWER}})
                return
        super().route(route)

    def open_answer(self):
        self.page.goto(self.base + "/", wait_until="networkidle")
        expect(self.page.locator(".message-bubble.assistant")).to_contain_text("Restart the")

    def test_copy_puts_the_answer_text_on_the_clipboard(self):
        self.open_answer()
        copy = self.page.get_by_role("button", name="Copy answer", exact=True)
        copy.click()
        expect(self.page.get_by_role("button", name="Copied", exact=True)).to_be_visible()
        self.assertEqual(self.page.evaluate("navigator.clipboard.readText()"), ANSWER)
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.errors, [])

    def test_export_downloads_the_open_chat_as_markdown(self):
        self.open_answer()
        with self.page.expect_download() as info:
            self.page.get_by_title("More", exact=True).click()
            self.page.get_by_role("button", name="Export chat as Markdown", exact=True).click()
        download = info.value
        self.assertEqual(download.suggested_filename, "first-fixture-chat.md")
        text = open(download.path(), encoding="utf-8").read()
        self.assertIn("# First fixture chat", text)
        self.assertIn("**You**\n\nWhy can't my laptop get an address?", text)
        self.assertIn("**Janus**\n\n" + ANSWER, text)
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(AnswerActionTests(name) for name in loader.getTestCaseNames(AnswerActionTests)
                             if name in AnswerActionTests.__dict__)


if __name__ == "__main__":
    unittest.main()
