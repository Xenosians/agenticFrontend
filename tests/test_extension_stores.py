"""Read-only store views of the real MCP and Lua catalogs; no tool is invoked."""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation


CATALOG = {
    "schema": "extension-catalog.v1",
    "capabilities_schema": "mcp-tool-catalog.v1",
    "capabilities": [
        {"id": "account_status", "description": "Read one account status.", "effect": "read",
         "risk": "read", "permission": "directory.read", "provider": "directory",
         "requires_approval": False, "agent_names": ["account-specialist"]},
        {"id": "ticket_create", "description": "Create an issue in the selected Jira project.",
         "effect": "mutation", "risk": "high", "permission": "jira.write", "provider": "jira",
         "requires_approval": True, "agent_names": ["jira-specialist"]},
        {"id": "invalid_tool", "effect": "mutation", "requires_approval": "true"},
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
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        if urlparse(request.url).path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            self.methods.append(request.method)
            if request.method == "GET":
                route.fulfill(json=self.catalog)
            else:
                route.fulfill(status=405, json={"error": "read_only_catalog"})
            return
        super().route(route)

    def open_store(self, button, title):
        self.open_first_chat()
        self.page.locator(".rail-navigation").get_by_role("button", name=button, exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text(title)

    def test_mcp_store_lists_live_registry_metadata_and_filters_without_dispatch(self):
        self.open_store("MCP Tool Store", "MCP Tool Store")
        cards = self.page.locator(".tool-store-card")
        expect(cards).to_have_count(2)
        ticket = cards.filter(has=self.page.get_by_role("heading", name="ticket_create", exact=True))
        expect(ticket).to_contain_text("mutation")
        expect(ticket).to_contain_text("Approval required")
        expect(ticket).to_contain_text("jira-specialist")
        expect(self.page.locator(".store-view")).to_contain_text("Provider readiness is shown separately")
        self.page.get_by_role("searchbox", name="Search MCP tools", exact=True).fill("directory")
        expect(cards).to_have_count(1)
        expect(cards.first).to_contain_text("account_status")
        self.assertTrue(self.methods)
        self.assertEqual(set(self.methods), {"GET"})
        self.assertEqual(self.errors, [])

    def test_lua_store_reports_resolution_and_does_not_offer_unreviewed_install(self):
        self.open_store("Lua Plugin Store", "Lua Plugin Store")
        cards = self.page.locator(".plugin-store-card")
        expect(cards).to_have_count(2)
        expect(cards.filter(has=self.page.get_by_role("heading", name="tool.default", exact=True))).to_contain_text(
            "Packaged Lua adapter")
        expect(cards.filter(has=self.page.get_by_role("heading", name="model.local", exact=True))).to_contain_text(
            "Unavailable")
        expect(self.page.locator(".store-guidance")).to_contain_text("User-installed plugins are not enabled yet")
        self.page.get_by_role("searchbox", name="Search Lua plugins", exact=True).fill("model.local")
        expect(cards).to_have_count(1)
        self.assertTrue(self.methods)
        self.assertEqual(set(self.methods), {"GET"})
        self.assertEqual(self.errors, [])

    def test_unknown_registry_schema_is_not_presented_as_an_empty_healthy_store(self):
        self.catalog["capabilities_schema"] = "mcp-tool-catalog.v-next"
        self.open_store("MCP Tool Store", "MCP Tool Store")
        expect(self.page.locator(".store-state")).to_contain_text("not available yet")
        expect(self.page.locator(".tool-store-card")).to_have_count(0)
        self.assertTrue(self.methods)
        self.assertEqual(set(self.methods), {"GET"})
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(ExtensionStoreViewTests(name) for name in loader.getTestCaseNames(ExtensionStoreViewTests)
                             if name in ExtensionStoreViewTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
