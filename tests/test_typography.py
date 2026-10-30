"""Computed typography and reflow in built pages with isolated HTTP fixtures.

The zoom cases use Chromium's CSS layout zoom to exercise enlarged text and
controls at fixed desktop/phone viewports; no live account or provider is used.
"""
import unittest

from playwright.sync_api import expect

from test_capabilities_page import CapabilitiesPageTests
from test_statusbar import CONTRAST


class TypographyTests(CapabilitiesPageTests):
    def open_personal(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        self.page.locator(".plugin-tabs").get_by_role("button", name="Personal", exact=True).click()
        expect(self.page.locator(".plugin-role-section")).to_be_visible()

    def assert_type(self, selectors, minimum):
        observed = self.page.evaluate("""selectors => selectors.map(selector => {
            const node = document.querySelector(selector);
            if (!node) return {selector, missing: true};
            const style = getComputedStyle(node);
            return {selector, font: style.fontFamily, size: parseFloat(style.fontSize)};
        })""", selectors)
        family = self.page.locator("body").evaluate("node => getComputedStyle(node).fontFamily")
        for row in observed:
            self.assertFalse(row.get("missing"), row)
            self.assertEqual(row["font"], family, row)
            self.assertGreaterEqual(row["size"], minimum, row)

    def assert_no_content_overflow(self):
        overflow = self.page.evaluate("""() =>
            [...document.querySelectorAll('.conversation, .plugin-main, .capability-row')]
              .filter(node => node.scrollWidth > node.clientWidth + 1)
              .map(node => ({class: node.className, width: node.clientWidth, content: node.scrollWidth}))""")
        self.assertEqual(overflow, [], overflow)

    def test_connections_share_ui_face_and_readable_semantic_sizes(self):
        self.open_personal()
        self.assert_type([".plugin-select", ".plugin-select option", ".plugin-tab",
                          ".plugin-search input"], 13)
        self.assert_type([".plugin-role-copy strong", ".personal-resource-copy strong"], 13)
        self.assert_type([".plugin-role-copy span", ".personal-resource-copy span",
                          ".selection-heading span:not(.plugin-icon)"], 12)
        for selector in (".plugin-role-copy span", ".personal-resource-copy span",
                         ".plugin-section-heading p"):
            self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5, selector)
        self.page.locator(".plugin-add-button").click()
        expect(self.page.get_by_role("heading", name="Add model connection", exact=True)).to_be_visible()
        self.assert_type([".plugin-field input", ".plugin-field label", ".plugin-primary"], 12)
        self.assertEqual(self.errors, [])

    def test_capabilities_use_readable_body_and_caption_roles(self):
        self.open_capabilities()
        self.assert_type([".capability-search", ".capability-copy strong"], 13)
        self.assert_type([".capability-copy span", ".capability-tag", ".capability-group h3"], 12)
        self.assertGreaterEqual(self.page.evaluate(CONTRAST, ".capability-copy span"), 4.5)
        self.assertEqual(self.errors, [])

    def test_enlarged_connections_and_capabilities_reflow_and_keep_keyboard_focus(self):
        for width, height in ((1440, 1000), (390, 760)):
            for zoom in (1, 1.25, 1.5):
                with self.subTest(width=width, zoom=zoom):
                    self.page.set_viewport_size({"width": width, "height": height})
                    self.open_personal()
                    self.page.evaluate("zoom => document.documentElement.style.zoom = zoom", zoom)
                    self.assert_type([".plugin-select"], 13)
                    select = self.page.get_by_role("combobox", name="Active model", exact=True)
                    select.scroll_into_view_if_needed()
                    # Enter via the keyboard after a programmatic focus anchor,
                    # so :focus-visible is genuinely keyboard-triggered.
                    select.focus()
                    self.page.keyboard.press("Tab")
                    outline = self.page.evaluate("""() => {
                        const style = getComputedStyle(document.activeElement);
                        return {style: style.outlineStyle, width: parseFloat(style.outlineWidth)};
                    }""")
                    self.assertNotEqual(outline["style"], "none", outline)
                    # Chromium rounds outlines to device pixels before exposing
                    # CSS values (e.g. 1.6 CSS px at 125% paints a 2px ring).
                    self.assertGreaterEqual(outline["width"] * zoom, 1.99, outline)
                    self.assertFalse(self.page.evaluate("""() =>
                        document.documentElement.scrollWidth > window.innerWidth + 1"""))
                    self.assert_no_content_overflow()
                    self.open_capabilities()
                    # This navigation reloads the fixture page, so explicitly
                    # restore zoom before measuring the second real view.
                    self.page.evaluate("zoom => document.documentElement.style.zoom = zoom", zoom)
                    self.assert_type([".capability-search", ".capability-copy strong"], 13)
                    self.assertFalse(self.page.evaluate("""() =>
                        document.documentElement.scrollWidth > window.innerWidth + 1"""))
                    self.assert_no_content_overflow()
                    self.assertEqual(self.mutations, [])
                    self.assertEqual(self.submissions, [])
                    self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(TypographyTests(name) for name in loader.getTestCaseNames(TypographyTests)
                             if name in TypographyTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
