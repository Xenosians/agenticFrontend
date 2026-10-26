"""Feedback on a result (FR-089): the user's critique or correction of an answer
is saved for review, linked to its task. Saving it changes nothing else.

Isolated HTTP fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_job_feedback.py
"""
import re
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST

SUBMISSION_IDENTITY = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


class JobFeedbackTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.feedback_requests = []
        self.feedback_status = 201
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/api/"):
            if path == "/api/v2/chats/fixture-first/history":
                route.fulfill(json={"messages": [
                    {"role": "user", "content": "First chat history", "job_id": "fixture-job",
                     "status": "completed"},
                    {"role": "assistant", "content": "Fixture job response", "job_id": "fixture-job",
                     "status": "completed"},
                ]})
                return
            if path == "/api/v1/jobs/fixture-job/feedback" and request.method == "POST":
                body = request.post_data_json
                self.feedback_requests.append({"body": body, "csrf": request.headers.get("x-csrf-token")})
                if self.feedback_status != 201:
                    route.fulfill(status=self.feedback_status, json={
                        "error": "feedback_save_failed", "message": "The feedback could not be saved."})
                    return
                route.fulfill(status=201, json={"feedback": {
                    "job_id": "fixture-job", "submission_id": body["submission_id"], "note": body["note"],
                    "review_status": "pending_review"}})
                return
        super().route(route)

    def open_answer(self):
        self.open_first_chat()
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()

    def write_feedback(self, note, correction=""):
        self.page.get_by_role("button", name="Give feedback", exact=True).click()
        send = self.page.get_by_role("button", name="Send feedback", exact=True)
        expect(send).to_be_disabled()
        self.page.get_by_label("What was wrong?", exact=True).fill(note)
        if correction:
            self.page.get_by_label("Correct result (optional)", exact=True).fill(correction)
        expect(send).to_be_enabled()
        return send

    def test_feedback_on_an_answer_is_saved_for_review_with_its_task(self):
        self.open_answer()
        self.write_feedback("It listed closed tickets", "Only the open tickets").click()
        expect(self.page.locator(".message-feedback-status")).to_have_text("Feedback saved for review.")
        self.assertEqual(len(self.feedback_requests), 1)
        sent = self.feedback_requests[0]
        self.assertEqual(sent["csrf"], "fixture-csrf")
        self.assertRegex(sent["body"].pop("submission_id"), SUBMISSION_IDENTITY)
        self.assertEqual(sent["body"], {"note": "It listed closed tickets", "correction": "Only the open tickets"})
        # Saved feedback closes the form; the answer is unchanged.
        expect(self.page.get_by_role("button", name="Send feedback", exact=True)).to_have_count(0)
        expect(self.page.get_by_text("Fixture job response", exact=True)).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_an_unsaved_note_is_kept_and_sent_again_as_the_same_feedback(self):
        self.open_answer()
        self.feedback_status = 500
        self.write_feedback("It listed closed tickets").click()
        expect(self.page.locator(".message-feedback-error")).to_contain_text("Feedback was not saved.")
        expect(self.page.get_by_label("What was wrong?", exact=True)).to_have_value("It listed closed tickets")
        self.feedback_status = 201
        self.page.get_by_role("button", name="Send feedback", exact=True).click()
        expect(self.page.locator(".message-feedback-status")).to_have_text("Feedback saved for review.")
        identities = [sent["body"]["submission_id"] for sent in self.feedback_requests]
        self.assertEqual(len(identities), 2)
        self.assertEqual(identities[0], identities[1], "a resent note must keep its feedback identity")
        self.assertEqual(self.errors, [])

    def test_only_answers_from_a_saved_task_offer_feedback_and_cancel_sends_nothing(self):
        self.open_answer()
        expect(self.page.get_by_role("button", name="Give feedback", exact=True)).to_have_count(1)
        toggle_contrast = self.page.evaluate(CONTRAST, ".message-feedback-toggle")
        self.assertGreaterEqual(toggle_contrast, 4.5)
        self.write_feedback("Draft that is not sent")
        self.page.get_by_role("button", name="Cancel", exact=True).click()
        expect(self.page.get_by_label("What was wrong?", exact=True)).to_have_count(0)
        expect(self.page.get_by_role("button", name="Give feedback", exact=True)).to_be_visible()
        self.assertEqual(self.feedback_requests, [])
        self.assertEqual(self.errors, [])

    def test_the_feedback_form_matches_the_answer_it_describes(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_answer()
            self.write_feedback("It listed closed tickets")
            layout = self.page.evaluate("""() => {
                const bubble = document.querySelector('.message-row.assistant .message-bubble');
                const textLeft = bubble.getBoundingClientRect().left + parseFloat(getComputedStyle(bubble).paddingLeft);
                const font = (selector) => getComputedStyle(document.querySelector(selector)).fontSize;
                const form = document.querySelector('.message-feedback-form').getBoundingClientRect();
                return {
                    answerTextLeft: Math.round(textLeft),
                    formLeft: Math.round(form.left),
                    formRight: Math.round(form.right),
                    columnRight: Math.round(bubble.parentElement.getBoundingClientRect().right),
                    fieldWidth: Math.round(document.querySelector('.message-feedback-field textarea').getBoundingClientRect().width),
                    answerFont: font('.message-row.assistant .message-bubble'),
                    fieldFont: font('.message-feedback-field textarea'),
                    buttonFont: font('.message-feedback-actions button'),
                };
            }""")
            # The form lines up with the answer's text and uses its type size.
            self.assertEqual(layout["formLeft"], layout["answerTextLeft"], f"form edge at {width}px")
            self.assertEqual(layout["fieldFont"], layout["answerFont"], f"field text at {width}px")
            self.assertEqual(layout["buttonFont"], layout["answerFont"], f"button text at {width}px")
            # Room to write a correction, without leaving the answer's column.
            self.assertLessEqual(layout["formRight"], layout["columnRight"], f"form overflows at {width}px")
            if width >= 1024:
                self.assertGreaterEqual(layout["fieldWidth"], 400, "the correction field is cramped")
            self.page.reload(wait_until="networkidle")
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(JobFeedbackTests(name) for name in loader.getTestCaseNames(JobFeedbackTests)
                             if name in JobFeedbackTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
