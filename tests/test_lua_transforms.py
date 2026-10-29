"""Lua row transforms on the Data tab (SRS 1.9 FR-097, V19-11), with isolated HTTP fixtures.

The script reshapes the chosen file's JSON rows in the AI service's isolated
worker. A preview admits nothing; applying is offered only after a preview of
the same script and uploads through ordinary dataset admission.
Run after rebuilding: python tests/test_lua_transforms.py
"""
import copy
import json
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST
from test_workspace_context import CATALOG

ROWS = "\n".join(json.dumps({"question": f"Printer jam {index}", "answer": f"Open tray {index}"})
                 for index in range(12)).encode()
LAYERS = ["process", "no_new_privileges", "network_namespace", "landlock", "resource_limits", "no_new_descriptors"]
SCRIPT = 'return function(row) return {text = row.question} end'
STARTER = """-- Map each row to a new one; return nil to drop it.
return function(row)
  return {messages = {
    {role = "user", content = row.question},
    {role = "assistant", content = row.answer},
  }}
end
"""


def preview(kept=12):
    return {"schema": "lua-row-transform.v1", "input_rows": 12, "output_rows": kept, "elapsed_ms": 3,
            "isolation": LAYERS, "preview": [{"text": f"Printer jam {index}"} for index in range(min(kept, 5))]}


class LuaTransformTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog["transforms"] = [{"id": "lua-row-transform", "available": True}]
        self.mutations = []
        self.transform_reply = preview()
        self.hold = False
        self.pending = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def tearDown(self):
        for route in self.pending:
            route.abort()
        super().tearDown()

    def route(self, route):
        request = route.request
        if urlparse(request.url).path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            if request.method == "GET":
                route.fulfill(json=self.catalog)
                return
            body = request.post_data_json
            self.mutations.append(body)
            if body["action"] == "dataset_transform" and not body["payload"]["apply"]:
                if self.hold:
                    self.pending.append(route)
                elif isinstance(self.transform_reply, tuple):
                    route.fulfill(status=self.transform_reply[0], json=self.transform_reply[1])
                else:
                    route.fulfill(json=self.transform_reply)
                return
            route.fulfill(json={"id": "d" * 32, "kind": "dataset", "state": "ready", "version": 1})
            return
        super().route(route)

    def open_transform(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        self.page.locator(".plugin-tabs").get_by_role("button", name="Data & automation", exact=True).click()
        toggle = self.page.get_by_role("button", name="Transform rows with Lua", exact=True)
        expect(toggle).to_have_attribute("aria-expanded", "false")
        toggle.click()
        expect(toggle).to_have_attribute("aria-expanded", "true")
        self.page.locator("#datasetFile").set_input_files(
            files=[{"name": "tickets.jsonl", "mimeType": "application/x-ndjson", "buffer": ROWS}])

    def fill_dataset(self):
        self.page.get_by_role("combobox", name="Purpose", exact=True).select_option("training")
        self.page.get_by_placeholder("Dataset name", exact=True).fill("Printer fixes")
        self.page.get_by_placeholder("Owned documentation", exact=True).fill("Owned tickets")
        self.page.get_by_placeholder("Internal / owned", exact=True).fill("Internal")
        self.page.locator(".dataset-review input").check()

    def script(self):
        return self.page.get_by_role("textbox", name="Lua script", exact=True)

    def button(self, name):
        return self.page.locator(".dataset-transform").get_by_role("button", name=name, exact=True)

    def test_a_preview_shows_kept_rows_and_isolation_and_admits_nothing(self):
        self.open_transform()
        # The editor starts with a working example that maps question/answer rows to chat messages.
        expect(self.script()).to_have_value(STARTER)
        expect(self.button("Apply and upload")).to_be_disabled()
        self.script().fill(SCRIPT)
        self.button("Preview").click()
        result = self.page.get_by_role("region", name="Transform preview")
        expect(result.get_by_role("status")).to_have_text("12 of 12 rows kept · 3 ms")
        expect(result).to_contain_text("no network, no file access, no new files or processes")
        expect(result.locator("li")).to_have_count(5)
        expect(result.locator("li").first).to_have_text('{"text":"Printer jam 0"}')
        self.assertEqual([m["action"] for m in self.mutations], ["dataset_transform"])
        sent = self.mutations[0]["payload"]
        self.assertEqual((sent["script"], sent["text"], sent["apply"]), (SCRIPT, ROWS.decode(), False))
        expect(self.button("Apply and upload")).to_be_enabled()
        self.assertEqual(self.errors, [])

    def test_applying_uploads_the_previewed_script_through_admission(self):
        self.open_transform()
        self.fill_dataset()
        self.script().fill(SCRIPT)
        self.button("Preview").click()
        expect(self.button("Apply and upload")).to_be_enabled()
        with self.page.expect_response(lambda response: urlparse(response.url).path == "/api/v1/extensions"
                                       and response.request.method == "POST"
                                       and response.request.post_data_json["payload"].get("apply") is True):
            self.button("Apply and upload").click()
        applied = self.mutations[-1]["payload"]
        self.assertEqual(applied, {"script": SCRIPT, "text": ROWS.decode(), "apply": True, "name": "Printer fixes",
                                   "source": "Owned tickets", "license": "Internal", "purpose": "training",
                                   "reviewed": True})
        expect(self.page.locator(".plugin-notice")).to_contain_text("Saved.")
        # A spent preview needs a fresh one before the next upload.
        expect(self.button("Apply and upload")).to_be_disabled()

    def test_editing_the_script_withdraws_the_preview(self):
        self.open_transform()
        self.script().fill(SCRIPT)
        self.button("Preview").click()
        expect(self.button("Apply and upload")).to_be_enabled()
        self.script().fill(SCRIPT + "\n-- changed")
        expect(self.button("Apply and upload")).to_be_disabled()
        expect(self.page.get_by_role("region", name="Transform preview")).to_have_count(0)
        # Even a forced click uploads nothing without a preview of this script.
        self.button("Apply and upload").dispatch_event("click")
        self.page.wait_for_timeout(300)
        self.assertEqual([m["payload"]["apply"] for m in self.mutations], [False])

    def test_a_preview_answered_after_the_script_changed_is_dropped(self):
        self.open_transform()
        self.hold = True
        self.script().fill(SCRIPT)
        self.button("Preview").click()
        # Wait until the preview request is actually held by the fixture.
        for _ in range(100):
            if self.pending:
                break
            self.page.wait_for_timeout(20)
        self.assertEqual(len(self.pending), 1)
        held = self.pending.pop()
        self.hold = False
        self.script().fill("return function(row) return nil end")
        held.fulfill(json=preview())
        self.page.wait_for_timeout(300)
        expect(self.page.get_by_role("region", name="Transform preview")).to_have_count(0)
        expect(self.button("Apply and upload")).to_be_disabled()

    def test_a_refusal_shows_the_scripts_own_error_and_offers_no_upload(self):
        self.transform_reply = (422, {"error": "extension_request_rejected",
                                      "detail": {"code": "transform_failed", "message": "Row 3: bad row"}})
        self.open_transform()
        self.button("Preview").click()
        expect(self.page.locator(".plugin-notice.error")).to_contain_text("Row 3: bad row (transform_failed)")
        expect(self.button("Apply and upload")).to_be_disabled()
        self.assertEqual(len(self.mutations), 1)

    def test_a_preview_that_claims_admission_is_an_error_not_a_preview(self):
        self.transform_reply = {**preview(), "id": "d" * 32}
        self.open_transform()
        self.button("Preview").click()
        expect(self.page.locator(".plugin-notice.error")).to_be_visible()
        expect(self.page.get_by_role("region", name="Transform preview")).to_have_count(0)
        expect(self.button("Apply and upload")).to_be_disabled()

    def test_without_lua_on_the_host_no_transform_is_offered(self):
        self.catalog["transforms"] = [{"id": "lua-row-transform", "available": False}]
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        self.page.locator(".plugin-tabs").get_by_role("button", name="Data & automation", exact=True).click()
        expect(self.page.get_by_role("button", name="Upload dataset", exact=True)).to_be_visible()
        expect(self.page.get_by_role("button", name="Transform rows with Lua", exact=True)).to_have_count(0)

    def test_transform_text_meets_wcag_aa_contrast_without_overflow(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_transform()
            self.button("Preview").click()
            expect(self.page.get_by_role("region", name="Transform preview")).to_be_visible()
            for selector in (".dataset-transform-note", ".dataset-transform-rows code", ".dataset-script"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            overflow = self.page.evaluate(
                "document.documentElement.scrollWidth > document.documentElement.clientWidth")
            self.assertFalse(overflow, f"horizontal overflow at {width}px")


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(LuaTransformTests(name) for name in loader.getTestCaseNames(LuaTransformTests)
                             if name in LuaTransformTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
