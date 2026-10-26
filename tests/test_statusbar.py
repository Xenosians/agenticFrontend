"""The status bar (FR-077, FR-080): Hermes-style persistent service and job state.

One full-width row under the panes: backend and AI runtime health from the
public health endpoint (re-read on the configured cadence), the live-update
state of an observed job on every page, and the run inspector toggle.
Isolated HTTP fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_statusbar.py
"""
import json
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation

READY = {"status": "ok", "ai_service": {"reachable": True, "healthy": True, "ready": True}}
STARTING = {"status": "ok", "ai_service": {"reachable": True, "healthy": True, "ready": False}}
AI_DOWN = {"status": "ok", "ai_service": {"reachable": False, "healthy": False, "ready": False}}

CONTRAST = """(selector) => {
    const channel = (value) => { value /= 255; return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4; };
    const luminance = (color) => {
        const [r, g, b] = color.match(/[0-9.]+/g).map(Number);
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
    };
    // Text against the nearest painted background, with inherited opacity applied.
    const node = document.querySelector(selector);
    let opacity = 1, surface = null;
    for (let current = node; current; current = current.parentElement) {
        const style = getComputedStyle(current);
        opacity *= Number(style.opacity);
        const match = style.backgroundColor.match(/[0-9.]+/g);
        if (!surface && match && (match.length < 4 || Number(match[3]) > 0)) surface = style.backgroundColor;
    }
    const page = luminance(surface || getComputedStyle(document.body).backgroundColor);
    const text = page + (luminance(getComputedStyle(node).color) - page) * opacity;
    return (Math.max(text, page) + 0.05) / (Math.min(text, page) + 0.05);
}"""


class StatusbarTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.health = READY
        self.health_requests = 0
        self.health_interval_ms = None
        self.job_status = None  # None: the shared fixture completes jobs at once.
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/"):
            if path == "/config.js" and self.health_interval_ms:
                route.fulfill(content_type="application/javascript", body=(
                    "window.AGENTIC_CONFIG = Object.freeze({backendBaseUrl:" + json.dumps(self.base)
                    + ",pollIntervalMs:10,healthIntervalMs:" + str(self.health_interval_ms) + "});"))
                return
            if path == "/api/health":
                self.health_requests += 1
                if self.health is None:
                    route.fulfill(status=503, json={"error": "fixture outage"})
                else:
                    route.fulfill(json=self.health)
                return
            if self.job_status and path == "/api/v1/jobs" and request.method == "POST":
                payload = request.post_data_json
                self.submissions.append(payload)
                route.fulfill(json={"job_id": "fixture-job", "status": "pending",
                                    "submission_id": payload["submission_id"]})
                return
            if self.job_status and path == "/api/v2/jobs/fixture-job":
                result = {"answer": "Fixture job response"} if self.job_status == "completed" else {}
                route.fulfill(json={"contract_version": 2, "job_id": "fixture-job",
                                    "status": self.job_status, "result": result})
                return
        super().route(route)

    def bar(self):
        return self.page.get_by_role("contentinfo", name="Status", exact=True)

    def test_the_bar_spans_the_window_under_the_panes(self):
        for viewport in ({"width": 1440, "height": 900}, {"width": 390, "height": 760}):
            with self.subTest(viewport=viewport):
                self.page.set_viewport_size(viewport)
                self.open_first_chat()
                expect(self.bar()).to_be_visible()
                box = self.bar().bounding_box()
                self.assertAlmostEqual(box["x"], 0, delta=1)
                self.assertAlmostEqual(box["x"] + box["width"], viewport["width"], delta=1)
                self.assertAlmostEqual(box["y"] + box["height"], viewport["height"], delta=1)
                # The composer ends where the bar begins, and nothing scrolls sideways.
                composer = self.page.locator(".composer-container").bounding_box()
                self.assertLessEqual(composer["y"] + composer["height"], box["y"] + 1)
                self.assertFalse(self.page.evaluate(
                    "() => document.documentElement.scrollWidth > window.innerWidth"))
                # Small text on and just above the bar, and the sidebar's
                # product tagline and section labels, stay readable (WCAG AA, 4.5:1).
                for selector in (".statusbar-health", ".composer-hint", ".brand-copy span", ".section-label"):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5, selector)
                self.assertEqual(self.errors, [])

    def test_service_health_is_named_and_opens_system_status(self):
        self.open_first_chat()
        health = self.bar().get_by_role("button", name="Services ready", exact=True)
        expect(health).to_be_visible()
        health.click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("System")
        self.assertEqual(self.errors, [])

    def test_health_changes_appear_without_a_reload(self):
        self.health_interval_ms = 40
        # A fast health cadence keeps the network busy, so wait for content
        # rather than network idle.
        self.page.goto(self.base + "/")
        expect(self.page.get_by_text("First chat history", exact=True)).to_be_visible()
        bar = self.bar()
        expect(bar).to_contain_text("Services ready")
        for health, label in ((STARTING, "AI runtime starting"), (AI_DOWN, "AI runtime unavailable"),
                              (None, "Backend unavailable"), (READY, "Services ready")):
            with self.subTest(label=label):
                self.health = health
                expect(bar.locator(".statusbar-health")).to_have_text(label)
        self.assertEqual(self.errors, [])

    def test_without_a_configured_cadence_health_is_read_once(self):
        self.open_first_chat()
        expect(self.bar()).to_contain_text("Services ready")
        reads = self.health_requests
        self.page.wait_for_timeout(300)
        self.assertEqual(self.health_requests, reads)
        self.assertEqual(self.errors, [])

    def test_an_observed_job_stays_visible_on_every_page(self):
        self.job_status = "processing"
        self.open_first_chat()
        self.page.locator("#messageInput").fill("Fixture request")
        self.page.locator("#messageInput").press("Enter")
        job = self.bar().locator(".statusbar-job")
        # The fixture has no WebSocket, so the job is observed by polling.
        expect(job).to_contain_text("Checking for updates")
        self.page.locator(".sidebar").get_by_role("button", name="Capabilities", exact=True).click()
        expect(job).to_be_visible()
        job.click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Activity")
        self.job_status = "completed"
        expect(job).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_the_inspector_toggle_reflects_and_changes_the_rail(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        toggle = self.bar().get_by_role("button", name="Run inspector", exact=True)
        expect(toggle).to_have_attribute("aria-pressed", "false")
        toggle.click()
        expect(self.page.locator(".inspector")).to_be_visible()
        expect(toggle).to_have_attribute("aria-pressed", "true")
        toggle.click()
        expect(self.page.locator(".inspector")).to_have_count(0)
        # Where the layout has no room for the rail, the toggle is not offered.
        self.page.set_viewport_size({"width": 1000, "height": 800})
        expect(toggle).to_be_hidden()
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(StatusbarTests(name) for name in loader.getTestCaseNames(StatusbarTests)
                             if name in StatusbarTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
