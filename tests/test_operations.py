"""Operations uses real snapshot data and read-only controls with isolated HTTP fixtures."""
import copy
import os
from pathlib import Path
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST


def metric():
    return {"event_id": "e" * 32, "attempt": 1, "recorded_at": "2026-10-26T09:00:00Z",
            "stage": "SPECIALIST_REASONING", "operation": "generate", "adapter": "http",
            "role": "fixture-specialist", "outcome": "success", "repair_of": None,
            "duration_ms": 1250, "queue_ms": None, "execution_ms": None, "first_token_ms": None,
            "generated_tokens": None, "estimated_input_tokens": None, "request_token_budget": None,
            "output_token_cap": None, "dropped_messages": None}


def job(identity, chat, status, metrics):
    return {"job_id": identity * 32, "chat_id": "fixture-" + chat, "status": status, "attempt": 1,
            "selected_agent": "fixture-specialist", "created_at": "2026-10-26T08:00:00Z",
            "claimed_at": "2026-10-26T08:00:01Z", "completed_at": None,
            "queue_wait_ms": 1000, "elapsed_ms": 3000, "metrics_truncated": False, "metrics": metrics}


def snapshot():
    return {"schema": "operations-snapshot.v1", "observed_at": "2026-10-26T09:00:00Z",
            "counts": {"pending": 13, "processing": 3, "waiting_approval": 7,
                       "reconciliation_required": 0, "denied": 0, "outcome_unknown": 1,
                       "completed": 28, "failed": 2},
            "jobs": [job("a", "first", "processing", [metric()]), job("b", "second", "completed", [])]}


class OperationsTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.snapshot = snapshot()
        self.operations_status = 200
        self.operations_requests = []
        self.operations_pending = []
        self.hold_operations = False
        self.owner = "fixture-owner"
        self.history_reads = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def tearDown(self):
        for route in self.operations_pending:
            route.abort()
        self.operations_pending.clear()
        super().tearDown()

    def auth(self):
        return {"user": {"user_id": self.owner, "email": "owner@example.test",
                         "display_name": "Fixture Owner" if self.owner == "fixture-owner" else "Second Owner",
                         "role": "user"}, "session_id": "session-" + self.owner, "csrf_token": "fixture-csrf"}

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        bundle = os.getenv("OPERATIONS_TEST_BUNDLE")
        if bundle and request.url.startswith(self.base + "/") and path == "/js/app.js":
            route.fulfill(content_type="application/javascript", body=Path(bundle).read_text())
            return
        if request.url.startswith(self.base + "/api/"):
            if path in {"/api/v1/auth/me", "/api/v1/auth/login"}:
                route.fulfill(json=self.auth())
                return
            if path == "/api/v1/auth/logout":
                route.fulfill(json={"status": "signed_out"})
                return
            if path == "/api/v1/operations":
                self.operations_requests.append(request.method)
                if self.hold_operations:
                    self.operations_pending.append(route)
                elif self.operations_status != 200:
                    route.fulfill(status=self.operations_status, json={"error": "fixture-private-error-do-not-display"})
                else:
                    route.fulfill(json=self.snapshot)
                return
            if path.startswith("/api/v2/chats/") and path.endswith("/history"):
                key = path.split("/")[-2]
                self.history_reads.append(key)
                route.fulfill(json={"messages": [{"role": "user", "content":
                    "First chat history" if key == "fixture-first" else "Second chat history"}]})
                return
        super().route(route)

    def open_operations(self):
        self.open_first_chat()
        self.page.locator(".sidebar").get_by_role("button", name="Operations", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Operations")

    def assert_safe(self):
        self.assertTrue(self.operations_requests)
        self.assertTrue(all(method == "GET" for method in self.operations_requests))
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_queue_counts_and_call_measurements_come_from_snapshot(self):
        self.open_operations()
        expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("13")
        expect(self.page.locator('.operation-count[data-status="completed"] strong')).to_have_text("28")
        expect(self.page.locator(".operation-job")).to_have_count(2)
        row = self.page.locator('.operation-job[data-job-id="' + "a" * 32 + '"]')
        row.get_by_role("button", name="Show recorded calls", exact=True).click()
        expect(row.locator(".operation-call")).to_have_count(1)
        expect(row.locator(".operation-call")).to_contain_text("Specialist reasoning")
        expect(row.locator(".operation-call")).to_contain_text("1.25 s")
        expect(row.locator(".operation-call")).to_contain_text("Not recorded")
        historical = self.page.locator('.operation-job[data-job-id="' + "b" * 32 + '"]')
        expect(historical).to_contain_text("Inference timings: Not recorded")
        expect(historical.get_by_role("button", name="Show recorded calls", exact=True)).to_have_count(0)
        self.assert_safe()

    def test_counts_status_and_secondary_text_meet_wcag_aa_contrast(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_first_chat()
            # The palette reaches Operations at every width; phones hide the sidebar.
            self.page.keyboard.press("Control+k")
            self.page.locator("#commandSearch").fill("Operations")
            self.page.locator("#commandSearch").press("Enter")
            expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("13")
            self.page.get_by_role("button", name="Show recorded calls", exact=True).click()
            for selector in (".operation-count .run-label", ".operations-panel .section-heading-row span",
                             ".operation-job-heading .capability-badge", ".operation-call-outcome",
                             ".operation-measurement span", ".operations-panel .operation-note"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            # A long status label wraps inside its card instead of pushing the number out of line.
            tops = self.page.locator(".operation-count strong").evaluate_all(
                "nodes => nodes.map((node) => Math.round(node.getBoundingClientRect().bottom))")
            rows = 4 if width > 650 else 2
            for start in range(0, len(tops), rows):
                self.assertEqual(len(set(tops[start:start + rows])), 1, f"count values misaligned at {width}px")
        self.assert_safe()

    def test_refresh_uses_new_data_and_failures_cannot_display_a_zero_queue(self):
        self.open_operations()
        expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("13")
        self.operations_status = 503
        self.page.get_by_role("button", name="Refresh operations", exact=True).click()
        expect(self.page.get_by_role("alert")).to_contain_text("HTTP 503")
        expect(self.page.locator(".operation-count")).to_have_count(0)
        expect(self.page.get_by_text("fixture-private-error-do-not-display")).to_have_count(0)
        self.operations_status = 200
        self.snapshot["counts"] = {key: 0 for key in self.snapshot["counts"]}
        self.snapshot["jobs"] = []
        self.page.get_by_role("button", name="Refresh operations", exact=True).click()
        expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("0")
        expect(self.page.get_by_text("No recent tasks were returned.", exact=True)).to_be_visible()
        self.assert_safe()

    def test_invalid_snapshot_and_auth_failure_are_explicit(self):
        self.snapshot["counts"]["pending"] = False
        self.open_operations()
        expect(self.page.get_by_role("alert")).to_contain_text("response was invalid")
        expect(self.page.locator(".operation-count")).to_have_count(0)
        self.operations_status = 401
        self.page.get_by_role("button", name="Refresh operations", exact=True).click()
        expect(self.page.get_by_role("alert")).to_contain_text("HTTP 401")
        expect(self.page.locator(".operation-job")).to_have_count(0)
        self.assert_safe()

    def test_first_and_last_job_open_their_exact_saved_chat(self):
        self.open_first_chat()
        for identity, expected in (("b", "fixture-second"), ("a", "fixture-first")):
            self.page.locator(".sidebar").get_by_role("button", name="Operations", exact=True).click()
            row = self.page.locator('.operation-job[data-job-id="' + identity * 32 + '"]')
            row.get_by_role("button", name="Open chat", exact=True).click()
            expect(self.page.locator(".workspace-title h1")).to_have_text("Chat")
            expect(self.page.get_by_text("Second chat history" if expected == "fixture-second" else "First chat history",
                                         exact=True)).to_be_visible()
            self.assertEqual(self.history_reads[-1], expected)
        self.assert_safe()

    def test_command_palette_opens_operations_and_mobile_layout_keeps_measurements(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_first_chat()
            self.page.keyboard.press("Control+k")
            self.page.locator("#commandSearch").fill("Operations")
            self.page.locator("#commandSearch").press("Enter")
            expect(self.page.locator(".workspace-title h1")).to_have_text("Operations")
            expect(self.page.locator(".operation-job")).to_have_count(2)
            self.page.get_by_role("button", name="Show recorded calls", exact=True).click()
            self.assertTrue(self.page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"),
                            f"Operations overflows at {width}px")
            expect(self.page.locator(".operation-call")).to_contain_text("Generated tokens")
        self.assert_safe()

    def test_a_late_response_cannot_cross_confirmed_sign_out_and_new_owner(self):
        self.hold_operations = True
        self.open_operations()
        expect(self.page.get_by_text("Loading your operations…", exact=True)).to_be_visible()
        self.assertEqual(len(self.operations_pending), 1)
        old = copy.deepcopy(self.snapshot)
        self.page.get_by_title("More", exact=True).click()
        self.page.get_by_role("button", name="Sign out", exact=True).click()
        expect(self.page.get_by_role("button", name="Sign in", exact=True)).to_be_visible()
        self.owner = "second-owner"
        self.page.locator("label.auth-field", has_text="Email").locator("input").fill("second@example.test")
        self.page.locator("label.auth-field", has_text="Password").locator("input").fill("fixture-password")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        expect(self.page.locator(".sidebar-footer")).to_contain_text("Second Owner")
        with self.page.expect_request(lambda request: urlparse(request.url).path == "/api/v1/operations"):
            self.page.locator(".sidebar").get_by_role("button", name="Operations", exact=True).click()
        self.assertEqual(len(self.operations_pending), 2)
        self.operations_pending.pop(0).fulfill(json=old)
        self.page.evaluate("() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
        expect(self.page.get_by_text("Loading your operations…", exact=True)).to_be_visible()
        expect(self.page.locator(".operation-count")).to_have_count(0)
        own = snapshot()
        own["counts"]["pending"] = 2
        own["jobs"] = []
        self.operations_pending.pop(0).fulfill(json=own)
        expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("2")
        expect(self.page.locator(".operation-job")).to_have_count(0)
        self.assert_safe()


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(OperationsTests(name) for name in loader.getTestCaseNames(OperationsTests)
                             if name in OperationsTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
