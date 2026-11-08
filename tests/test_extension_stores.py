"""One Store page with three sections: Tools (MCP tools grouped into packages), the Skill
Library and the Plugin Store (Lua plugins). Read-only catalogs; a switch saves an owner's
choice and the page shows what the service saved. No tool is invoked.
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST


CATALOG = {
    "schema": "extension-catalog.v1",
    "capabilities_schema": "mcp-tool-catalog.v1",
    "capabilities": [
        {"id": "account_status", "description": "Read one account status.", "effect": "read",
         "risk": "read", "permission": "directory.read", "provider": "directory",
         "requires_approval": False, "agent_names": ["account-specialist"]},
        {"id": "account_unlock", "description": "Unlock one account.", "effect": "mutation",
         "risk": "medium", "permission": "directory.write", "provider": "directory",
         "requires_approval": True, "agent_names": ["account-specialist"]},
        {"id": "ticket_create", "description": "Create an issue in the selected Jira project.",
         "effect": "mutation", "risk": "high", "permission": "jira.write", "provider": "ticketing",
         "requires_approval": True, "agent_names": ["jira-specialist"]},
        {"id": "invalid_tool", "effect": "mutation", "requires_approval": "true"},
    ],
    "tool_packages": [
        {"id": "directory", "name": "Directory (LDAP)", "kind": "provider", "state": "configured"},
        {"id": "ticketing", "name": "Ticketing (Jira)", "kind": "provider", "state": "not_configured"},
        {"id": "proxmox", "name": "Proxmox VE", "kind": "provider", "state": "not_configured"},
    ],
    "plugin_catalog": {"schema": "lua-plugin-catalog.v1", "scope": "runtime", "plugins": [
        {"id": "tool.default", "protocol": "tool", "state": "resolved", "source": "packaged",
         "sha256": "a" * 64},
        {"id": "model.local", "protocol": "model", "state": "unavailable", "source": "unavailable",
         "reason_code": "lua_adapter_configuration_invalid"},
    ]},
    "resources": [], "skills": [], "selected": {"model_id": None, "dataset_id": None},
    "role_assignments": {}, "specialist_roles": [], "provider_presets": [], "connection_presets": [],
    "inference_option_support": [], "networking_inference_options": [], "local_profiles": [],
    "harnesses": [], "transforms": [], "crawl_sites": [], "connections": [],
}


class ExtensionStoreViewTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.methods = []
        self.commands = []
        self.reject = None
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        if urlparse(request.url).path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            self.methods.append(request.method)
            if request.method == "GET":
                route.fulfill(json=self.catalog)
                return
            body = request.post_data_json
            self.commands.append(body)
            if self.reject:
                route.fulfill(status=422, json={"error": "extension_request_rejected", "detail": self.reject})
            elif body["action"] == "tool_enable":
                row = next(row for row in self.catalog["capabilities"] if row.get("id") == body["payload"]["id"])
                row["enabled"] = body["payload"]["enabled"]
                route.fulfill(json={"id": row["id"], "enabled": row["enabled"]})
            elif body["action"] == "tool_package_enable":
                package = body["payload"]["package"]
                tools = [row for row in self.catalog["capabilities"] if row.get("provider") == package]
                for row in tools:
                    row["enabled"] = body["payload"]["enabled"]
                route.fulfill(json={"package": package, "enabled": body["payload"]["enabled"],
                                    "tools": sorted(row["id"] for row in tools)})
            else:
                route.fulfill(status=405, json={"error": "read_only_catalog"})
            return
        super().route(route)

    def open_store(self, section="Tools"):
        self.open_first_chat()
        self.page.locator(".rail-navigation").get_by_role("button", name="Store", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Store")
        self.page.get_by_role("tablist", name="Store sections").get_by_role("tab", name=section, exact=True).click()
        expect(self.page.get_by_role("tab", name=section, exact=True)).to_have_attribute("aria-selected", "true")

    def package(self, name):
        return self.page.locator(".tool-package").filter(
            has=self.page.get_by_role("heading", name=name, exact=True))

    def open_package(self, name):
        package = self.package(name)
        package.locator(".tool-package-toggle").click()
        return package

    def test_one_store_page_holds_tools_skills_and_plugins_as_sections(self):
        self.open_first_chat()
        rail = self.page.locator(".rail-navigation")
        for old in ("MCP Tool Store", "Lua Plugin Store", "Skill Store"):
            expect(rail.get_by_role("button", name=old, exact=True)).to_have_count(0)
        rail.get_by_role("button", name="Store", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Store")
        tabs = self.page.get_by_role("tablist", name="Store sections").get_by_role("tab")
        expect(tabs).to_have_text(["Tools", "Skill Library", "Plugin Store"])
        expect(tabs.first).to_have_attribute("aria-selected", "true")
        expect(self.page.get_by_role("tabpanel", name="Tools")).to_be_visible()
        tabs.nth(1).click()
        expect(self.page.get_by_role("tabpanel", name="Skill Library")).to_be_visible()
        tabs.nth(2).click()
        expect(self.page.get_by_role("tabpanel", name="Plugin Store")).to_be_visible()
        # Arrow keys move between the sections, as in any tab list.
        tabs.nth(2).focus()
        self.page.keyboard.press("ArrowRight")
        expect(tabs.first).to_be_focused()
        expect(tabs.first).to_have_attribute("aria-selected", "true")
        self.page.keyboard.press("ArrowLeft")
        expect(tabs.nth(2)).to_be_focused()
        expect(tabs.nth(2)).to_have_attribute("aria-selected", "true")
        self.assertEqual(set(self.methods), {"GET"})
        self.assertEqual(self.errors, [])

    def test_tools_are_grouped_into_one_package_per_service(self):
        self.open_store("Tools")
        packages = self.page.locator(".tool-package")
        # Only packages with registered tools are listed; the malformed row is skipped.
        expect(packages).to_have_count(2)
        expect(packages.locator("h3")).to_have_text(["Directory (LDAP)", "Ticketing (Jira)"])
        directory = self.package("Directory (LDAP)")
        expect(directory.locator(".tool-package-counts")).to_have_text("2 tools · 1 can change data")
        expect(directory.locator(".tool-package-setup")).to_have_text("Configured")
        expect(self.package("Ticketing (Jira)").locator(".tool-package-setup")).to_have_text("Needs setup")
        # The tools stay inside their package until it is opened.
        toggle = directory.locator(".tool-package-toggle")
        expect(toggle).to_have_attribute("aria-expanded", "false")
        expect(directory.locator(".tool-store-card")).to_have_count(0)
        toggle.click()
        expect(toggle).to_have_attribute("aria-expanded", "true")
        cards = directory.locator(".tool-store-card")
        expect(cards).to_have_count(2)
        account = cards.filter(has=self.page.get_by_role("heading", name="account_status", exact=True))
        expect(account.locator(".store-badge")).to_have_text(["Read only", "Approval not required"])
        unlock = cards.filter(has=self.page.get_by_role("heading", name="account_unlock", exact=True))
        expect(unlock).to_contain_text("Changes data")
        expect(unlock).to_contain_text("Approval required")
        expect(unlock).to_contain_text("account-specialist")
        toggle.click()
        expect(directory.locator(".tool-store-card")).to_have_count(0)
        self.assertEqual(set(self.methods), {"GET"})
        self.assertEqual(self.errors, [])

    def test_searching_tools_shows_the_matching_tools_in_their_packages(self):
        self.open_store("Tools")
        search = self.page.get_by_role("searchbox", name="Search tools", exact=True)
        search.fill("unlock")
        expect(self.page.locator(".tool-package")).to_have_count(1)
        expect(self.package("Directory (LDAP)").locator(".tool-store-card h3")).to_have_text(["account_unlock"])
        # A package name matches too, and lists all of its tools.
        search.fill("jira")
        expect(self.page.locator(".tool-package")).to_have_count(1)
        expect(self.package("Ticketing (Jira)").locator(".tool-store-card h3")).to_have_text(["ticket_create"])
        search.fill("no such tool")
        expect(self.page.locator(".store-state")).to_have_text("No tools match this search.")
        search.fill("")
        expect(self.page.locator(".tool-package")).to_have_count(2)
        expect(self.page.locator(".tool-store-card")).to_have_count(0)
        self.assertEqual(set(self.methods), {"GET"})
        self.assertEqual(self.errors, [])

    def test_a_package_switch_turns_all_its_tools_off_and_the_page_shows_the_saved_state(self):
        self.open_store("Tools")
        directory = self.package("Directory (LDAP)")
        switch = directory.get_by_role("checkbox", name="Use all Directory (LDAP) tools", exact=True)
        expect(switch).to_be_checked()
        switch.click()
        expect(switch).not_to_be_checked()
        expect(directory.locator(".tool-package-heading .tool-switch span")).to_have_text("Off")
        expect(directory).to_have_class("tool-package is-off")
        self.assertEqual(self.commands, [{"action": "tool_package_enable",
                                          "payload": {"package": "directory", "enabled": False}}])
        # The page shows what the service saved: the catalog is read again after the change.
        self.assertIn("GET", self.methods[self.methods.index("POST") + 1:])
        self.open_package("Directory (LDAP)")
        expect(directory.locator(".tool-store-card.is-off")).to_have_count(2)
        # Dimmed, but every text on a turned-off package stays readable (WCAG AA).
        for selector in (".tool-package.is-off h3", ".tool-package.is-off .tool-package-counts",
                         ".tool-package.is-off .tool-switch span", ".tool-store-card.is-off .store-card-description"):
            with self.subTest(selector=selector):
                self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
        self.assertEqual(self.errors, [])

    def test_a_package_with_some_tools_off_says_so_and_turns_them_all_on(self):
        self.catalog["capabilities"][1]["enabled"] = False
        self.open_store("Tools")
        directory = self.package("Directory (LDAP)")
        expect(directory.locator(".tool-package-heading .tool-switch span")).to_have_text("1 of 2 on")
        expect(directory).to_have_class("tool-package")
        switch = directory.get_by_role("checkbox", name="Use all Directory (LDAP) tools", exact=True)
        # Partly on is the browser's mixed state, not "off".
        expect(switch).to_have_js_property("indeterminate", True)
        switch.click()
        expect(directory.locator(".tool-package-heading .tool-switch span")).to_have_text("On")
        expect(switch).to_be_checked()
        expect(switch).to_have_js_property("indeterminate", False)
        self.assertEqual(self.commands, [{"action": "tool_package_enable",
                                          "payload": {"package": "directory", "enabled": True}}])
        self.assertEqual(self.errors, [])

    def test_one_tool_inside_a_package_still_has_its_own_switch(self):
        self.open_store("Tools")
        directory = self.open_package("Directory (LDAP)")
        card = directory.locator(".tool-store-card").filter(
            has=self.page.get_by_role("heading", name="account_status", exact=True))
        switch = card.get_by_role("checkbox", name="Use account_status", exact=True)
        expect(switch).to_be_checked()
        switch.click()
        expect(card.locator(".tool-switch span")).to_have_text("Off")
        expect(switch).not_to_be_checked()
        expect(card).to_have_class("store-card tool-store-card is-off")
        # The package stays open after the catalog is read again, and counts the change.
        expect(directory.locator(".tool-store-card")).to_have_count(2)
        expect(directory.locator(".tool-package-heading .tool-switch span")).to_have_text("1 of 2 on")
        for selector in (".tool-store-card.is-off h3", ".tool-store-card.is-off .store-card-description",
                         ".tool-store-card.is-off .store-badge", ".tool-store-card.is-off .tool-switch span"):
            with self.subTest(selector=selector):
                self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
        self.assertEqual(self.commands, [{"action": "tool_enable",
                                          "payload": {"id": "account_status", "enabled": False}}])
        self.assertEqual(self.errors, [])

    def test_a_refused_switch_keeps_the_previous_state_and_says_why(self):
        self.reject = {"code": "tool_package_not_found", "message": "Tool package not found."}
        self.open_store("Tools")
        directory = self.package("Directory (LDAP)")
        directory.get_by_role("checkbox", name="Use all Directory (LDAP) tools", exact=True).click()
        expect(self.page.locator(".store-view .operation-error")).to_contain_text("Tool package not found.")
        expect(directory.get_by_role("checkbox", name="Use all Directory (LDAP) tools", exact=True)).to_be_checked()
        self.assertEqual(self.errors, [])

    def test_plugin_store_reports_resolution_and_does_not_offer_unreviewed_install(self):
        self.open_store("Plugin Store")
        cards = self.page.locator(".plugin-store-card")
        expect(cards).to_have_count(2)
        expect(cards.filter(has=self.page.get_by_role("heading", name="tool.default", exact=True))).to_contain_text(
            "Packaged Lua plugin")
        expect(cards.filter(has=self.page.get_by_role("heading", name="model.local", exact=True))).to_contain_text(
            "Unavailable")
        expect(self.page.locator(".store-guidance")).to_contain_text("Installing your own plugins is not available yet")
        self.page.get_by_role("searchbox", name="Search plugins", exact=True).fill("model.local")
        expect(cards).to_have_count(1)
        self.assertTrue(self.methods)
        self.assertEqual(set(self.methods), {"GET"})
        self.assertEqual(self.errors, [])

    def test_unknown_registry_schema_is_not_presented_as_an_empty_healthy_store(self):
        self.catalog["capabilities_schema"] = "mcp-tool-catalog.v-next"
        self.open_store("Tools")
        expect(self.page.locator(".store-state")).to_contain_text("not available yet")
        expect(self.page.locator(".tool-package")).to_have_count(0)
        self.assertTrue(self.methods)
        self.assertEqual(set(self.methods), {"GET"})
        self.assertEqual(self.errors, [])

    def test_tools_whose_package_is_not_listed_still_show_under_other_tools(self):
        self.catalog["tool_packages"] = [row for row in self.catalog["tool_packages"] if row["id"] != "ticketing"]
        self.open_store("Tools")
        other = self.package("Other tools")
        expect(other).to_have_count(1)
        # Without a known package there is nothing to switch as a whole; each tool keeps its own switch.
        expect(other.locator(".tool-package-heading").get_by_role("checkbox")).to_have_count(0)
        other.locator(".tool-package-toggle").click()
        expect(other.locator(".tool-store-card h3")).to_have_text(["ticket_create"])
        expect(other.get_by_role("checkbox", name="Use ticket_create", exact=True)).to_be_checked()
        self.assertEqual(self.errors, [])

    def test_old_store_commands_open_the_matching_section(self):
        self.open_first_chat()
        for command, section in (("Tools: MCP tool packages", "Tools"), ("Skill Library", "Skill Library"),
                                 ("Plugin Store", "Plugin Store")):
            with self.subTest(command=command):
                self.page.keyboard.press("Control+k")
                self.page.locator("#commandSearch").fill(command)
                self.page.locator("#commandSearch").press("Enter")
                expect(self.page.locator(".workspace-title h1")).to_have_text("Store")
                expect(self.page.get_by_role("tab", name=section, exact=True)).to_have_attribute(
                    "aria-selected", "true")
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(ExtensionStoreViewTests(name) for name in loader.getTestCaseNames(ExtensionStoreViewTests)
                             if name in ExtensionStoreViewTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
