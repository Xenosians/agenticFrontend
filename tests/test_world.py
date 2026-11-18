"""The agents' world (owner decisions of 18 November): the agents in the chat list open a full page
world drawn with three.js voxels, the chat docked in a corner and a settings menu. The owner walks his
own gladiator (arrow keys / WASD or a click) and opens any agent's card by clicking him or walking up
to his desk. Display only: moving, cards and menus send nothing; the docked chat sends the same request
as the chat view. Isolated HTTP fixtures only.

Run after rebuilding: python tests/test_world.py
"""
import re
import unittest

from playwright.sync_api import expect

import test_gladiators as gladiators


class WorldTests(gladiators.GladiatorTests):
    def open_world(self, width=1440, height=900):
        self.page.set_viewport_size({"width": width, "height": height})
        self.open_first_chat()
        self.preview().click()
        world = self.page.get_by_role("dialog", name="Agents' world", exact=True)
        expect(world).to_be_visible()
        expect(world.locator(".world-loading")).to_have_count(0)
        return world

    def owner_tile(self, world):
        return world.locator(".world-owner").get_attribute("data-tile")

    def test_the_agents_open_the_world_after_a_loading_screen_and_escape_returns(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open_first_chat()
        expect(self.preview()).to_have_attribute("aria-label", "Open the agents' world")
        self.preview().click()
        world = self.page.get_by_role("dialog", name="Agents' world", exact=True)
        expect(world).to_be_visible()
        # The loading screen says what is happening, then gives way to the drawn world.
        expect(world.locator(".world-loading")).to_have_count(0)
        canvas = world.locator("canvas.room3d-canvas")
        expect(canvas).to_have_count(1)
        # The world fills the window, not a box in the middle of it.
        box = world.bounding_box()
        self.assertGreaterEqual(box["width"], 1440 - 2)
        self.assertGreaterEqual(box["height"], 900 - 40)
        # Every agent keeps an accessible desk, the hub's first.
        self.assertEqual(world.locator(".world-desk").evaluate_all("nodes => nodes.map(n => n.dataset.agent)"),
                         ["hub", "networking-specialist", "proxmox-specialist"])
        self.page.keyboard.press("Escape")
        expect(world).to_have_count(0)
        expect(self.page.locator("canvas.room3d-canvas")).to_have_count(0)
        expect(self.preview()).to_be_focused()
        self.assertEqual(self.errors, [])

    def test_the_owner_walks_with_the_keys_and_desks_block_him(self):
        world = self.open_world()
        floor = world.locator(".world-floor")
        floor.focus()
        # Three agents, three columns: the hub at 1,1, networking at 4,1, proxmox at 7,1; the owner
        # starts in the middle of the front aisle.
        self.assertEqual(self.owner_tile(world), "4,3")
        card = world.get_by_role("region", name="Networking specialist", exact=True)
        expect(card).to_have_count(0)
        # In front of the networking specialist's desk his card opens, and his desk is marked.
        self.page.keyboard.press("ArrowUp")
        expect(world.locator(".world-owner")).to_have_attribute("data-tile", "4,2")
        expect(card).to_be_visible()
        expect(card).to_contain_text("Networking specialist is asleep.")
        expect(world.locator('.world-desk[data-agent="networking-specialist"]')).to_have_attribute("data-open", "true")
        # His desk blocks the way: pressing into it leaves the owner where he is.
        self.page.keyboard.press("w")
        expect(world.locator(".world-owner")).to_have_attribute("data-tile", "4,2")
        # Walking away closes the card.
        self.page.keyboard.press("ArrowDown")
        expect(world.locator(".world-owner")).to_have_attribute("data-tile", "4,3")
        expect(card).to_have_count(0)
        expect(world.locator('.world-desk[data-open="true"]')).to_have_count(0)
        # The owner's position is said in words for screen readers.
        expect(world.locator(".world-owner")).to_have_attribute("aria-label", re.compile("You"))
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_clicking_an_agent_opens_his_card_and_ask_focuses_the_docked_chat(self):
        world = self.open_world()
        world.locator('.world-desk[data-agent="hub"]').click()
        card = world.get_by_role("region", name="Janus (hub)", exact=True)
        expect(card).to_be_visible()
        expect(card).to_contain_text("Janus (hub) is walking about.")
        expect(card).to_contain_text("Janus decides which agent handles each request.")
        card.get_by_role("button", name="Ask Janus", exact=True).click()
        expect(world.locator("#worldMessageInput")).to_be_focused()
        # Nothing was sent by opening a card or asking.
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_a_click_on_a_desk_walks_the_owner_there(self):
        world = self.open_world()
        world.locator('.world-desk[data-agent="networking-specialist"]').dblclick()
        card = world.get_by_role("region", name="Networking specialist", exact=True)
        expect(card).to_be_visible()
        # The owner walks, one tile per step, to a free tile beside the networking specialist's desk
        # (4,1) and stops there.
        owner = world.locator(".world-owner")
        expect(owner).to_have_attribute("data-tile", re.compile(r"^(3,1|5,1|4,0|4,2)$"))
        self.assertEqual(owner.get_attribute("data-walking"), "false")
        self.assertEqual(self.errors, [])

    def test_the_docked_chat_sends_the_same_request_as_the_chat_view(self):
        world = self.open_world()
        chat = world.get_by_role("complementary", name="Chat", exact=True)
        expect(chat).to_be_visible()
        expect(chat).to_contain_text("First chat history")
        chat.locator("#worldMessageInput").fill("Check node hummingbird")
        chat.locator("#worldMessageInput").press("Enter")
        self.page.wait_for_timeout(300)
        self.assertEqual([payload.get("message") for payload in self.submissions], ["Check node hummingbird"])
        # The chat can be hidden to see the whole world, and shown again.
        chat.get_by_role("button", name="Hide chat", exact=True).click()
        expect(world.locator("#worldMessageInput")).to_have_count(0)
        world.get_by_role("button", name="Show chat", exact=True).click()
        expect(world.locator("#worldMessageInput")).to_be_visible()
        self.assertEqual(self.errors, [])

    def test_the_settings_menu_goes_back_to_chat_and_stops_motion(self):
        world = self.open_world()
        world.get_by_role("button", name="World settings", exact=True).click()
        menu = world.get_by_role("menu", name="World settings", exact=True)
        expect(menu).to_be_visible()
        motion = menu.get_by_role("menuitemcheckbox", name="Motion", exact=True)
        expect(motion).to_have_attribute("aria-checked", "true")
        motion.click()
        expect(motion).to_have_attribute("aria-checked", "false")
        self.assertFalse(self.page.evaluate("() => document.querySelector('.world .room3d-host').__room3dRunning"))
        # Escape closes the menu first, then the world.
        self.page.keyboard.press("Escape")
        expect(menu).to_have_count(0)
        expect(world).to_be_visible()
        world.get_by_role("button", name="World settings", exact=True).click()
        menu.get_by_role("menuitem", name="Back to chat", exact=True).click()
        expect(world).to_have_count(0)
        expect(self.page.locator(".workspace-title h1")).to_have_text("Chat")
        self.assertEqual(self.errors, [])

    def test_without_webgl_the_world_is_the_2d_room_with_the_same_controls(self):
        self.page.add_init_script("HTMLCanvasElement.prototype.getContext = function () { return null; };")
        world = self.open_world()
        expect(world.locator("canvas.room3d-canvas")).to_have_count(0)
        expect(world.locator(".world-desk")).to_have_count(3)
        floor = world.locator(".world-floor")
        # The whole floor is drawn, every row and column (vision review: two rows were missing), with a
        # gap so neighbouring tiles never merge, and each desk shows its agent's state.
        self.assertEqual(floor.evaluate("n => getComputedStyle(n).gridTemplateRows.split(' ').length"), 4)
        self.assertEqual(floor.evaluate("n => getComputedStyle(n).gridTemplateColumns.split(' ').length"), 9)
        self.assertNotEqual(floor.evaluate("n => getComputedStyle(n).columnGap"), "0px")
        expect(world.locator('.world-desk[data-agent="proxmox-specialist"] .world-desk-state')).to_have_text("asleep")
        floor.focus()
        self.page.keyboard.press("ArrowUp")
        expect(world.locator(".world-owner")).to_have_attribute("data-tile", "4,2")
        self.assertEqual(self.errors, [])

    def test_the_drawing_starts_below_the_request_bar_and_an_empty_message_cannot_be_sent(self):
        world = self.open_world()
        bar = world.locator(".room-topbar").bounding_box()
        canvas = world.locator("canvas.room3d-canvas").bounding_box()
        self.assertGreaterEqual(canvas["y"], bar["y"] + bar["height"])
        send = world.get_by_role("button", name="Send message", exact=True)
        expect(send).to_be_disabled()
        expect(send).not_to_have_class(re.compile(r"\bactive\b"))
        world.locator("#worldMessageInput").fill("Check node hummingbird")
        expect(send).to_be_enabled()
        expect(send).to_have_class(re.compile(r"\bactive\b"))
        self.assertEqual(self.errors, [])

    def test_a_narrow_window_keeps_the_world_inside_it(self):
        # The agents sit in the chat list, which phones do not show; a window narrowed to phone width
        # with the world open must still fit, with the chat foldable and every control on screen.
        world = self.open_world()
        self.page.set_viewport_size({"width": 390, "height": 760})
        self.page.wait_for_timeout(300)
        self.assertFalse(self.page.evaluate("() => document.documentElement.scrollWidth > window.innerWidth"))
        chat = world.get_by_role("complementary", name="Chat", exact=True)
        chat.get_by_role("button", name="Hide chat", exact=True).click()
        expect(world.locator("#worldMessageInput")).to_have_count(0)
        world.get_by_role("button", name="Show chat", exact=True).click()
        expect(world.locator("#worldMessageInput")).to_be_visible()
        for selector in (".world-settings-button", ".world-chat", ".room-topbar"):
            box = world.locator(selector).first.bounding_box()
            self.assertGreaterEqual(box["x"], 0, selector)
            self.assertLessEqual(box["x"] + box["width"], 390, selector)
        # An open card and the chat never cover each other (vision review), and the card keeps the margins.
        world.locator('.world-desk[data-agent="hub"]').click()
        card = world.locator(".world-card").bounding_box()
        chat = world.locator(".world-chat").bounding_box()
        self.assertTrue(card["y"] + card["height"] <= chat["y"] or chat["y"] + chat["height"] <= card["y"],
                        (card, chat))
        self.assertGreaterEqual(card["x"], 12)
        self.assertLessEqual(card["x"] + card["width"], 390 - 12 + 1)
        self.assertEqual(self.errors, [])




    def test_an_agents_card_lists_what_he_did_for_the_current_request(self):
        """World decision 3 (18 November): a card shows the agent's activity and his recent steps."""
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
        self.preview().click()
        world = self.page.get_by_role("dialog", name="Agents' world", exact=True)
        expect(world).to_be_visible()
        self.push_progress("routing", "hub")
        expect(world.locator('.world-desk[data-agent="hub"]')).to_have_attribute("aria-label", "Janus (hub), thinking")
        self.push_progress("planning", "proxmox-specialist")
        self.push_progress("executing", "proxmox-specialist")
        world.locator('.world-desk[data-agent="proxmox-specialist"]').click()
        card = world.get_by_role("region", name="Proxmox specialist", exact=True)
        steps = card.get_by_role("list", name="Recent steps", exact=True)
        expect(steps.get_by_role("listitem")).to_have_text(["Planned the action", "Ran the tool"])
        # The hub's card lists his own step; an agent with none says so.
        world.locator('.world-desk[data-agent="hub"]').click()
        hub = world.get_by_role("region", name="Janus (hub)", exact=True)
        expect(hub.get_by_role("list", name="Recent steps", exact=True).get_by_role("listitem")).to_have_text(
            ["Chose who handles the request"])
        world.locator('.world-desk[data-agent="networking-specialist"]').click()
        quiet = world.get_by_role("region", name="Networking specialist", exact=True)
        expect(quiet.get_by_role("list")).to_have_count(0)
        expect(quiet).to_contain_text("No steps in this request yet.")
        self.assertEqual(self.errors, [])

    def test_redraws_never_open_new_webgl_contexts_or_lose_the_worlds_own(self):
        """Screenshot review (18 November): the world went white after many redraws. Each redraw probed
        WebGL support with a new context; past the browser's limit the oldest one, the world's, was lost."""
        self.page.add_init_script("""(() => {
          const original = HTMLCanvasElement.prototype.getContext;
          window.__webglContexts = 0;
          window.__webglLost = 0;
          HTMLCanvasElement.prototype.getContext = function (kind, ...rest) {
            const context = original.call(this, kind, ...rest);
            if (context && /webgl/.test(String(kind)) && !this.__counted) {
              this.__counted = true;
              window.__webglContexts++;
            }
            return context;
          };
          document.addEventListener("webglcontextlost", () => { window.__webglLost++; }, true);
        })();""")
        world = self.open_world()
        world.locator(".world-floor").focus()
        for key in ["ArrowLeft", "ArrowRight"] * 15:
            self.page.keyboard.press(key)
        self.page.wait_for_timeout(300)
        # One probe and the world's own renderer, however often the page redraws.
        self.assertLessEqual(self.page.evaluate("window.__webglContexts"), 2)
        self.assertEqual(self.page.evaluate("window.__webglLost"), 0)
        self.assertEqual(self.errors, [])

class WorldReviewTests(WorldTests):
    """Defects found by the screenshot review, kept as assertions."""

    def test_over_the_drawing_the_open_desk_is_marked_on_the_floor_not_boxed(self):
        world = self.open_world()
        hub = world.locator('.world-desk[data-agent="hub"]')
        hub.click()
        expect(hub).to_have_attribute("data-open", "true")
        # A flat box over an isometric desk covered the owner (review): the drawing marks the open desk
        # on its floor instead, and the button draws nothing once focus and the pointer have left it.
        world.locator(".world-floor").focus()
        self.page.mouse.move(2, 400)
        self.assertEqual(hub.evaluate("n => getComputedStyle(n).borderTopColor"), "rgba(0, 0, 0, 0)")
        expect(world.locator(".room3d-host")).to_have_attribute("data-open", "hub")
        self.assertEqual(self.errors, [])

    def test_a_focused_floor_shows_its_keys_instead_of_a_ring_around_the_world(self):
        world = self.open_world()
        floor = world.locator(".world-floor")
        floor.focus()
        self.page.keyboard.press("ArrowUp")
        # A ring around the whole stage read as a glitch (review); keyboard focus is shown by a hint.
        self.assertEqual(floor.evaluate("n => getComputedStyle(n).boxShadow"), "none")
        self.assertEqual(floor.evaluate("n => getComputedStyle(n).outlineStyle"), "none")
        self.assertIn("Arrow keys", floor.evaluate("n => getComputedStyle(n, '::after').content"))
        self.assertEqual(self.errors, [])

    def test_the_2d_floor_frame_is_quiet_and_shows_its_keys_when_focused(self):
        self.page.add_init_script("HTMLCanvasElement.prototype.getContext = function () { return null; };")
        world = self.open_world()
        floor = world.locator(".world-floor")
        self.assertEqual(floor.evaluate("n => getComputedStyle(n).borderTopWidth"), "1px")
        self.assertNotEqual(floor.evaluate("n => getComputedStyle(n).borderTopColor"),
                            floor.evaluate("n => getComputedStyle(n).color"))
        floor.focus()
        self.page.keyboard.press("ArrowUp")
        self.assertEqual(floor.evaluate("n => getComputedStyle(n).boxShadow"), "none")
        self.assertIn("Arrow keys", floor.evaluate("n => getComputedStyle(n, '::after').content"))
        self.assertEqual(self.errors, [])


def load_tests(loader, tests, pattern):
    # Only the world's own tests: the inherited gladiator and chat tests run in their own suites.
    suite = unittest.TestSuite()
    for case in (WorldTests, WorldReviewTests):
        for name in sorted(case.__dict__):
            if name.startswith("test_"):
                suite.addTest(case(name))
    return suite


if __name__ == "__main__":
    unittest.main(verbosity=2)
