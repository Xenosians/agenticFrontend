"""Dataset version identity on the Data tab (SRS 1.9 FR-085), using isolated HTTP fixtures.

Run after rebuilding: python tests/test_dataset_versions.py
No deployment service, credentials, provider or model is used.
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST
from test_workspace_context import CATALOG

DATASETS = [
    {"id": "a" * 32, "kind": "dataset", "name": "Fixture manual", "purpose": "rag", "state": "ready",
     "source": "fixture", "license": "internal", "version": 1, "lineage_id": "a" * 32,
     "sha256": "1111aaaa" + "0" * 56, "superseded_by": "b" * 32},
    {"id": "b" * 32, "kind": "dataset", "name": "Fixture manual", "purpose": "rag", "state": "ready",
     "source": "fixture", "license": "internal", "version": 2, "lineage_id": "a" * 32,
     "previous_id": "a" * 32, "sha256": "2222bbbb" + "0" * 56},
    {"id": "c" * 32, "kind": "dataset", "name": "Fixture examples", "purpose": "training", "state": "ready",
     "source": "fixture", "license": "internal", "sha256": "3333cccc" + "0" * 56},
]


class DatasetVersionTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog["resources"] = [self.catalog["resources"][0], *copy.deepcopy(DATASETS)]
        self.catalog["selected"] = {"model_id": "fixture-model", "dataset_id": "b" * 32}
        self.mutations = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        if urlparse(request.url).path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            if request.method == "GET":
                route.fulfill(json=self.catalog)
            else:
                self.mutations.append(request.post_data_json)
                route.fulfill(json={"id": "d" * 32, "kind": "dataset", "state": "ready", "version": 3})
            return
        super().route(route)

    def open_tab(self, tab):
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        self.page.locator(".plugin-tabs").get_by_role("button", name=tab, exact=True).click()

    def test_each_dataset_shows_its_version_and_digest(self):
        self.open_tab("Personal")
        rows = self.page.locator(".personal-resource-row")
        versions = self.page.locator(".resource-version")
        # Shown exactly as recorded: a digest is never re-cased.
        expect(versions).to_have_count(3)
        self.assertEqual(versions.evaluate_all("nodes => nodes.map((node) => node.innerText)"),
                         ["v1 · 1111aaaa · replaced by v2", "v2 · 2222bbbb", "v1 · 3333cccc"])
        expect(rows.filter(has_text="Fixture examples")).to_contain_text("v1 · 3333cccc")
        # Versions of one dataset are told apart by name, in the list and the installed rail.
        names = rows.locator(".personal-resource-copy strong")
        self.assertEqual(names.evaluate_all("nodes => nodes.map((node) => node.innerText)"),
                         ["Fixture provider model", "Fixture manual (v1)", "Fixture manual (v2)", "Fixture examples"])
        rail = self.page.locator(".plugin-installed .installed-item strong")
        self.assertEqual(rail.filter(has_text="Fixture manual (v1)").count(), 1)
        # The version is its own line below the kind · state line, never run into it.
        layout = versions.first.evaluate("""(node) => {
            const status = node.parentElement.querySelector(':scope > span');
            return {sibling: node.parentElement.classList.contains('personal-resource-copy'),
                    below: node.getBoundingClientRect().top >= status.getBoundingClientRect().bottom};
        }""")
        self.assertEqual(layout, {"sibling": True, "below": True})
        contrast = self.page.evaluate(CONTRAST, ".resource-version")
        self.assertGreaterEqual(contrast, 4.5)
        self.assertEqual(self.errors, [])

    def test_an_upload_can_replace_the_latest_version_of_a_dataset(self):
        self.open_tab("Data & automation")
        self.page.get_by_role("combobox", name="Purpose", exact=True).select_option("rag")
        target = self.page.get_by_role("combobox", name="Upload as", exact=True)
        expect(target.locator("option")).to_have_text(["New dataset", "New version of Fixture manual (v2)"])
        target.select_option("b" * 32)
        self.page.get_by_placeholder("Dataset name", exact=True).fill("Fixture manual")
        self.page.get_by_placeholder("Owned documentation", exact=True).fill("fixture")
        self.page.get_by_placeholder("Internal / owned", exact=True).fill("internal")
        self.page.locator("#datasetFile").set_input_files(
            files=[{"name": "manual.md", "mimeType": "text/markdown", "buffer": b"Version three."}])
        self.page.locator(".dataset-review input").check()
        with self.page.expect_response(lambda response: urlparse(response.url).path == "/api/v1/extensions"
                                       and response.request.method == "POST"):
            self.page.get_by_role("button", name="Upload dataset", exact=True).click()
        self.assertEqual(len(self.mutations), 1)
        self.assertEqual(self.mutations[0]["action"], "dataset")
        self.assertEqual(self.mutations[0]["payload"]["replaces"], "b" * 32)
        self.assertEqual(self.mutations[0]["payload"]["text"], "Version three.")
        self.assertEqual(self.errors, [])

    def test_a_new_dataset_upload_names_no_earlier_version(self):
        self.open_tab("Data & automation")
        self.page.get_by_role("combobox", name="Purpose", exact=True).select_option("rag")
        expect(self.page.get_by_role("combobox", name="Upload as", exact=True)).to_have_value("")
        self.page.get_by_placeholder("Dataset name", exact=True).fill("Second manual")
        self.page.get_by_placeholder("Owned documentation", exact=True).fill("fixture")
        self.page.get_by_placeholder("Internal / owned", exact=True).fill("internal")
        self.page.locator("#datasetFile").set_input_files(
            files=[{"name": "second.md", "mimeType": "text/markdown", "buffer": b"Another manual."}])
        self.page.locator(".dataset-review input").check()
        with self.page.expect_response(lambda response: urlparse(response.url).path == "/api/v1/extensions"
                                       and response.request.method == "POST"):
            self.page.get_by_role("button", name="Upload dataset", exact=True).click()
        self.assertEqual(len(self.mutations), 1)
        self.assertNotIn("replaces", self.mutations[0]["payload"])
        self.assertEqual(self.errors, [])

    def test_a_training_upload_offers_only_training_histories(self):
        self.open_tab("Data & automation")
        self.page.get_by_role("combobox", name="Purpose", exact=True).select_option("training")
        target = self.page.get_by_role("combobox", name="Upload as", exact=True)
        expect(target.locator("option")).to_have_text(["New dataset", "New version of Fixture examples (v1)"])
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.errors, [])

    def test_reference_choices_name_each_version(self):
        self.open_tab("Personal")
        options = self.page.get_by_role("combobox", name="Reference dataset", exact=True).locator("option")
        expect(options).to_have_text(["No additional dataset", "Fixture manual (v1)", "Fixture manual (v2)"])
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(DatasetVersionTests(name) for name in loader.getTestCaseNames(DatasetVersionTests)
                             if name in DatasetVersionTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
