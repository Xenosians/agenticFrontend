"""The gladiators (F1): every Janus agent is a pixel gladiator acting out what it is really doing.

The agents sit at the bottom of the chat list (owner decision, 18 November; the strip above the message
box is gone) and open the agents' room large. The Run Inspector's Ludus tab
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

    def test_the_message_box_has_no_gladiator_strip_above_it(self):
        """Owner decision, 18 November: the strip is gone; the room in the chat list shows who works."""
        for viewport in ({"width": 1440, "height": 900}, {"width": 390, "height": 760}):
            with self.subTest(viewport=viewport):
                self.page.set_viewport_size(viewport)
                self.open_first_chat()
                expect(self.page.locator(".composer-container")).to_be_visible()
                expect(self.page.locator(".gladiator-strip")).to_have_count(0)
                self.assertFalse(self.page.evaluate(
                    "() => document.documentElement.scrollWidth > window.innerWidth"))
                self.assertEqual(self.errors, [])

    def preview(self):
        return self.page.get_by_role("button", name="Open the agents' world", exact=True)

    def test_an_agent_without_his_own_sheet_is_still_a_gladiator_not_a_block(self):
        # A new or third-party specialist has no drawn sheet yet; he borrows the common one instead of
        # painting a solid block of text colour (seen in the layout review of 19 November).
        catalog = {**CATALOG, "capabilities": CATALOG["capabilities"] + [
            {"id": "fixture_new_tool", "agent_names": ["fixture-new-specialist"], "grounded_arguments": []}]}
        self.page.route("**/api/v1/extensions", lambda route: route.fulfill(json=catalog))
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        newcomer = self.preview().locator('.gladiator[data-agent="fixture-new-specialist"]')
        expect(newcomer).to_have_count(1)
        masks = newcomer.evaluate("n => [getComputedStyle(n).webkitMaskImage, getComputedStyle(n).maskImage]")
        self.assertTrue(any("assets/gladiators/" in mask for mask in masks), masks)
        own = self.preview().locator('.gladiator[data-agent="proxmox-specialist"]').evaluate(
            "n => getComputedStyle(n).webkitMaskImage")
        self.assertIn("proxmox-specialist.png", own)
        self.assertEqual(self.errors, [])

    def test_the_agents_room_sits_at_the_bottom_of_the_chat_list(self):
        """Owner decision, 18 November: the room moves to the empty bottom of the chat list."""
        for width in (1440, 1100):
            with self.subTest(width=width):
                self.page.set_viewport_size({"width": width, "height": 900})
                self.open_first_chat()
                preview = self.preview()
                expect(preview).to_be_visible()
                # Inside the chat list column, below the chats, never over one.
                chats = self.page.locator(".sidebar-chats").bounding_box()
                box = preview.bounding_box()
                listed = self.page.locator(".chat-nav-section").bounding_box()
                self.assertGreaterEqual(box["x"], chats["x"] - 1)
                self.assertLessEqual(box["x"] + box["width"], chats["x"] + chats["width"] + 1)
                self.assertGreaterEqual(box["y"], listed["y"] + listed["height"] - 1)
                self.assertLessEqual(box["y"] + box["height"], chats["y"] + chats["height"] + 1)
                # Every agent the catalog names is in it, in roster order, acting out his state: who is
                # awake large (2x, legible), the sleepers small below.
                awake = preview.locator(".ludus-preview-awake .gladiator")
                asleep = preview.locator(".ludus-preview-asleep .gladiator")
                self.assertEqual(awake.evaluate_all("nodes => nodes.map(n => n.dataset.agent + ':' + n.dataset.state)"),
                                 ["hub:walking"])
                self.assertEqual(asleep.evaluate_all("nodes => nodes.map(n => n.dataset.agent)"),
                                 ["networking-specialist", "proxmox-specialist"])
                hub = awake.first.bounding_box()
                self.assertEqual((round(hub["width"]), round(hub["height"])), (64, 80))
                sleeper = asleep.first.bounding_box()
                self.assertEqual((round(sleeper["width"]), round(sleeper["height"])), (32, 40))
                # Centred in the box, not bunched at its left edge.
                middle = hub["x"] + hub["width"] / 2
                self.assertLess(abs(middle - (box["x"] + box["width"] / 2)), 4)
                expect(preview.locator(".ludus-preview-caption")).to_have_text(
                    "Janus (hub) is walking about; the other 2 are asleep.")
                # One control: the agents inside are pictures, not separate tab stops.
                self.assertEqual(preview.locator("button, a, input, [tabindex]").count(), 0)
                # Nothing in the list scrolls sideways because of it.
                self.assertFalse(self.page.locator(".sidebar").evaluate(
                    "node => node.scrollWidth > node.clientWidth + 1"))
                self.assertEqual(self.errors, [])

    def test_many_chats_scroll_above_the_room_and_never_run_under_it(self):
        many = [{"chat_id": "fixture-first", "title": "First fixture chat"}] + [
            {"chat_id": f"fixture-many-{index}", "title": f"Fixture chat {index}"} for index in range(40)]
        self.page.route("**/api/v1/chats", lambda route: route.fulfill(json={"chats": many}))
        self.page.set_viewport_size({"width": 1440, "height": 800})
        self.open_first_chat()
        listed = self.page.locator(".chat-nav-section")
        expect(self.page.get_by_text("Fixture chat 0", exact=True)).to_be_visible()
        preview = self.preview()
        expect(preview).to_be_visible()
        # The list scrolls in its own space; the room keeps its place below it, wholly visible.
        self.assertTrue(listed.evaluate("node => node.scrollHeight > node.clientHeight"))
        list_box = listed.bounding_box()
        box = preview.bounding_box()
        self.assertGreaterEqual(box["y"], list_box["y"] + list_box["height"] - 1)
        self.assertLessEqual(box["y"] + box["height"], 800)
        self.assertGreaterEqual(list_box["height"], 96)
        self.assertEqual(self.errors, [])

    def test_the_room_in_the_chat_list_opens_the_room_and_escape_brings_focus_back(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        preview = self.preview()
        preview.click()
        dialog = self.page.get_by_role("dialog", name="Agents' world", exact=True)
        expect(dialog).to_be_visible()
        self.assertEqual(dialog.locator(".world-desk").evaluate_all("nodes => nodes.map(n => n.dataset.agent)"),
                         ["hub", "networking-specialist", "proxmox-specialist"])
        self.page.keyboard.press("Escape")
        expect(dialog).to_have_count(0)
        expect(preview).to_be_focused()
        self.assertEqual(self.errors, [])

    def test_the_room_follows_the_job_live_in_the_chat_list(self):
        self.job_status = "processing"
        self.serve_job_socket()
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        self.page.locator("#messageInput").fill("Check node hummingbird")
        self.page.locator("#messageInput").press("Enter")
        deadline = 50
        while self.job_socket is None and deadline:
            self.page.wait_for_timeout(100)
            deadline -= 1
        self.assertIsNotNone(self.job_socket, "the job socket never joined")
        self.push_progress("executing", "proxmox-specialist")
        preview = self.preview()
        specialist = preview.locator('.gladiator[data-agent="proxmox-specialist"]')
        expect(specialist).to_have_attribute("data-state", "working")
        expect(specialist).to_have_count(1)
        self.assertEqual(preview.locator(".ludus-preview-awake .gladiator").evaluate_all(
            "nodes => nodes.map(n => n.dataset.agent)"), ["hub", "proxmox-specialist"])
        expect(preview.locator(".ludus-preview-caption")).to_have_text(
            "Proxmox specialist is working; Janus (hub) is thinking; the other one is asleep.")
        self.assertEqual(self.errors, [])

    def test_the_hub_acts_out_the_job_and_names_what_he_is_doing(self):
        self.job_status = "processing"
        self.open_first_chat()
        hub = self.page.locator('.ludus-preview .gladiator[data-agent="hub"]')
        expect(hub).to_have_attribute("data-state", "walking")
        self.page.locator("#messageInput").fill("Check node hummingbird")
        self.page.locator("#messageInput").press("Enter")
        expect(hub).to_have_attribute("data-state", "thinking")
        expect(hub).to_have_attribute("title", "Janus (hub): thinking")
        # Once the server names the specialist, he takes up the work.
        self.job_agent = "proxmox-specialist"
        self.job_status = "waiting_approval"
        specialist = self.page.locator('.ludus-preview .gladiator[data-agent="proxmox-specialist"]')
        expect(specialist).to_have_attribute("data-state", "waiting")
        expect(hub).to_have_attribute("data-talking-to", "proxmox-specialist")
        self.assertEqual(self.errors, [])

    def test_the_hub_hands_the_request_to_the_specialist_while_the_job_runs(self):
        # Live progress names the agent doing each step, so the hand-off shows before any approval.
        self.job_status = "processing"
        self.serve_job_socket()
        self.open_first_chat()
        hub = self.page.locator('.ludus-preview .gladiator[data-agent="hub"]')
        specialist = self.page.locator('.ludus-preview .gladiator[data-agent="proxmox-specialist"]')
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
        expect(specialist).to_have_attribute("data-state", "sleeping")
        self.push_progress("planning", "proxmox-specialist")
        expect(specialist).to_have_attribute("data-state", "thinking")
        expect(hub).to_have_attribute("data-talking-to", "proxmox-specialist")
        self.push_progress("executing", "proxmox-specialist")
        expect(specialist).to_have_attribute("data-state", "working")
        # The hub writes the answer alone; a name that is not a plain agent name is never shown.
        self.push_progress("synthesizing", "hub")
        expect(hub).to_have_attribute("data-state", "working")
        expect(hub).to_have_attribute("data-talking-to", "")
        expect(specialist).to_have_attribute("data-state", "sleeping")
        # A name that is not a plain agent name is never shown: still only the catalog's agents.
        self.push_progress("planning", "<img src=x>")
        expect(self.page.locator('.ludus-preview .gladiator')).to_have_count(3)
        self.assertEqual(self.errors, [])

    def test_the_inspector_shows_the_run_and_the_room_lives_in_the_chat_list(self):
        """Owner decision, 18 November: the Ludus tab left the Run Inspector."""
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        self.page.locator(".titlebar").get_by_role("button", name="Run inspector", exact=True).click()
        expect(self.page.locator(".inspector-tabs button")).to_have_text(["Run", "Events", "Raw"])
        # The three tabs share the bar's whole width: no empty slot where a tab used to be.
        bar = self.page.locator(".inspector-tabs").bounding_box()
        last = self.page.locator(".inspector-tabs button").last.bounding_box()
        self.assertLess(bar["x"] + bar["width"] - (last["x"] + last["width"]), 16)
        expect(self.page.get_by_role("region", name="Ludus", exact=True)).to_have_count(0)
        # No room is drawn anywhere (not even hidden) until the owner opens it from the chat list.
        expect(self.page.locator(".agents-room")).to_have_count(0)
        expect(self.preview()).to_be_visible()
        self.assertEqual(self.errors, [])

    def open_room(self):
        """The agents open their world large from the bottom of the chat list (owner decision, 18 November)."""
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        self.preview().click()
        dialog = self.page.get_by_role("dialog", name="Agents' world", exact=True)
        expect(dialog).to_be_visible()
        return dialog

    def test_the_agents_room_seats_every_agent_at_his_own_desk(self):
        dialog = self.open_room()
        desks = dialog.locator(".world-desk")
        # One desk per agent the catalog names, the hub's first; nothing is invented.
        self.assertEqual(desks.evaluate_all("nodes => nodes.map(n => n.dataset.agent)"),
                         ["hub", "networking-specialist", "proxmox-specialist"])
        specialist = dialog.locator('.world-desk[data-agent="proxmox-specialist"]')
        # Each desk says whose it is and what he is doing, for people who cannot see the art.
        expect(specialist).to_have_attribute("aria-label", "Proxmox specialist, asleep")
        # The top bar: no request yet, nothing counted but those asleep.
        bar = dialog.locator(".room-topbar")
        expect(bar.locator(".room-step")).to_have_attribute("aria-valuenow", "0")
        expect(bar.locator('.room-counter[data-counter="busy"]')).to_contain_text("0")
        # The world fills the window without scrolling the page.
        self.assertFalse(self.page.evaluate("() => document.documentElement.scrollWidth > window.innerWidth"))
        # Choosing a desk says who works there and what he is doing.
        specialist.click()
        expect(dialog.get_by_role("region", name="Proxmox specialist", exact=True)).to_contain_text(
            "Proxmox specialist is asleep.")
        # Escape closes the world and focus returns to the agents in the chat list.
        self.page.keyboard.press("Escape")
        expect(dialog).to_have_count(0)
        expect(self.preview()).to_be_focused()
        # Escape works at once, while focus is still on the opener; the menu's Back to chat works too.
        self.preview().click()
        expect(dialog).to_be_visible()
        self.preview().focus()
        self.page.keyboard.press("Escape")
        expect(dialog).to_have_count(0)
        self.preview().click()
        dialog.get_by_role("button", name="World settings", exact=True).click()
        dialog.get_by_role("menuitem", name="Back to chat", exact=True).click()
        expect(dialog).to_have_count(0)
        expect(self.preview()).to_be_focused()
        self.assertEqual(self.errors, [])

    def test_the_expanded_room_is_drawn_in_3d_from_the_same_seats_and_keeps_its_desks(self):
        """2.5D isometric voxel room (owner decision, 17 November): three.js draws the expanded room."""
        dialog = self.open_room()
        canvas = dialog.locator("canvas.room3d-canvas")
        expect(canvas).to_have_count(1)
        # The canvas names the room for screen readers; the desks stay as the accessible layer.
        expect(canvas).to_have_attribute("role", "img")
        expect(canvas).to_have_attribute("aria-label", "Agents' world: Janus (hub), walking about; "
                                                       "Networking specialist, asleep; Proxmox specialist, asleep; "
                                                       "you are on tile 4, 3")
        self.assertEqual(dialog.locator(".world-desk").evaluate_all("nodes => nodes.map(n => n.dataset.agent)"),
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
        dialog = self.open_room()
        expect(dialog.locator(".world-desk")).to_have_count(3)
        expect(dialog.locator("canvas.room3d-canvas")).to_have_count(0)
        expect(dialog.locator(".world-stage")).not_to_have_class(re.compile("room3d-on"))
        self.assertEqual(self.errors, [])

    def test_in_the_room_the_hub_walks_to_the_specialists_desk_and_the_bar_follows_the_job(self):
        self.job_status = "processing"
        self.serve_job_socket()
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        self.page.locator("#messageInput").fill("Check node hummingbird")
        self.page.locator("#messageInput").press("Enter")
        deadline = 50
        while self.job_socket is None and deadline:
            self.page.wait_for_timeout(100)
            deadline -= 1
        self.assertIsNotNone(self.job_socket, "the job socket never joined")
        # The owner opens the world while the request runs; it follows the job live.
        self.preview().click()
        dialog = self.page.get_by_role("dialog", name="Agents' world", exact=True)
        expect(dialog).to_be_visible()
        hub = dialog.locator('.world-desk[data-agent="hub"]')
        specialist = dialog.locator('.world-desk[data-agent="proxmox-specialist"]')
        bar = dialog.locator(".room-topbar")
        seats = "() => (globalThis.__room3dSeats || []).map(s => [s.agent, s.state, s.screen, s.visiting].join('|'))"
        self.push_progress("routing", "hub")
        expect(hub).to_have_attribute("aria-label", "Janus (hub), thinking")
        expect(bar.locator(".room-step")).to_have_attribute("aria-valuenow", "1")
        self.push_progress("executing", "proxmox-specialist")
        # The hub leaves his seat and stands at the proxmox specialist's desk, who types at a working screen.
        expect(hub).to_have_attribute("aria-label", "Janus (hub), at the proxmox specialist's desk")
        expect(specialist).to_have_attribute("aria-label", "Proxmox specialist, working")
        self.page.wait_for_function(seats + ".includes('proxmox-specialist|working|working|')")
        # The hub, still thinking, stands at that desk (the 3D seats say whom he visits).
        self.assertIn("hub|thinking|on|proxmox-specialist", self.page.evaluate(seats))
        expect(bar.locator(".room-step")).to_have_attribute("aria-valuenow", "3")
        expect(bar.locator(".room-counter[data-counter=\"busy\"]")).to_contain_text("2")
        # The bar names the request by its chat.
        expect(bar.locator(".room-title")).to_have_text("First fixture chat")
        self.push_progress("synthesizing", "hub")
        expect(hub).to_have_attribute("aria-label", "Janus (hub), working")
        self.page.wait_for_function(seats + ".every(s => !s.endsWith('|proxmox-specialist'))")
        expect(bar.locator(".room-step")).to_have_attribute("aria-valuenow", "4")
        self.assertEqual(self.errors, [])

    def test_the_owner_can_hide_the_gladiators_and_the_choice_is_saved(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        expect(self.preview()).to_be_visible()
        self.page.locator(".sidebar-nav").get_by_role("button", name="Settings", exact=True).click()
        switch = self.page.get_by_role("switch", name="Show the agents' gladiators", exact=True)
        expect(switch).to_be_checked()
        switch.click()
        expect(switch).not_to_be_checked()
        self.assertEqual(self.preference_writes, [{"gladiators": False}])
        self.page.reload(wait_until="networkidle")
        self.page.locator(".chat-nav-main", has_text="First fixture chat").click()
        expect(self.page.get_by_text("First chat history", exact=True)).to_be_visible()
        expect(self.page.locator(".ludus-preview")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_reduced_motion_holds_a_still_pose(self):
        self.page.emulate_media(reduced_motion="reduce")
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        hub = self.page.locator('.ludus-preview .gladiator[data-agent="hub"]')
        expect(hub).to_be_visible()
        self.assertEqual(hub.evaluate("node => getComputedStyle(node).animationName"), "none")
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(GladiatorTests(name) for name in loader.getTestCaseNames(GladiatorTests)
                             if name in GladiatorTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
