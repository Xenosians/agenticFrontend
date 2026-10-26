"""The reviewer queue for feedback (FR-089), with isolated HTTP fixtures.

Only administrators see Review. A decision needs a reason, is sent once, and
the queue states that a decision never changes the task.
"""
import copy
import unittest
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST

PENDING = "a" * 32
DECIDED = "c" * 32


def queue():
    return {"feedback": [
        {"feedback_id": PENDING, "job_id": "b" * 32, "chat_id": "fixture-first", "kind": "correction",
         "note": "It missed the VPN tickets", "correction": "List SUP-14 too",
         "review_status": "pending_review", "created_at": "2026-10-26T09:00:00Z",
         "subject": {"request": "List the open VPN tickets", "answer": "No open VPN tickets.",
                     "status": "completed", "selected_agent": "fixture-issues"}},
    ]}


def decided():
    return {"feedback_id": DECIDED, "job_id": "d" * 32, "chat_id": "fixture-second", "kind": "critique",
            "note": "It answered too late", "correction": None, "review_status": "dismissed",
            "created_at": "2026-10-26T08:00:00Z",
            "review": {"decision": "dismissed", "reason": "Expected latency", "reviewer_id": "fixture-admin",
                       "reviewed_at": "2026-10-26T10:00:00Z"},
            "subject": {"request": "Show my tickets", "answer": None, "status": "failed"}}


class FeedbackReviewTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.role = "admin"
        self.queue = queue()
        self.queue_reads = []
        self.decisions = []
        self.decision_status = 200
        self.defer_queue = False
        self.defer_decision = False
        self.pending_queue = []
        self.pending_decision = []
        self.decision_receipt = None
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        url = urlparse(request.url)
        if request.url.startswith(self.base + "/api/"):
            if url.path == "/api/v1/auth/me":
                # Same owner as the inherited chat fixtures; only the role differs.
                route.fulfill(json={"user": {"user_id": "fixture-owner", "email": "owner@example.test",
                                             "display_name": "Fixture Owner", "role": self.role},
                                    "session_id": "fixture-session", "csrf_token": "fixture-csrf"})
                return
            if url.path == "/api/v1/feedback/review" and request.method == "GET":
                self.queue_reads.append(parse_qs(url.query))
                body = copy.deepcopy(self.queue)
                if parse_qs(url.query).get("status") == ["all"]:
                    body["feedback"].append(decided())
                if self.defer_queue:
                    self.pending_queue.append((route, body))
                    return
                route.fulfill(json=body)
                return
            if url.path == f"/api/v1/feedback/{PENDING}/review" and request.method == "POST":
                self.decisions.append({"body": request.post_data_json,
                                       "csrf": request.headers.get("x-csrf-token")})
                if self.decision_status != 200:
                    route.fulfill(status=self.decision_status,
                                  json={"error": "review_conflict",
                                        "detail": "This feedback already has a different decision."})
                    return
                record = copy.deepcopy(self.queue["feedback"][0])
                record["review_status"] = request.post_data_json["decision"]
                record["review"] = dict(request.post_data_json, reviewer_id="fixture-admin",
                                        reviewed_at="2026-10-26T11:00:00Z")
                self.queue["feedback"] = []
                if self.defer_decision:
                    self.pending_decision.append((route, record))
                    return
                route.fulfill(json=self.decision_receipt if self.decision_receipt is not None else {"feedback": record})
                return
        super().route(route)

    def open_review(self):
        self.open_first_chat()
        self.page.locator(".sidebar").get_by_role("button", name="Review", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Review")

    def test_reviewer_reads_the_subject_and_records_one_decision_with_a_reason(self):
        self.open_review()
        item = self.page.locator(f'.review-item[data-feedback-id="{PENDING}"]')
        expect(item).to_contain_text("It missed the VPN tickets")
        expect(item).to_contain_text("List SUP-14 too")
        expect(item).to_contain_text("List the open VPN tickets")
        expect(item).to_contain_text("No open VPN tickets.")
        expect(item).to_contain_text("Pending review")
        expect(self.page.locator(".review-panel")).to_contain_text("never changes the task")

        accept = item.get_by_role("button", name="Accept", exact=True)
        expect(accept).to_be_disabled()  # A decision needs a reason.
        item.get_by_label("Reason").fill("Valid: the search dropped a status filter")
        accept.click()
        expect(self.page.locator(".review-panel")).to_contain_text("No feedback waits for review")
        self.assertEqual(self.decisions, [{"body": {"decision": "accepted",
                                                    "reason": "Valid: the search dropped a status filter"},
                                           "csrf": "fixture-csrf"}])
        self.assertEqual(self.errors, [])

    def test_decided_feedback_shows_its_decision_and_cannot_be_decided_again(self):
        self.open_review()
        self.page.get_by_role("button", name="Show decided", exact=True).click()
        item = self.page.locator(f'.review-item[data-feedback-id="{DECIDED}"]')
        expect(item).to_contain_text("Dismissed")
        expect(item).to_contain_text("Expected latency")
        expect(item).to_contain_text("No answer was recorded")
        expect(item.get_by_role("button", name="Accept", exact=True)).to_have_count(0)
        self.assertEqual(self.queue_reads[-1], {"status": ["all"]})
        self.assertEqual(self.errors, [])

    def test_trimmed_reason_receipt_confirms_the_submitted_decision(self):
        self.open_review()
        item = self.page.locator(f'.review-item[data-feedback-id="{PENDING}"]')
        item.get_by_label("Reason").fill("  Checked against the saved task  ")
        item.get_by_role("button", name="Accept", exact=True).click()
        expect(self.page.locator(".review-panel")).to_contain_text("No feedback waits for review")
        self.assertEqual(self.decisions, [{"body": {"decision": "accepted",
                                                    "reason": "Checked against the saved task"},
                                           "csrf": "fixture-csrf"}])
        expect(self.page.locator(".review-panel").get_by_role("alert")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_a_refused_decision_is_stated_and_the_record_stays_pending(self):
        self.decision_status = 409
        self.open_review()
        item = self.page.locator(f'.review-item[data-feedback-id="{PENDING}"]')
        item.get_by_label("Reason").fill("Not reproducible")
        item.get_by_role("button", name="Dismiss", exact=True).click()
        expect(item.get_by_role("alert")).to_contain_text("already has a different decision")
        expect(item).to_contain_text("Pending review")
        self.assertEqual(len(self.decisions), 1)
        self.assertEqual(self.errors, [])

    def test_people_who_are_not_reviewers_do_not_see_review(self):
        self.role = "user"
        self.open_first_chat()
        expect(self.page.locator(".sidebar").get_by_role("button", name="Review", exact=True)).to_have_count(0)
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Review feedback")
        expect(self.page.locator(".command-center-row", has_text="Review feedback")).to_have_count(0)
        self.assertEqual(self.queue_reads, [])

    def test_refresh_and_filter_cannot_invalidate_an_inflight_decision(self):
        self.open_review()
        self.defer_decision = True
        item = self.page.locator(f'.review-item[data-feedback-id="{PENDING}"]')
        item.get_by_label("Reason").fill("The filter was dropped")
        with self.page.expect_request(lambda req: req.method == "POST" and req.url.endswith("/review")):
            item.get_by_role("button", name="Accept", exact=True).click()
        expect(item.get_by_role("button", name="Saving…", exact=True)).to_be_disabled()
        expect(self.page.get_by_role("button", name="Refresh review", exact=True)).to_be_disabled()
        expect(self.page.get_by_role("button", name="Show decided", exact=True)).to_be_disabled()
        self.assertEqual(len(self.pending_decision), 1)
        route, record = self.pending_decision.pop()
        route.fulfill(json={"feedback": record})
        expect(self.page.locator(".review-panel")).to_contain_text("No feedback waits for review")
        expect(self.page.get_by_role("button", name="Refresh review", exact=True)).to_be_enabled()
        expect(self.page.get_by_role("button", name="Show decided", exact=True)).to_be_enabled()
        self.assertEqual(len(self.decisions), 1)
        self.assertEqual(len(self.queue_reads), 1)
        self.assertEqual(self.errors, [])

    def test_a_queue_read_blocks_decisions_until_its_result_arrives(self):
        self.open_review()
        item = self.page.locator(f'.review-item[data-feedback-id="{PENDING}"]')
        item.get_by_label("Reason").fill("The filter was dropped")
        self.defer_queue = True
        with self.page.expect_request(lambda req: req.method == "GET" and "/feedback/review" in req.url):
            self.page.get_by_role("button", name="Refresh review", exact=True).click()
        expect(item.get_by_role("button", name="Accept", exact=True)).to_be_disabled()
        expect(item.get_by_role("button", name="Dismiss", exact=True)).to_be_disabled()
        expect(self.page.get_by_role("button", name="Show decided", exact=True)).to_be_disabled()
        self.assertEqual(len(self.pending_queue), 1)
        route, body = self.pending_queue.pop()
        route.fulfill(json=body)
        expect(item.get_by_role("button", name="Accept", exact=True)).to_be_enabled()
        expect(self.page.get_by_role("button", name="Refresh review", exact=True)).to_be_enabled()
        item.get_by_role("button", name="Accept", exact=True).click()
        expect(self.page.locator(".review-panel")).to_contain_text("No feedback waits for review")
        self.assertEqual(len(self.decisions), 1)
        self.assertEqual(self.errors, [])

    def test_malformed_queue_success_is_an_error_not_an_empty_queue(self):
        for malformed in ({"detail": "unreadable"}, {"feedback": [{"feedback_id": PENDING}]}):
            with self.subTest(body=malformed):
                self.queue = malformed
                self.open_review()
                expect(self.page.locator(".review-panel").get_by_role("alert")).to_contain_text("response was invalid")
                expect(self.page.locator(".review-panel")).not_to_contain_text("No feedback waits for review")
                expect(self.page.locator(".review-item")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_mismatched_decision_receipts_keep_the_result_unconfirmed(self):
        for mismatch in ("identity", "decision", "reason", "pending", "envelope"):
            with self.subTest(mismatch=mismatch):
                self.queue = queue()
                record = copy.deepcopy(self.queue["feedback"][0])
                record["review_status"] = "accepted"
                record["review"] = {"decision": "accepted", "reason": "Checked", "reviewer_id": "fixture-admin",
                                    "reviewed_at": "2026-10-26T11:00:00Z"}
                if mismatch == "identity":
                    record["feedback_id"] = DECIDED
                elif mismatch == "decision":
                    record["review_status"] = record["review"]["decision"] = "dismissed"
                elif mismatch == "reason":
                    record["review"]["reason"] = "A different reason"
                elif mismatch == "pending":
                    record["review_status"] = "pending_review"
                    record.pop("review")
                self.decision_receipt = {"feedback": record} if mismatch != "envelope" else {"saved": True}
                self.open_review()
                item = self.page.locator(f'.review-item[data-feedback-id="{PENDING}"]')
                item.get_by_label("Reason").fill("Checked")
                before = len(self.decisions)
                item.get_by_role("button", name="Accept", exact=True).click()
                expect(item.get_by_role("alert")).to_contain_text("Refresh the queue before deciding again")
                expect(item).to_contain_text("Pending review")
                self.assertEqual(len(self.decisions), before + 1)
        self.assertEqual(self.errors, [])

    def test_review_text_meets_wcag_aa_contrast(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_first_chat()
            self.page.keyboard.press("Control+k")
            self.page.locator("#commandSearch").fill("Review feedback")
            self.page.locator("#commandSearch").press("Enter")
            expect(self.page.locator(".workspace-title h1")).to_have_text("Review")
            expect(self.page.locator(f'.review-item[data-feedback-id="{PENDING}"]')).to_be_visible()
            for selector in (".review-item .review-status", ".review-item .review-label",
                             ".review-panel .operation-note", ".review-item .review-subject",
                             ".review-item .review-reason"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            # The reason field uses the page's body text size, not the browser default.
            sizes = self.page.evaluate("""() => [
                getComputedStyle(document.querySelector('.review-item .review-reason')).fontSize,
                getComputedStyle(document.querySelector('.review-item .review-subject')).fontSize]""")
            self.assertEqual(sizes[0], sizes[1])
            overflow = self.page.evaluate(
                "document.documentElement.scrollWidth > document.documentElement.clientWidth")
            self.assertFalse(overflow, f"horizontal overflow at {width}px")


if __name__ == "__main__":
    unittest.main()
