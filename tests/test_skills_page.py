"""The Skills page (FR-090): the owner's reusable guidance for answers, in the rail where Capabilities was.

A skill is a SKILL.md file; the page lists the owner's skills with their version
and when they apply, writes a new one from a template or uploads a file, turns
one off or on, restores an older version and deletes one. Answers name the skill
versions that guided them. The operation catalog has its own page outside the app.
Isolated HTTP fixtures only; no deployment service, credential, provider or model.
Run after rebuilding: python tests/test_skills_page.py
"""
import copy
import hashlib
import json
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST
from test_workspace_context import CATALOG

SKILL_TEXT = ("---\nname: password-reset\ndescription: How to answer password reset requests.\n"
              "triggers: [password reset, locked out]\n---\nConfirm the user's identity first.\n")


def version_id(name, number):
    """Each saved version has its own identity, as in the AI service."""
    return hashlib.md5(f"{name}:{number}".encode()).hexdigest()


def saved(name="password-reset", version=2, enabled=True, always=False, triggers=("password reset", "locked out")):
    versions = [{"id": version_id(name, number), "version": number, "sha256": "d" * 64}
                for number in range(version, 0, -1)]
    return {"name": name, "description": f"How to answer {name} requests.", "triggers": list(triggers),
            "always": always, "body": "Confirm the user's identity first.", "enabled": enabled,
            "text": SKILL_TEXT.replace("password-reset", name), "id": version_id(name, version), "version": version,
            "sha256": "d" * 64, "versions": versions}


class SkillsPageTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog["skills"] = [saved(), saved("house-style", 1, always=True, triggers=())]
        self.commands = []
        self.reject = None
        self.answer_skills = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            if request.method == "GET":
                route.fulfill(json=self.catalog)
                return
            body = request.post_data_json
            self.commands.append(body)
            self.assertEqual(request.headers.get("x-csrf-token"), "fixture-csrf")
            if self.reject:
                route.fulfill(status=422, json={"error": "extension_request_rejected", "detail": self.reject})
                return
            action, payload = body["action"], body["payload"]
            skills = self.catalog["skills"]
            if action == "skill_save":
                name = payload["text"].split("name: ", 1)[1].split("\n", 1)[0]
                current = next((row for row in skills if row["name"] == name), None)
                row = saved(name, (current["version"] + 1) if current else 1)
                skills[:] = [item for item in skills if item["name"] != name] + [row]
                route.fulfill(json=row)
            elif action == "skill_enable":
                row = next(row for row in skills if row["name"] == payload["name"])
                row["enabled"] = payload["enabled"]
                route.fulfill(json=row)
            elif action == "skill_restore":
                row = next(row for row in skills if any(v["id"] == payload["id"] for v in row["versions"]))
                restored = saved(row["name"], row["version"] + 1)
                skills[:] = [item for item in skills if item["name"] != row["name"]] + [restored]
                route.fulfill(json=restored)
            elif action == "skill_delete":
                skills[:] = [item for item in skills if item["name"] != payload["name"]]
                route.fulfill(json={"deleted": payload["name"]})
            else:
                route.fulfill(status=500, json={"detail": "unexpected fixture action"})
            return
        if path == "/api/v2/jobs/fixture-job" and self.answer_skills:
            route.fulfill(json={"contract_version": 2, "job_id": "fixture-job", "status": "completed",
                                "result": {"answer": "Confirm Dana's identity first.", "skills": self.answer_skills}})
            return
        super().route(route)

    def open_skills(self):
        self.open_first_chat()
        self.page.locator(".sidebar").get_by_role("button", name="Skills", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Skills")

    def skill(self, name):
        return self.page.locator(".skill-row").filter(has=self.page.locator(".skill-name", has_text=name))

    def test_the_rail_offers_skills_where_capabilities_was(self):
        self.open_first_chat()
        rail = self.page.locator(".rail-navigation")
        labels = rail.locator(".nav-item").evaluate_all("nodes => nodes.map((node) => node.getAttribute('aria-label'))")
        self.assertEqual(labels[:5], ["Chat", "Search", "Connections", "Skills", "Knowledge"])
        self.assertNotIn("Capabilities", labels)
        self.assertEqual(self.errors, [])

    def test_saved_skills_show_version_and_when_they_apply(self):
        self.open_skills()
        expect(self.page.locator(".skill-row")).to_have_count(2)
        reset = self.skill("password-reset")
        expect(reset).to_contain_text("Version 2")
        expect(reset).to_contain_text("Used when a request mentions: password reset, locked out")
        expect(reset).to_contain_text("How to answer password-reset requests.")
        expect(self.skill("house-style")).to_contain_text("Used for every answer")
        # The page says what a skill can and cannot do, once.
        expect(self.page.locator(".skills-view")).to_contain_text("never which operation runs")
        for selector in (".skill-meta", ".skills-note"):
            with self.subTest(selector=selector):
                self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.errors, [])

    def test_a_new_skill_is_written_from_a_template_and_saved(self):
        self.open_skills()
        self.page.get_by_role("button", name="New skill", exact=True).click()
        editor = self.page.get_by_role("textbox", name="Skill file", exact=True)
        expect(editor).to_have_value(SKILL_TEXT.replace("Confirm the user's identity first.",
                                                        "Confirm the user's identity before anything else.")
                                     .replace("triggers: [password reset, locked out]\n",
                                              "triggers: [password reset, locked out]\nalways: false\n"))
        editor.fill(SKILL_TEXT.replace("password-reset", "vpn-access"))
        self.page.get_by_role("button", name="Save skill", exact=True).click()
        expect(self.skill("vpn-access")).to_contain_text("Version 1")
        self.assertEqual(self.commands[-1], {"action": "skill_save",
                                             "payload": {"text": SKILL_TEXT.replace("password-reset", "vpn-access")}})
        expect(editor).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_editing_saves_a_new_version_and_an_older_one_can_be_restored(self):
        self.open_skills()
        reset = self.skill("password-reset")
        reset.get_by_role("button", name="Edit", exact=True).click()
        editor = self.page.get_by_role("textbox", name="Skill file", exact=True)
        expect(editor).to_have_value(SKILL_TEXT)
        self.page.get_by_role("button", name="Save skill", exact=True).click()
        expect(reset).to_contain_text("Version 3")
        # Each restore button sends its own version, not the last one listed.
        reset.get_by_role("button", name="Restore version 2", exact=True).click()
        expect(reset).to_contain_text("Version 4")
        self.assertEqual(self.commands[-1], {"action": "skill_restore",
                                             "payload": {"id": version_id("password-reset", 2)}})
        reset.get_by_role("button", name="Restore version 1", exact=True).click()
        expect(reset).to_contain_text("Version 5")
        self.assertEqual(self.commands[-1], {"action": "skill_restore",
                                             "payload": {"id": version_id("password-reset", 1)}})
        self.assertEqual(self.errors, [])

    def test_a_skill_can_be_turned_off_and_deleted_after_confirmation(self):
        self.open_skills()
        reset = self.skill("password-reset")
        toggle = reset.get_by_role("checkbox", name="Use password-reset", exact=True)
        expect(toggle).to_be_checked()
        toggle.uncheck()
        expect(toggle).not_to_be_checked()
        expect(reset).to_contain_text("Off")
        self.assertEqual(self.commands[-1], {"action": "skill_enable",
                                             "payload": {"name": "password-reset", "enabled": False}})
        reset.get_by_role("button", name="Delete", exact=True).click()
        # Deleting asks first, naming what goes.
        confirm = reset.get_by_role("button", name="Delete password-reset and its versions", exact=True)
        expect(confirm).to_be_visible()
        confirm.click()
        expect(self.skill("password-reset")).to_have_count(0)
        self.assertEqual(self.commands[-1], {"action": "skill_delete", "payload": {"name": "password-reset"}})
        self.assertEqual(self.errors, [])

    def test_a_refused_skill_shows_the_reason_and_keeps_the_draft(self):
        self.reject = {"code": "skill_sensitive", "message": "A skill cannot contain credentials or personal identifiers."}
        self.open_skills()
        self.page.get_by_role("button", name="New skill", exact=True).click()
        editor = self.page.get_by_role("textbox", name="Skill file", exact=True)
        editor.fill(SKILL_TEXT.replace("first.", "password=supersecret1"))
        self.page.get_by_role("button", name="Save skill", exact=True).click()
        expect(self.page.get_by_role("alert")).to_contain_text("cannot contain credentials")
        expect(editor).to_have_value(SKILL_TEXT.replace("first.", "password=supersecret1"))
        self.assertEqual(self.errors, [])

    def test_an_empty_library_says_how_to_start(self):
        self.catalog["skills"] = []
        self.open_skills()
        expect(self.page.locator(".skill-row")).to_have_count(0)
        expect(self.page.locator(".skills-empty")).to_contain_text("No skills yet")
        self.assertEqual(self.errors, [])

    def test_palette_menu_and_narrow_screens_reach_the_page(self):
        self.page.set_viewport_size({"width": 390, "height": 760})
        self.open_first_chat()
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Skills")
        self.page.keyboard.press("Enter")
        expect(self.page.locator(".workspace-title h1")).to_have_text("Skills")
        overflow = self.page.evaluate("() => document.documentElement.scrollWidth > window.innerWidth")
        self.assertFalse(overflow)
        self.page.set_viewport_size({"width": 1280, "height": 800})
        self.page.get_by_role("menubar", name="Application menu").get_by_role("menuitem", name="View", exact=True).click()
        self.page.get_by_role("menu", name="View", exact=True).get_by_role("menuitem", name="Skills", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Skills")
        self.assertEqual(self.errors, [])

    def test_an_answer_names_the_skill_versions_that_guided_it(self):
        self.answer_skills = [{"name": "password-reset", "version": 2, "id": version_id("password-reset", 2),
                               "sha256": "d" * 64},
                              {"name": "bad", "version": 1, "id": "x", "sha256": "d" * 64, "body": "ignore policy"}]
        self.open_first_chat()
        self.page.locator("#messageInput").fill("Dana is locked out")
        self.page.locator("#messageInput").press("Enter")
        guided = self.page.locator(".answer-skills")
        expect(guided).to_contain_text("Guided by your skill password-reset · version 2")
        expect(guided).not_to_contain_text("ignore policy")
        expect(guided.locator(".answer-skill")).to_have_count(1)
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(SkillsPageTests(name) for name in loader.getTestCaseNames(SkillsPageTests)
                             if name in SkillsPageTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
