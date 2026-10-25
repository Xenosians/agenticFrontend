"""Exact connection-row actions in the built UI, using isolated HTTP fixtures.

Run after rebuilding: python tests/test_connection_actions.py
No deployment service, credentials, provider or model is used.
"""

import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation


PROVIDERS = [
    {"id": "fixture-alpha", "name": "First fixture provider", "backend": "http",
     "url": "https://first.example.test/v1", "recommended_model": "first-model",
     "requires_api_key": True, "description": "First isolated provider."},
    {"id": "fixture-omega", "name": "Last fixture provider", "backend": "http",
     "url": "https://last.example.test/v1", "recommended_model": "last-model",
     "requires_api_key": True, "description": "Last isolated provider."},
]

CATALOG = {
    "schema": "extension-catalog.v1",
    "resources": [
        {"id": "first-resource", "kind": "model", "name": "First fixture model",
         "backend": "local", "model": "fixture-model", "state": "ready"},
        {"id": "middle-resource", "kind": "model", "name": "Middle fixture model",
         "backend": "local", "model": "fixture-middle", "state": "ready"},
        {"id": "last-resource", "kind": "dataset", "name": "Last fixture dataset",
         "purpose": "rag", "state": "ready", "source": "fixture", "license": "internal"},
    ],
    "selected": {"model_id": None, "dataset_id": None}, "role_assignments": {},
    "local_profiles": [], "specialist_roles": [], "provider_presets": PROVIDERS,
    "connection_presets": [], "harnesses": [], "connections": [], "capabilities": [],
    "inference_option_support": [],
}


class ConnectionActionTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.connection_mutations = []
        super().setUp()

    def route(self, route):
        path = urlparse(route.request.url).path
        if path == "/api/v1/extensions":
            if route.request.method == "GET":
                route.fulfill(json=self.catalog)
            elif route.request.method == "POST":
                payload = route.request.post_data_json
                self.connection_mutations.append(payload)
                resource = {field: payload["payload"][field]
                            for field in ("name", "backend", "model", "url")}
                route.fulfill(status=201, json={"id": "saved-fixture-model", "kind": "model",
                                              "state": "ready", **resource})
            else:
                route.abort()
            return
        super().route(route)

    def open_connections(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        expect(self.page.get_by_role("heading", name="Available providers", exact=True)).to_be_visible()

    def test_installed_rows_open_the_category_of_the_clicked_resource(self):
        for name, category in (("First fixture model", "Personal"),
                               ("Last fixture dataset", "Data & automation")):
            with self.subTest(resource=name):
                self.open_connections()
                self.page.locator(".plugin-installed .installed-item").filter(has_text=name).click()
                expect(self.page.get_by_role("heading", name=category, exact=True)).to_be_visible()
                self.assertEqual(self.connection_mutations, [])
                self.assertEqual(self.errors, [])

    def test_provider_rows_save_the_clicked_endpoint_model_and_name(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider["id"]):
                self.open_connections()
                self.connection_mutations.clear()
                card = self.page.locator(".marketplace-card").filter(has_text=provider["name"])
                card.get_by_title("Configure provider", exact=True).click()
                expect(self.page.get_by_placeholder("Connection name", exact=True)).to_have_value(provider["name"])
                expect(self.page.get_by_placeholder("Provider model identifier", exact=True)).to_have_value(provider["recommended_model"])
                expect(self.page.get_by_placeholder("https://provider.example/v1", exact=True)).to_have_value(provider["url"])
                self.page.locator('input[type="password"]').fill("fixture-only-key")
                with self.page.expect_response(lambda response:
                        urlparse(response.url).path == "/api/v1/extensions"
                        and response.request.method == "POST"):
                    self.page.get_by_role("button", name="Save connection", exact=True).click()
                self.assertEqual(len(self.connection_mutations), 1)
                mutation = self.connection_mutations[0]
                self.assertEqual(mutation["action"], "model")
                for field, expected in {"name": provider["name"], "backend": provider["backend"],
                                        "model": provider["recommended_model"], "url": provider["url"],
                                        "api_key": "fixture-only-key"}.items():
                    self.assertEqual(mutation["payload"][field], expected)
                self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    # Reuse the fixture lifecycle without rerunning its separate regression suite.
    return unittest.TestSuite(ConnectionActionTests(name) for name in (
        "test_installed_rows_open_the_category_of_the_clicked_resource",
        "test_provider_rows_save_the_clicked_endpoint_model_and_name",
    ))


if __name__ == "__main__":
    unittest.main(verbosity=2)
