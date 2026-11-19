"""The design system (owner decisions of 18 November): one industry-standard look on every page except
the agents' world. Modelled on shadcn/ui (the Linear/Vercel look): Inter bundled with the app, a
fixed type scale, three weights, 36px controls (32px small), 8px control corners, 12px cards, a
4px spacing grid, Lucide line icons instead of text glyphs, switches for on/off settings, one page
header per page, and WCAG 2.2 target sizes and focus rings. Every check measures what the page
renders, on every main view, at desktop and phone width, dark and light.

Isolated HTTP fixtures only. Run after rebuilding: python tests/test_design_system.py
"""
import unittest

from playwright.sync_api import expect

import test_plain_language as plain

VIEWS = ("Chat", "Search", "Model Store", "Store", "Knowledge", "Operations", "Settings")
TYPE_SCALE = {12, 14, 16, 18, 20, 24}
WEIGHTS = {"400", "500", "600"}
BUTTONS = (".primary-action, .secondary-action, .plugin-primary, .plugin-secondary, .plugin-action-button, "
           ".auth-primary, .approval-action-button, .rejection-action-button, .approval-recovery-button, "
           ".command-back-button, .plugin-add-button, .plugin-back-button, .proxmox-power, .proxmox-ask, "
           ".header-action, .chats-header-action, .workspace-context")
FIELDS = ("input:not([type=radio]):not([type=checkbox]):not([type=file]):not([type=hidden]):not(.visually-hidden)"
          ":not(.search-box input):not(.plugin-search input):not(.command-center-search input), "
          "select, .search-box, .plugin-search, .command-center-search")
GLYPHS = "⌕×✎◇↻↑⬡⚙❏✓↵←◌⌘⋯≡▶▸▾▼›⌄+·"

MEASURE = """([buttons, fields, glyphs]) => {
  const shown = n => { const b = n.getBoundingClientRect(); const s = getComputedStyle(n);
    return b.width > 1 && b.height > 1 && s.visibility !== 'hidden' && s.display !== 'none' &&
           b.bottom > 0 && b.top < innerHeight && b.right > 0 && b.left < innerWidth; };
  const outside = n => n.closest('.world, .ludus-preview, .room-overlay-closed, .composer, .world-chat');
  const name = n => `${n.tagName.toLowerCase()}.${String(n.className.baseVal ?? n.className).split(' ')[0]}`;
  const texts = [...document.querySelectorAll('body *')].filter(n => !outside(n) && shown(n) &&
    [...n.childNodes].some(c => c.nodeType === 3 && c.textContent.trim()));
  const sizes = {}, weights = {};
  for (const n of texts) {
    const s = getComputedStyle(n);
    (sizes[parseFloat(s.fontSize)] ||= []).push(name(n));
    (weights[s.fontWeight] ||= []).push(name(n));
  }
  const box = n => n.getBoundingClientRect();
  const controls = [...document.querySelectorAll(buttons)].filter(n => shown(n) && !outside(n))
    .map(n => ({name: name(n), h: Math.round(box(n).height), r: getComputedStyle(n).borderTopLeftRadius}));
  const inputs = [...document.querySelectorAll(fields)].filter(n => shown(n) && !outside(n))
    .map(n => ({name: name(n), h: Math.round(box(n).height), r: getComputedStyle(n).borderTopLeftRadius}));
  const targets = [...document.querySelectorAll('button, a[href], select, input, textarea, [role=tab], [role=switch], [role=menuitem]')]
    .filter(n => shown(n) && !outside(n) && !n.closest('p, li > span'))
    .map(n => { const own = (n.type === 'radio' || n.type === 'checkbox') && n.closest('label') ? n.closest('label') : n;
                const b = box(own); return {name: name(n), w: Math.round(b.width), h: Math.round(b.height)}; })
    .filter(t => t.w < 24 || t.h < 24);
  const glyphButtons = [...document.querySelectorAll('button, [role=button], .search-box > span, .command-center-search > span')]
    .filter(n => shown(n) && !outside(n)).map(n => ({name: name(n), text: n.innerText.trim()}))
    .filter(t => t.text.length === 1 && glyphs.includes(t.text));
  return {sizes, weights, controls, inputs, targets, glyphButtons,
          font: getComputedStyle(document.body).fontFamily,
          interLoaded: document.fonts.check('14px Inter')};
}"""


class DesignSystemTests(plain.PlainLanguageTests):
    def each_view(self, check):
        for theme in ("dark", "light"):
            for width, height in ((1440, 900), (390, 800)):
                self.page.set_viewport_size({"width": width, "height": height})
                self.open_first_chat()
                self.page.evaluate("t => document.documentElement.dataset.theme = t", theme)
                for name in VIEWS:
                    with self.subTest(view=name, theme=theme, width=width):
                        if width < 700 and name != "Chat":
                            menu = self.page.get_by_role("button", name="Open menu", exact=True)
                            if menu.count():
                                menu.first.click()
                        self.open_view(name)
                        self.page.wait_for_timeout(150)
                        check(name, self.page.evaluate(MEASURE, [BUTTONS, FIELDS, GLYPHS]))

    def test_inter_is_bundled_and_used_everywhere(self):
        fonts = []
        self.page.on("request", lambda request: fonts.append(request.url) if "/fonts/" in request.url else None)
        self.open_first_chat()
        self.page.evaluate("document.fonts.ready")
        self.page.wait_for_function("document.fonts.check('14px Inter')")
        family = self.page.evaluate("getComputedStyle(document.body).fontFamily")
        self.assertTrue(family.startswith("Inter"), family)
        # Served by the app itself (the policy allows fonts from 'self' only), never a font service.
        self.assertTrue(fonts and all(url.startswith(self.base + "/fonts/") for url in fonts), fonts)
        self.assertEqual(self.errors, [])

    def test_text_uses_the_type_scale_and_three_weights(self):
        def check(view, found):
            off_scale = {size: names[:4] for size, names in found["sizes"].items() if float(size) not in TYPE_SCALE}
            self.assertEqual(off_scale, {}, f"{view}: text off the type scale")
            off_weight = {weight: names[:4] for weight, names in found["weights"].items() if weight not in WEIGHTS}
            self.assertEqual(off_weight, {}, f"{view}: weights outside 400/500/600")
        self.each_view(check)
        self.assertEqual(self.errors, [])

    def test_buttons_and_fields_have_the_standard_heights_and_corners(self):
        def check(view, found):
            bad = [c for c in found["controls"] if c["h"] not in (32, 36) or c["r"] not in ("8px", "6px")]
            self.assertEqual(bad, [], f"{view}: buttons not 32/36px with 6-8px corners")
            bad = [c for c in found["inputs"] if c["h"] != 36 or c["r"] != "8px"]
            self.assertEqual(bad, [], f"{view}: fields not 36px with 8px corners")
        self.each_view(check)
        self.assertEqual(self.errors, [])

    def test_the_application_menu_bar_uses_compact_desktop_items(self):
        # A desktop menu bar (VS Code, Linear desktop): 28px items in body text, 6px corners, above 24px;
        # the title bar's icon buttons share the 28px height.
        self.open_first_chat()
        items = self.page.evaluate("""() => [...document.querySelectorAll('.workspace-menu-trigger, .titlebar-button')]
            .filter(n => n.getBoundingClientRect().width > 0).map(n => {
            const s = getComputedStyle(n); return [Math.round(n.getBoundingClientRect().height), s.borderTopLeftRadius]; })""")
        self.assertTrue(items)
        self.assertEqual({tuple(item) for item in items}, {(28, "6px")})
        sizes = self.page.evaluate("""() => [...document.querySelectorAll('.workspace-menu-trigger')]
            .map(n => getComputedStyle(n).fontSize)""")
        self.assertEqual(set(sizes), {"14px"})
        self.assertEqual(self.errors, [])

    def test_every_control_is_a_large_enough_target_and_uses_icons_not_glyphs(self):
        def check(view, found):
            # WCAG 2.2 SC 2.5.8: pointer targets at least 24 by 24 CSS pixels.
            self.assertEqual(found["targets"], [], f"{view}: targets under 24px")
            self.assertEqual(found["glyphButtons"], [], f"{view}: text glyphs used as icons")
        self.each_view(check)
        self.assertEqual(self.errors, [])

    def test_icons_are_lucide_line_icons_that_inherit_the_text_colour(self):
        self.open_first_chat()
        icons = self.page.locator("svg.icon")
        self.assertGreater(icons.count(), 5)
        first = icons.first
        self.assertEqual(first.get_attribute("aria-hidden"), "true")
        self.assertEqual(first.get_attribute("stroke"), "currentColor")
        self.assertEqual(first.get_attribute("fill"), "none")
        self.assertEqual(first.get_attribute("viewBox"), "0 0 24 24")
        self.assertEqual(self.errors, [])

    def test_keyboard_focus_shows_a_two_pixel_ring(self):
        self.open_first_chat()
        self.page.locator("#messageInput").focus()
        self.page.keyboard.press("Shift+Tab")
        ring = self.page.evaluate("""() => { const s = getComputedStyle(document.activeElement);
            return {style: s.outlineStyle, width: parseFloat(s.outlineWidth)}; }""")
        # WCAG 2.2 SC 2.4.13: at least as large as a 2px perimeter.
        self.assertEqual(ring["style"], "solid", ring)
        self.assertGreaterEqual(ring["width"], 2, ring)
        self.assertEqual(self.errors, [])

    def test_on_off_settings_are_switches_with_the_control_on_the_right(self):
        self.open_first_chat()
        self.open_view("Settings")
        self.page.get_by_role("navigation", name="Settings sections", exact=True).get_by_role(
            "link", name="Notifications", exact=True).click()
        switch = self.page.get_by_role("switch", name="Task completion emails", exact=True)
        expect(switch).to_be_visible()
        expect(switch).to_be_checked()
        row = self.page.locator(".settings-toggle").filter(has=switch)
        label = row.locator("strong").bounding_box()
        control = switch.bounding_box()
        # Linear/Vercel: the label and its description on the left, the switch on the right.
        self.assertGreater(control["x"], label["x"] + label["width"])
        self.assertEqual((round(control["width"]), round(control["height"])), (36, 20))
        expect(self.page.get_by_role("checkbox")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_each_page_has_one_header_with_one_title_and_one_description(self):
        self.open_first_chat()
        for name in VIEWS[1:]:
            with self.subTest(view=name):
                self.open_view(name)
                header = self.page.locator(".workspace .page-header")
                expect(header).to_have_count(1)
                expect(header.locator(".page-title")).to_have_count(1)
                expect(header.locator(".page-description")).to_have_count(1)
                sizes = self.page.evaluate("""() => [document.querySelector('.workspace-title h1'),
                    document.querySelector('.page-header .page-title')].map(n => parseFloat(getComputedStyle(n).fontSize))""")
                # The top bar names the place (14px); the page title is the one heading that stands out (24px).
                self.assertEqual(sizes, [14, 24], name)
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(DesignSystemTests(name) for name in loader.getTestCaseNames(DesignSystemTests)
                              if name in DesignSystemTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
