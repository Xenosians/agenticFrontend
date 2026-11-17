"""The gladiators (F1): every Janus agent is a pixel gladiator acting out what it is really doing.

A strip directly above the message box shows the hub (and the specialist he hands a request to) at 2x on
desktop and 1x on phones, never over the conversation or the composer. The Run Inspector's Ludus tab
seats every agent at his own desk in one room (F1b) that zooms in whole-pixel steps and opens large. The owner can hide them in
Settings > Appearance; the choice is saved with the account. Isolated HTTP fixtures only.
Run after rebuilding: python tests/test_gladiators.py
"""
import json
import os
import re
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
        self.job_socket = None
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
            if self.job_status and path == "/api/v2/jobs/socket-token":
                route.fulfill(json={"token": "fixture-socket-token"})
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

    def serve_job_socket(self):
        """A stand-in for Phoenix's job channel: joins, then lets the test push progress frames."""
        def handler(socket):
            def on_message(message):
                frame = json.loads(message)
                if frame[3] == "phx_join":
                    socket.send(json.dumps([frame[0], frame[1], frame[2], "phx_reply", {
                        "status": "ok", "response": {"job_id": "fixture-job", "status": "processing",
                                                     "attempts": 1}}]))
                    self.job_socket = (socket, frame[0])
                elif frame[2] == "phoenix":
                    socket.send(json.dumps([None, frame[1], "phoenix", "phx_reply",
                                                          {"status": "ok", "response": {}}]))
            socket.on_message(on_message)
        self.page.route_web_socket("**/socket/websocket**", handler)

    def push_progress(self, stage, agent=None):
        socket, join_ref = self.job_socket
        payload = {"job_id": "fixture-job", "attempt": 1, "stage": stage}
        if agent is not None:
            payload["agent"] = agent
        socket.send(json.dumps([join_ref, None, "job:fixture-job", "job_progress", payload]))

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

    def test_the_hub_hands_the_request_to_the_specialist_while_the_job_runs(self):
        # Live progress names the agent doing each step, so the hand-off shows before any approval.
        self.job_status = "processing"
        self.serve_job_socket()
        self.open_first_chat()
        hub = self.page.locator('.gladiator-strip .gladiator[data-agent="hub"]')
        specialist = self.page.locator('.gladiator-strip .gladiator[data-agent="proxmox-specialist"]')
        self.page.locator("#messageInput").fill("Check node hummingbird")
        self.page.locator("#messageInput").press("Enter")
        expect(hub).to_have_attribute("data-state", "thinking")
        deadline = 50
        while self.job_socket is None and deadline:
            self.page.wait_for_timeout(100)
            deadline -= 1
        self.assertIsNotNone(self.job_socket, "the job socket never joined")
        self.push_progress("routing", "hub")
        expect(hub).to_have_attribute("data-state", "thinking")
        expect(specialist).to_have_count(0)
        self.push_progress("planning", "proxmox-specialist")
        expect(specialist).to_have_attribute("data-state", "thinking")
        expect(hub).to_have_attribute("data-talking-to", "proxmox-specialist")
        self.push_progress("executing", "proxmox-specialist")
        expect(specialist).to_have_attribute("data-state", "working")
        # The hub writes the answer alone; a name that is not a plain agent name is never shown.
        self.push_progress("synthesizing", "hub")
        expect(hub).to_have_attribute("data-state", "working")
        expect(hub).to_have_attribute("data-talking-to", "")
        expect(specialist).to_have_count(0)
        self.push_progress("planning", "<img src=x>")
        expect(self.page.locator('.gladiator-strip .gladiator')).to_have_count(1)
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
        desks = room.locator(".agents-room .room-desk")
        expect(desks).to_have_count(3)  # the hub and the two specialists the catalog names
        zoom = room.locator(".ludus-zoom-level")
        start = int(zoom.get_attribute("data-zoom"))
        room.get_by_role("button", name="Zoom in", exact=True).click()
        expect(zoom).to_have_attribute("data-zoom", str(min(start + 1, 4)))
        hub = room.locator('.room-desk[data-agent="hub"]').bounding_box()
        self.assertEqual(round(hub["width"]), 80 * min(start + 1, 4))
        zoom_out = room.get_by_role("button", name="Zoom out", exact=True)
        for _ in range(min(start + 1, 4) - 1):
            zoom_out.click()
        expect(zoom).to_have_attribute("data-zoom", "1")
        # At the smallest step the control says so instead of doing nothing.
        expect(zoom_out).to_be_disabled()
        # Choosing a desk says who works there and what his agent is doing.
        room.locator('.room-desk[data-agent="proxmox-specialist"]').click()
        expect(room.locator(".ludus-focus")).to_contain_text("Proxmox specialist")
        expect(room.locator(".ludus-focus")).to_contain_text("asleep")
        self.assertEqual(self.errors, [])

    def open_ludus(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        self.page.get_by_role("contentinfo", name="Status", exact=True).get_by_role(
            "button", name="Run inspector", exact=True).click()
        self.page.locator(".inspector-tabs").get_by_role("button", name="Ludus", exact=True).click()
        return self.page.get_by_role("region", name="Ludus", exact=True)

    def test_the_agents_room_seats_every_agent_at_his_own_desk_and_opens_large(self):
        room = self.open_ludus()
        office = room.get_by_role("group", name="Agents' room", exact=True)
        desks = office.locator(".room-desk")
        # One desk per agent the catalog names, the hub's first; nothing is invented.
        self.assertEqual(desks.evaluate_all("nodes => nodes.map(n => n.dataset.agent)"),
                         ["hub", "networking-specialist", "proxmox-specialist"])
        hub = office.locator('.room-desk[data-agent="hub"]')
        expect(hub).to_have_attribute("data-pose", "idle")
        expect(office.locator('.room-desk[data-agent="proxmox-specialist"]')).to_have_attribute("data-pose", "dozing")
        expect(office.locator('.room-desk[data-agent="proxmox-specialist"]')).to_have_attribute("data-screen", "off")
        # Each desk says whose it is and what he is doing, for people who cannot see the art.
        expect(office.locator('.room-desk[data-agent="proxmox-specialist"]')).to_have_attribute(
            "aria-label", "Proxmox specialist, asleep")
        # The top bar: no request yet, nothing counted but those asleep.
        bar = room.locator(".room-topbar")
        expect(bar.locator(".room-step")).to_have_attribute("aria-valuenow", "0")
        expect(bar.locator(".room-counter[data-counter=\"busy\"]")).to_contain_text("0")
        # Every desk at whole-pixel scale: a workstation is 80 x 40 art pixels at zoom 1.
        zoom = int(room.locator(".ludus-zoom-level").get_attribute("data-zoom"))
        box = hub.bounding_box()
        self.assertEqual((round(box["width"]), round(box["height"])), (80 * zoom, 40 * zoom))
        # The room fits the inspector: nothing scrolls sideways at the first step.
        self.assertFalse(room.locator(".ludus-viewport").evaluate("node => node.scrollWidth > node.clientWidth"))
        # Expand opens the same room large over the conversation; Escape closes it and focus returns.
        room.get_by_role("button", name="Expand the agents' room", exact=True).click()
        dialog = self.page.get_by_role("dialog", name="Agents' room", exact=True)
        expect(dialog).to_be_visible()
        large = dialog.locator('.room-desk[data-agent="hub"]').bounding_box()
        self.assertGreater(large["width"], box["width"])
        self.assertEqual(round(large["width"]) % 80, 0)
        # Expanded, the whole room fits the window without scrolling.
        self.assertFalse(dialog.locator(".room-dialog-body").evaluate(
            "node => node.scrollWidth > node.clientWidth || node.scrollHeight > node.clientHeight"))
        self.assertFalse(self.page.evaluate("() => document.documentElement.scrollWidth > window.innerWidth"))
        self.page.keyboard.press("Escape")
        expect(dialog).to_have_count(0)
        expand = room.get_by_role("button", name="Expand the agents' room", exact=True)
        expect(expand).to_be_focused()
        # Escape closes it even when pressed at once, while focus is still on the Expand button.
        expand.click()
        expect(dialog).to_be_visible()
        expand.focus()
        self.page.keyboard.press("Escape")
        expect(dialog).to_have_count(0)
        # The close button works too.
        expand.click()
        dialog.get_by_role("button", name="Close the agents' room", exact=True).click()
        expect(dialog).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_the_expanded_room_is_drawn_in_3d_from_the_same_seats_and_keeps_its_desks(self):
        """2.5D isometric voxel room (owner decision, 17 November): three.js draws the expanded room."""
        room = self.open_ludus()
        room.get_by_role("button", name="Expand the agents' room", exact=True).click()
        dialog = self.page.get_by_role("dialog", name="Agents' room", exact=True)
        canvas = dialog.locator("canvas.room3d-canvas")
        expect(canvas).to_have_count(1)
        # The canvas names the room for screen readers; the desks stay as the accessible layer.
        expect(canvas).to_have_attribute("role", "img")
        expect(canvas).to_have_attribute("aria-label", "Agents' room: Janus (hub), walking about; "
                                                       "Networking specialist, asleep; Proxmox specialist, asleep")
        self.assertEqual(dialog.locator(".room-desk").evaluate_all("nodes => nodes.map(n => n.dataset.agent)"),
                         ["hub", "networking-specialist", "proxmox-specialist"])
        # The seats the 3D room draws are exactly the app's own: same agents, order and states.
        seats = self.page.evaluate("() => globalThis.__room3dSeats")
        self.assertEqual([(seat["agent"], seat["state"], seat["screen"]) for seat in seats],
                         [("hub", "walking", "on"), ("networking-specialist", "sleeping", "off"),
                          ("proxmox-specialist", "sleeping", "off")])
        # Something was really drawn: the canvas is not blank (WebGL renders in headless Chromium).
        painted = canvas.evaluate("""c => { const g = c.getContext('webgl2') || c.getContext('webgl');
            const px = new Uint8Array(4 * 64 * 64); g.readPixels((c.width >> 1) - 32, (c.height >> 1) - 32, 64, 64,
            g.RGBA, g.UNSIGNED_BYTE, px); let lit = 0; for (let i = 3; i < px.length; i += 4) if (px[i]) lit++;
            return lit; }""")
        self.assertGreater(painted, 200)
        # Closing the room removes the renderer; nothing keeps drawing in the background.
        self.page.keyboard.press("Escape")
        expect(dialog).to_have_count(0)
        expect(self.page.locator("canvas.room3d-canvas")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_without_webgl_the_expanded_room_stays_2d(self):
        self.page.add_init_script("""HTMLCanvasElement.prototype.getContext = function () { return null; };""")
        room = self.open_ludus()
        room.get_by_role("button", name="Expand the agents' room", exact=True).click()
        dialog = self.page.get_by_role("dialog", name="Agents' room", exact=True)
        expect(dialog.locator(".room-desk")).to_have_count(3)
        expect(dialog.locator("canvas.room3d-canvas")).to_have_count(0)
        expect(dialog.locator(".agents-room")).not_to_have_class(re.compile("room3d-active"))
        self.assertEqual(self.errors, [])

    def test_in_the_room_the_hub_walks_to_the_specialists_desk_and_the_bar_follows_the_job(self):
        self.job_status = "processing"
        self.serve_job_socket()
        room = self.open_ludus()
        self.page.locator("#messageInput").fill("Check node hummingbird")
        self.page.locator("#messageInput").press("Enter")
        deadline = 50
        while self.job_socket is None and deadline:
            self.page.wait_for_timeout(100)
            deadline -= 1
        self.assertIsNotNone(self.job_socket, "the job socket never joined")
        # Sending a request keeps the room open: the owner is watching it and it follows the job live.
        office = room.get_by_role("group", name="Agents' room", exact=True)
        expect(office).to_be_visible()
        hub = office.locator('.room-desk[data-agent="hub"]')
        specialist = office.locator('.room-desk[data-agent="proxmox-specialist"]')
        bar = room.locator(".room-topbar")
        self.push_progress("routing", "hub")
        expect(hub).to_have_attribute("data-pose", "pondering")
        expect(bar.locator(".room-step")).to_have_attribute("aria-valuenow", "1")
        self.push_progress("executing", "proxmox-specialist")
        # The hub's seat is empty and he stands at the proxmox specialist's desk, who types.
        expect(hub).to_have_attribute("data-pose", "away")
        expect(specialist).to_have_attribute("data-pose", "typing")
        expect(specialist).to_have_attribute("data-screen", "working")
        expect(specialist.locator('.room-visitor[data-agent="hub"]')).to_have_count(1)
        expect(bar.locator(".room-step")).to_have_attribute("aria-valuenow", "3")
        expect(bar.locator(".room-counter[data-counter=\"busy\"]")).to_contain_text("2")
        # The bar names the request by its chat.
        expect(bar.locator(".room-title")).to_have_text("First fixture chat")
        self.push_progress("synthesizing", "hub")
        expect(hub).to_have_attribute("data-pose", "typing")
        expect(specialist.locator(".room-visitor")).to_have_count(0)
        expect(bar.locator(".room-step")).to_have_attribute("aria-valuenow", "4")
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
