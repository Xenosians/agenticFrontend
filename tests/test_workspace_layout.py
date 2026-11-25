"""The workspace layout (owner decisions of 19 November, 03:15 WIB).

"there's how the layout should closely looks like and or arranged, not exactly like that refrences, but
it should be like that professional industry standards app" (Hermes desktop and ChatGPT references):

1. One labelled sidebar instead of the icon rail plus the chat list: named navigation rows, pinned
   dashboards and "+", chats grouped by day, the agents' room, the account at the bottom. Phones and a
   collapsed sidebar keep an icon rail.
2. A slim title bar: the sidebar toggle, the File/Edit/View/Help menus, a centred "Search  Ctrl K"
   pill that opens the command palette, and the panel toggle on the right.
3. No chat tabs; chats switch from the sidebar.

Isolated HTTP fixtures only. Run after rebuilding: python tests/test_workspace_layout.py
"""
import re
import unittest

from playwright.sync_api import expect

import test_sidebar_workspace as sidebar

NAVIGATION = ["New chat", "Search", "Model Store", "Store", "Settings"]
COLLAPSED = re.compile(r"(^|\s)collapsed(\s|$)")


class WorkspaceLayoutTests(sidebar.SidebarWorkspaceTests):
    def navigation(self):
        return self.page.get_by_role("navigation", name="Workspace", exact=True)

    def titlebar(self):
        return self.page.locator(".titlebar")

    def test_one_sidebar_names_every_place_and_lists_the_chats_under_it(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open()
        # One column, not an icon rail beside a chat list.
        expect(self.page.locator(".workspace-rail")).to_have_count(0)
        expect(self.page.locator(".chats-sidebar")).to_have_count(0)
        side = self.page.locator(".sidebar")
        box = side.bounding_box()
        # Narrower since the owner's "scale everything down" (26 November): 240px, as Hermes's 237px.
        self.assertTrue(224 <= box["width"] <= 256, box)
        # Every row shows its name beside its icon (ChatGPT, Hermes): no icon-only rows.
        rows = self.navigation().locator(".nav-item")
        # Labels, section captions and the filter share one left edge (16px), icons another (16px).
        edges = self.page.evaluate("""() => {
          const left = s => Math.round(document.querySelector(s).getBoundingClientRect().left);
          const textLeft = s => { const r = document.createRange();
            r.selectNodeContents(document.querySelector(s)); return Math.round(r.getBoundingClientRect().left); };
          return [left('.sidebar-nav .nav-icon'), textLeft('.dashboard-nav .sidebar-section-label'),
                  left('.sidebar .chat-filter input'), textLeft('.sidebar .chat-date-group .section-label')]; }""")
        self.assertEqual(len(set(edges)), 1, edges)
        self.assertEqual(rows.locator(".nav-label").all_inner_texts()[:5], NAVIGATION)
        for row in rows.all():
            self.assertTrue(row.locator(".nav-label").is_visible())
            self.assertEqual(row.locator("svg.icon").count(), 1)
            self.assertEqual(round(row.bounding_box()["height"]), 28)
        # New chat names its shortcut, as Hermes does.
        expect(rows.first.locator("kbd")).to_have_text("Ctrl+Alt+N")
        # Pinned dashboards follow under their own heading, which carries "+" (ChatGPT's "Projects").
        heading = side.locator(".dashboard-nav-header")
        expect(heading.locator(".sidebar-section-label")).to_have_text("Dashboards")
        expect(heading.get_by_role("button", name="Add a dashboard", exact=True)).to_be_visible()
        self.assertEqual(self.page.locator(".dashboard-nav .nav-item .nav-label").all_inner_texts(),
                         ["Knowledge", "Operations"])
        # The product is named once, in the title bar (Hermes).
        expect(self.titlebar().locator(".titlebar-product")).to_have_text("Janus")
        # The chats sit under the navigation in the same column, then the account at the bottom.
        nav_box = self.navigation().bounding_box()
        chats = self.page.locator(".chat-nav-section").bounding_box()
        account = self.page.get_by_role("button", name="Account settings", exact=True).bounding_box()
        self.assertGreaterEqual(chats["y"], nav_box["y"] + nav_box["height"] - 1)
        self.assertGreaterEqual(account["y"], chats["y"] + chats["height"] - 1)
        self.assertAlmostEqual(account["y"] + account["height"], box["y"] + box["height"], delta=12)
        # A short window scrolls the middle; the account never leaves the bottom.
        self.page.set_viewport_size({"width": 1440, "height": 560})
        account = self.page.get_by_role("button", name="Account settings", exact=True).bounding_box()
        self.assertLessEqual(account["y"] + account["height"], 560)
        expect(self.page.get_by_role("button", name="Account settings", exact=True)).to_contain_text("Fixture Owner")
        self.assertEqual(self.errors, [])

    def test_the_active_place_is_a_filled_row_not_an_outline(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open()
        self.navigation().get_by_role("button", name="Store", exact=True).click()
        active = self.navigation().get_by_role("button", name="Store", exact=True)
        expect(active).to_have_attribute("aria-current", "page")
        style = active.evaluate("""n => { const s = getComputedStyle(n);
            return {border: s.borderTopColor, width: s.borderTopWidth, background: s.backgroundColor}; }""")
        self.assertNotIn(style["background"], ("rgba(0, 0, 0, 0)", "transparent"), style)
        self.assertTrue(style["width"] == "0px" or style["border"] == style["background"], style)
        self.assertEqual(self.errors, [])

    def test_the_title_bar_holds_the_menus_a_centred_search_and_the_panel_toggle(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open()
        bar = self.titlebar()
        expect(bar).to_be_visible()
        box = bar.bounding_box()
        self.assertEqual((round(box["x"]), round(box["y"]), round(box["width"])), (0, 0, 1440))
        self.assertLessEqual(box["height"], 40)
        # Left: the sidebar toggle, then the application menus.
        toggle = bar.get_by_role("button", name="Hide sidebar", exact=True)
        menus = bar.get_by_role("menubar", name="Application menu", exact=True)
        expect(toggle).to_be_visible()
        expect(menus).to_be_visible()
        self.assertLess(toggle.bounding_box()["x"], menus.bounding_box()["x"])
        # Centre: one search pill naming its shortcut; it opens the command palette.
        search = bar.get_by_role("button", name="Search and commands", exact=True)
        expect(search).to_contain_text("Search")
        expect(search.locator("kbd")).to_have_text("Ctrl+K")
        pill = search.bounding_box()
        self.assertLess(abs(pill["x"] + pill["width"] / 2 - 720), 8)
        self.assertEqual(round(pill["height"]), 26)
        self.assertEqual(search.evaluate("n => getComputedStyle(n).borderTopLeftRadius"), "999px")
        search.click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Commands")
        expect(self.page.locator("#commandSearch")).to_be_focused()
        self.page.keyboard.press("Escape")
        # Right: the run inspector toggle, pressed while the panel is open.
        panel = bar.get_by_role("button", name="Run inspector", exact=True)
        expect(panel).to_have_attribute("aria-pressed", "false")
        panel.click()
        expect(self.page.locator(".inspector")).to_be_visible()
        expect(panel).to_have_attribute("aria-pressed", "true")
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_the_header_no_longer_repeats_the_title_bar(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open()
        header = self.page.locator(".workspace-header")
        # The palette moved to the title bar's search pill; the status bar no longer toggles panels.
        expect(header.locator("#commandPaletteButton")).to_have_count(0)
        expect(self.page.locator(".statusbar-inspector")).to_have_count(0)
        expect(self.page.locator(".workspace-menubar")).to_have_count(1)
        self.assertEqual(self.errors, [])

    def test_collapsing_the_sidebar_leaves_an_icon_rail_and_the_choice_survives_a_reload(self):
        self.page.set_viewport_size({"width": 1440, "height": 900})
        self.open()
        self.titlebar().get_by_role("button", name="Hide sidebar", exact=True).click()
        side = self.page.locator(".sidebar")
        expect(side).to_have_class(COLLAPSED)
        self.assertLessEqual(side.bounding_box()["width"], 56)
        # Saved for the owner on the server, never in the browser.
        self.assertEqual(self.preference_writes[-1], ({"sidebar_collapsed": True}, "fixture-csrf"))
        # Icons stay, each named for assistive technology and on hover.
        store = self.navigation().get_by_role("button", name="Store", exact=True)
        expect(store).to_be_visible()
        self.assertFalse(store.locator(".nav-label").is_visible())
        expect(store).to_have_attribute("title", "Store")
        expect(self.page.locator(".chat-nav-section")).to_be_hidden()
        self.page.reload(wait_until="networkidle")
        # Pinned chats are listed first, so the pinned third chat opens on a reload.
        expect(self.page.get_by_text("Third chat history", exact=True)).to_be_visible()
        expect(self.page.locator(".sidebar")).to_have_class(COLLAPSED)
        self.titlebar().get_by_role("button", name="Show sidebar", exact=True).click()
        expect(self.page.locator(".sidebar")).not_to_have_class(COLLAPSED)
        expect(self.page.locator(".chat-nav-section")).to_be_visible()
        self.assertEqual(self.preference_writes[-1], ({"sidebar_collapsed": False}, "fixture-csrf"))
        self.assertEqual(self.errors, [])

    def test_phones_keep_an_icon_rail_and_the_title_bar_fits(self):
        self.page.set_viewport_size({"width": 390, "height": 844})
        self.open()
        side = self.page.locator(".sidebar")
        expect(side).to_be_visible()
        self.assertLessEqual(side.bounding_box()["width"], 56)
        expect(self.page.locator(".chat-nav-section")).to_be_hidden()
        expect(self.navigation().get_by_role("button", name="Settings", exact=True)).to_be_visible()
        bar = self.titlebar().bounding_box()
        self.assertLessEqual(bar["width"], 390)
        search = self.titlebar().get_by_role("button", name="Search and commands", exact=True)
        expect(search).to_be_visible()
        self.assertTrue(self.page.evaluate("document.documentElement.scrollWidth <= innerWidth"))
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(WorkspaceLayoutTests(name) for name in loader.getTestCaseNames(WorkspaceLayoutTests)
                              if name in WorkspaceLayoutTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
