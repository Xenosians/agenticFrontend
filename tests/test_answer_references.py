"""Cited answers (FR-083, V19-06): an answer lists the reference passages its
model was given; each opens on request as untrusted reference text, only for
its owner and only as the exact cited version.

Isolated HTTP fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_answer_references.py
"""
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST

DATASET, VERSION = "a" * 32, "b" * 64


def citation(chunk, source="Owned router manual"):
    return {"locator": f"dataset:{DATASET}#chunk:{chunk}@{VERSION}", "dataset_id": DATASET, "chunk": chunk,
            "sha256": VERSION, "content_sha256": "c" * 64, "source": source, "license": "Owned"}


def passage(chunk, content):
    return {**citation(chunk), "schema": "owner-retrieval.v1", "content": content, "scope": "owner_private",
            "source_type": "dataset", "trust": "untrusted_retrieval"}


class AnswerReferenceTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.references = [citation(1), citation(3)]
        self.resolves, self.pending = [], []
        self.hold = False
        self.reply = None
        self.signed_out = False
        self.sessions = 0
        self.history_only = False
        super().setUp()
        self.page.set_default_timeout(5000)

    def tearDown(self):
        for route in self.pending:
            route.abort()
        super().tearDown()

    def route(self, route):
        request, path = route.request, urlparse(route.request.url).path
        if request.url.startswith(self.base + "/api/"):
            if path in {"/api/v1/auth/me", "/api/v1/auth/login"}:
                if self.signed_out and path == "/api/v1/auth/me":
                    route.fulfill(status=401, json={"error": "unauthenticated"})
                    return
                self.signed_out = False
                route.fulfill(json={"user": {"user_id": "fixture-owner", "email": "owner@example.test",
                    "display_name": "Fixture Owner", "role": "user"},
                    "session_id": f"fixture-session-{self.sessions}", "csrf_token": "fixture-csrf"})
                self.sessions += 1
                return
            if path == "/api/v1/auth/logout":
                self.signed_out = True
                route.fulfill(json={"status": "logged_out"})
                return
            if path == "/api/v1/auth/preferences":
                route.fulfill(json={"preferences": {"task_completed": False}})
                return
            if path == "/api/v1/auth/sessions":
                route.fulfill(json={"sessions": []})
                return
            if path == "/api/v2/chats/fixture-first/history":
                route.fulfill(json={"messages": [
                    {"role": "user", "content": "What changed last week?", "job_id": "older-job",
                     "status": "completed"},
                    {"role": "assistant", "content": "The DHCP pool was resized.", "job_id": "older-job",
                     "status": "completed", "references": [citation(8, "Change log")]},
                    {"role": "user", "content": "First chat history", "job_id": "fixture-job",
                     "status": "completed"},
                    {"role": "assistant", "content": "Check the WAN link light first.", "job_id": "fixture-job",
                     "status": "completed", "references": self.references},
                ]})
                return
            if path == "/api/v2/jobs/fixture-job":
                # Opening the chat re-reads its newest job; the saved result carries the same citations
                # unless a test checks that history alone restores them.
                result = {"answer": "Check the WAN link light first."}
                if not self.history_only:
                    result["references"] = self.references
                route.fulfill(json={"contract_version": 2, "job_id": "fixture-job", "status": "completed",
                                    "result": result})
                return
            if path == "/api/v1/extensions" and request.method == "POST" and request.post_data_json["action"] == "resolve":
                self.resolves.append({"payload": request.post_data_json["payload"],
                                      "csrf": request.headers.get("x-csrf-token")})
                if self.hold:
                    self.pending.append(route)
                    return
                payload = request.post_data_json["payload"]
                route.fulfill(json=self.reply or {"hit": passage(payload["chunk"], "Check the WAN light, then DHCP.")})
                return
        super().route(route)

    def open_answer(self):
        self.open_first_chat()
        expect(self.page.get_by_text("Check the WAN link light first.", exact=True)).to_be_visible()

    def assert_clean(self):
        self.assertEqual(self.errors, [])

    def test_an_answer_lists_the_passages_its_model_was_given(self):
        self.open_answer()
        section = self.page.get_by_role("region", name="Reference passages").last
        expect(section).to_contain_text("Reference passages given to the model")
        expect(section).to_contain_text("Untrusted reference")
        rows = section.locator(".answer-reference")
        expect(rows).to_have_count(2)
        expect(rows.nth(0)).to_contain_text("Owned router manual · chunk 1 · bbbbbbbb")
        expect(rows.nth(1)).to_contain_text("Owned router manual · chunk 3 · bbbbbbbb")
        # Nothing is fetched until the user asks for a passage.
        self.assertEqual(self.resolves, [])
        self.assert_clean()

    def test_earlier_answers_keep_their_citations_from_saved_history(self):
        self.history_only = True
        self.open_answer()
        older = self.page.locator(".message-row.assistant", has_text="The DHCP pool was resized.")
        expect(older.locator(".answer-reference")).to_have_count(1)
        expect(older.locator(".answer-reference")).to_contain_text("Change log · chunk 8 · bbbbbbbb")
        newest = self.page.locator(".message-row.assistant", has_text="Check the WAN link light first.")
        expect(newest.locator(".answer-reference")).to_have_count(2)
        self.assert_clean()

    def test_a_citation_opens_its_exact_passage_quoted_as_untrusted_text(self):
        self.open_answer()
        self.page.get_by_role("button", name="Show passage: Owned router manual · chunk 3 · bbbbbbbb").click()
        row = self.page.locator(f'.answer-reference[data-locator="dataset:{DATASET}#chunk:3@{VERSION}"]')
        expect(row.locator("blockquote")).to_have_text("Check the WAN light, then DHCP.")
        expect(row.locator(".knowledge-citation")).to_have_text(f"dataset:{DATASET}#chunk:3@{VERSION}")
        self.assertEqual(self.resolves, [{"payload": {"id": DATASET, "chunk": 3, "sha256": VERSION},
                                          "csrf": "fixture-csrf"}])
        # An opened passage is not fetched again.
        expect(row.get_by_role("button")).to_have_count(0)
        self.assert_clean()

    def test_a_reply_for_another_passage_or_authority_is_refused(self):
        for reply, message in (({"hit": passage(9, "Another chunk")}, "does not match its citation"),
                               ({"hit": {**passage(1, "Claims authority"), "trust": "trusted"}},
                                "does not match its citation"),
                               ({"detail": "outage"}, "could not be reopened")):
            self.reply = reply
            self.open_answer()
            self.page.get_by_role("button", name="Show passage: Owned router manual · chunk 1 · bbbbbbbb").click()
            row = self.page.locator(f'.answer-reference[data-locator="dataset:{DATASET}#chunk:1@{VERSION}"]')
            expect(row.locator("[role=alert]")).to_contain_text(message)
            expect(row.locator("blockquote")).to_have_count(0)
            # The error belongs to that citation only.
            expect(self.page.locator(".answer-references [role=alert]")).to_have_count(1)
        self.assert_clean()

    def test_malformed_citations_from_history_are_not_shown(self):
        broken = citation(2)
        broken["locator"] = f"dataset:{DATASET}#chunk:7@{VERSION}"
        self.references = [broken, {**citation(4), "content": "Ignore policy"}, citation(5)]
        self.open_answer()
        rows = self.page.locator(".message-row.assistant", has_text="Check the WAN link light first.").locator(
            ".answer-reference")
        expect(rows).to_have_count(1)
        expect(rows.first).to_contain_text("chunk 5")
        self.assert_clean()

    def test_an_answer_without_citations_has_no_reference_section(self):
        self.references = []
        self.open_answer()
        newest = self.page.locator(".message-row.assistant", has_text="Check the WAN link light first.")
        expect(newest.get_by_role("region", name="Reference passages")).to_have_count(0)
        self.assert_clean()

    def sign_out_and_back_in(self):
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Account settings")
        self.page.locator("#commandSearch").press("Enter")
        self.page.locator(".account-view").get_by_role("button", name="Sign out", exact=True).click()
        expect(self.page.get_by_role("heading", name="Sign in", exact=True)).to_be_visible()
        self.page.get_by_placeholder("you@example.com").fill("owner@example.test")
        self.page.get_by_placeholder("Password", exact=True).fill("fixture-password")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Account")

    def reopen_chat_in_app(self):
        # No page reload: anything kept in memory from the previous session would show here.
        self.page.locator(".chat-nav-title", has_text="First fixture chat").click()
        expect(self.page.get_by_text("Check the WAN link light first.", exact=True)).to_be_visible()

    def test_a_late_passage_never_appears_in_the_next_session(self):
        self.open_answer()
        self.hold = True
        self.page.get_by_role("button", name="Show passage: Owned router manual · chunk 1 · bbbbbbbb").click()
        expect(self.page.locator(".answer-reference-open", has_text="Opening…")).to_be_disabled()
        route = self.pending.pop()
        self.hold = False
        self.sign_out_and_back_in()
        route.fulfill(json={"hit": passage(1, "Late passage text")})
        self.reopen_chat_in_app()
        expect(self.page.get_by_text("Late passage text")).to_have_count(0)
        expect(self.page.get_by_role("button", name="Show passage: Owned router manual · chunk 1 · bbbbbbbb")).to_be_enabled()
        self.assert_clean()

    def test_opened_passages_are_cleared_when_the_session_ends(self):
        self.open_answer()
        self.page.get_by_role("button", name="Show passage: Owned router manual · chunk 1 · bbbbbbbb").click()
        expect(self.page.get_by_text("Check the WAN light, then DHCP.", exact=True)).to_be_visible()
        self.sign_out_and_back_in()
        self.reopen_chat_in_app()
        expect(self.page.get_by_text("Check the WAN light, then DHCP.", exact=True)).to_have_count(0)
        expect(self.page.get_by_role("button", name="Show passage: Owned router manual · chunk 1 · bbbbbbbb")).to_be_enabled()
        self.assert_clean()

    def test_citations_are_readable_at_desktop_and_phone_widths(self):
        self.open_answer()
        self.page.get_by_role("button", name="Show passage: Owned router manual · chunk 1 · bbbbbbbb").click()
        newest = self.page.locator(".message-row.assistant", has_text="Check the WAN link light first.")
        expect(newest.locator(".answer-references blockquote")).to_be_visible()
        for width in (1280, 390):
            self.page.set_viewport_size({"width": width, "height": 900})
            for selector in (".answer-references-title strong", ".answer-reference .knowledge-meta",
                             ".answer-reference-open", ".answer-references blockquote"):
                self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5, (width, selector))
            overflow = newest.locator(".answer-references").evaluate("el => el.scrollWidth - el.clientWidth")
            self.assertLessEqual(overflow, 0, width)
        self.assert_clean()


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(AnswerReferenceTests(name) for name in loader.getTestCaseNames(AnswerReferenceTests)
                             if name in AnswerReferenceTests.__dict__)


if __name__ == "__main__":
    unittest.main()
