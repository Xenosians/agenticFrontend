"""The gladiators (F1): every Janus agent is a pixel gladiator acting out what it is really doing.

A strip directly above the message box shows the hub (and the specialist he hands a request to) at 2x on
desktop and 1x on phones, never over the conversation or the composer. The Run Inspector's Ludus tab
shows every agent's gladiator in one room that zooms in whole-pixel steps. The owner can hide them in
Settings > Appearance; the choice is saved with the account. Isolated HTTP fixtures only.
Run after rebuilding: python tests/test_gladiators.py
"""
import os
import unittest
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation

CATALOG = {"resources": [], "selected": {}, "role_assignments": {}, "local_profiles": [], "capabilities": [
    {"id": "proxmox_nodes", "agent_names": ["proxmox-specialist"], "grounded_arguments": []},
    {"id": "network_router_health", "agent_names": ["networking-specialist"], "grounded_arguments": []},
]}


class GladiatorTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.gladiators_saved = True
        self.preference_writes = []
        self.job_status = None
        self.job_agent = None
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        # A separately built bundle may stand in for the shipped one while the work is in progress.
        bundle = os.getenv("SUITE_TEST_BUNDLE")
        if bundle and request.url.startswith(self.base + "/") and path == "/js/app.js":
            route.fulfill(content_type="application/javascript", headers=navigation.SECURITY_HEADERS,
                          body=Path(bundle).read_text())
            return
        if request.url.startswith(self.base + "/api/"):
            if path == "/api/v1/auth/preferences":
                if request.method == "PUT":
                    body = request.post_data_json
                    self.preference_writes.append(body)
                    self.gladiators_saved = body.get("gladiators", self.gladiators_saved)
                route.fulfill(json={"preferences": {"task_completed": True, "theme": "dark", "accent": "mono",
                                                    "pinned_views": ["knowledge", "operations"],
                                                    "gladiators": self.gladiators_saved}})
                return
            if path == "/api/v1/extensions":
                route.fulfill(json=CATALOG)
                return
            if path == "/api/v1/learning/runs":
                route.fulfill(json={"runs": []})
                return
            if self.job_status and path == "/api/v1/jobs" and request.method == "POST":
                payload = request.post_data_json
                self.submissions.append(payload)
                route.fulfill(json={"job_id": "fixture-job", "status": "pending",
                                    "submission_id": payload["submission_id"]})
                return
            if self.job_status and path == "/api/v2/jobs/fixture-job":
                body = {"contract_version": 2, "job_id": "fixture-job", "status": self.job_status}
                if self.job_agent:
                    body["selected_agent"] = self.job_agent
                if self.job_status == "completed":
                    body["result"] = {"answer": "Fixture job response"}
                route.fulfill(json=body)
                return
        super().route(route)

    def strip(self):
        return self.page.get_by_role("img", name="Janus agents", exact=True)

    def test_the_strip_sits_between_the_conversation_and_the_message_box(self):
        for viewport, scale in (({"width": 1440, "height": 900}, 2), ({"width": 390, "height": 760}, 1)):
            with self.subTest(viewport=viewport):
                self.page.set_viewport_size(viewport)
                self.open_first_chat()
                strip = self.page.locator(".gladiator-strip")
                expect(strip).to_be_visible()
                hub = strip.locator('.gladiator[data-agent="hub"]')
                expect(hub).to_be_visible()
                box = hub.bounding_box()
                # Whole-pixel scale only: 32x40 art at 2x on desktop, 1x on phones.
                self.assertEqual((round(box["width"]), round(box["height"])), (32 * scale, 40 * scale))
                strip_box = strip.bounding_box()
                composer = self.page.locator(".composer-container").bounding_box()
                conversation = self.page.locator(".conversation").bounding_box()
                # Nothing overlaps: the strip ends where the message box begins and starts below the chat.
                self.assertLessEqual(strip_box["y"] + strip_box["height"], composer["y"] + 1)
                self.assertGreaterEqual(strip_box["y"], conversation["y"] + conversation["height"] - 1)
                self.assertFalse(self.page.evaluate(
                    "() => document.documentElement.scrollWidth > window.innerWidth"))
                self.assertEqual(self.errors, [])

    def test_the_hub_acts_out_the_job_and_names_what_he_is_doing(self):
        self.job_status = "processing"
        self.open_first_chat()
        hub = self.page.locator('.gladiator-strip .gladiator[data-agent="hub"]')
        expect(hub).to_have_attribute("data-state", "walking")
        self.page.locator("#messageInput").fill("Check node hummingbird")
        self.page.locator("#messageInput").press("Enter")
        expect(hub).to_have_attribute("data-state", "thinking")
        expect(hub).to_have_attribute("title", "Janus (hub): thinking")
        # Once the server names the specialist, he joins the strip and does the work.
        self.job_agent = "proxmox-specialist"
        self.job_status = "waiting_approval"
        specialist = self.page.locator('.gladiator-strip .gladiator[data-agent="proxmox-specialist"]')
        expect(specialist).to_have_attribute("data-state", "waiting")
        expect(hub).to_have_attribute("data-talking-to", "proxmox-specialist")
        self.assertEqual(self.errors, [])

    def test_the_ludus_shows_every_agent_and_zooms_in_whole_steps(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        self.page.get_by_role("contentinfo", name="Status", exact=True).get_by_role(
            "button", name="Run inspector", exact=True).click()
        tabs = self.page.locator(".inspector-tabs button")
        expect(tabs).to_have_text(["Run", "Events", "Raw", "Ludus"])
        self.page.locator(".inspector-tabs").get_by_role("button", name="Ludus", exact=True).click()
        room = self.page.get_by_role("region", name="Ludus", exact=True)
        agents = room.locator(".gladiator")
        expect(agents).to_have_count(3)  # the hub and the two specialists the catalog names
        # Each stands in the area of his state: idle specialists in the barracks, the hub in the arena.
        self.assertEqual(room.locator('[data-area="Barracks"] .gladiator').evaluate_all(
            "nodes => nodes.map(n => n.dataset.agent)"), ["networking-specialist", "proxmox-specialist"])
        self.assertEqual(room.locator('[data-area="Arena"] .gladiator').evaluate_all(
            "nodes => nodes.map(n => n.dataset.agent)"), ["hub"])
        zoom = room.locator(".ludus-zoom-level")
        start = int(zoom.get_attribute("data-zoom"))
        room.get_by_role("button", name="Zoom in", exact=True).click()
        expect(zoom).to_have_attribute("data-zoom", str(min(start + 1, 4)))
        hub = room.locator('.gladiator[data-agent="hub"]').bounding_box()
        self.assertEqual(round(hub["width"]), 32 * min(start + 1, 4))
        zoom_out = room.get_by_role("button", name="Zoom out", exact=True)
        for _ in range(min(start + 1, 4) - 1):
            zoom_out.click()
        expect(zoom).to_have_attribute("data-zoom", "1")
        # At the smallest step the control says so instead of doing nothing.
        expect(zoom_out).to_be_disabled()
        # Choosing a gladiator says who he is and what his agent is doing.
        room.locator('.gladiator[data-agent="proxmox-specialist"]').click()
        expect(room.locator(".ludus-focus")).to_contain_text("Proxmox specialist")
        expect(room.locator(".ludus-focus")).to_contain_text("asleep")
        self.assertEqual(self.errors, [])

    def test_the_owner_can_hide_the_gladiators_and_the_choice_is_saved(self):
        self.open_first_chat()
        expect(self.page.locator(".gladiator-strip")).to_be_visible()
        self.page.locator(".rail-navigation").get_by_role("button", name="Settings", exact=True).click()
        switch = self.page.get_by_role("checkbox", name="Show the agents' gladiators")
        expect(switch).to_be_checked()
        switch.click()
        expect(switch).not_to_be_checked()
        self.assertEqual(self.preference_writes, [{"gladiators": False}])
        self.page.reload(wait_until="networkidle")
        self.page.locator(".rail-navigation").get_by_role("button", name="Chat", exact=True).click()
        expect(self.page.get_by_text("First chat history", exact=True)).to_be_visible()
        expect(self.page.locator(".gladiator-strip")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_reduced_motion_holds_a_still_pose(self):
        self.page.emulate_media(reduced_motion="reduce")
        self.open_first_chat()
        hub = self.page.locator('.gladiator-strip .gladiator[data-agent="hub"]')
        expect(hub).to_be_visible()
        self.assertEqual(hub.evaluate("node => getComputedStyle(node).animationName"), "none")
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(GladiatorTests(name) for name in loader.getTestCaseNames(GladiatorTests)
                             if name in GladiatorTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
