"""The Learning surface (FR-087), with isolated HTTP fixtures.

Shows the owner's models and training dataset versions, checks one selection
against the gates that still block a candidate run, and lists those gates.
Nothing on this page starts, loads or promotes a model.
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST

MODEL, REMOTE = "a" * 32, "b" * 32
CURRENT, REPLACED = "c" * 32, "d" * 32
DIGEST = "1" * 64


def method(identity, roles, tuning, entrypoint):
    return {"id": identity, "roles": roles, "tuning": tuning, "entrypoint": entrypoint,
            "requires": "reviewed data with independent validation"}


CATALOG = {
    "schema": "learning-catalog.v1", "execution_enabled": False, "promotion_enabled": False,
    "methods": [method("sft", ["hub", "specialist"], ["full", "lora", "qlora"], "scripts/train_recipe.py"),
                method("dpo", ["specialist"], ["qlora"], "scripts/train_preferences.py"),
                method("ppo", ["hub"], ["qlora"], "scripts/train_ppo.py")],
    "models": [
        {"id": REMOTE, "name": "Outbound model", "backend": "http", "state": "ready", "source_kind": "outbound",
         "training_available": False},
        {"id": MODEL, "name": "Hub model", "backend": "local", "state": "ready", "source_kind": "local",
         "training_available": False}],
    "datasets": [
        {"id": REPLACED, "name": "Ticket triage", "purpose": "training", "state": "ready", "sha256": "2" * 64,
         "lineage_id": REPLACED, "version": 1, "train_count": 10, "validation_count": 2, "superseded_by": CURRENT},
        {"id": CURRENT, "name": "Ticket triage", "purpose": "training", "state": "ready", "sha256": DIGEST,
         "lineage_id": REPLACED, "version": 2, "train_count": 11, "validation_count": 2, "superseded_by": None}],
}
COMMON = ["fixed_evaluation_required", "host_dispatch_not_integrated", "resource_unknown",
          "separate_promotion_required", "trusted_model_identity_required",
          "trusted_training_configuration_required"]


def receipt(selection, blockers):
    model = next(row for row in CATALOG["models"] if row["id"] == selection["model_id"])
    data = next(row for row in CATALOG["datasets"] if row["id"] == selection["dataset_id"])
    entrypoint = next(row["entrypoint"] for row in CATALOG["methods"] if row["id"] == selection["method"])
    return {"schema": "learning-selection-preflight.v1", "status": "blocked", "preflight_sha256": "9" * 64,
            "method": selection["method"], "role": selection["role"], "tuning": selection["tuning"],
            "entrypoint": entrypoint, "resource_state": "unknown",
            "model": {key: model[key] for key in ("id", "backend", "source_kind", "state")},
            "dataset": {key: data[key] for key in ("id", "sha256", "lineage_id", "version", "train_count",
                                                   "validation_count")},
            "blockers": blockers, "execution_enabled": False, "model_loaded": False,
            "live_tool_execution": False, "promotion_enabled": False}


class LearningTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog_status = 200
        self.checks = []
        self.check_status = 200
        self.check_response = None
        self.defer_check = False
        self.pending_checks = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/api/") and path == "/api/v1/learning":
            if self.catalog_status != 200:
                route.fulfill(status=self.catalog_status, json={
                    "error": "learning_service_unavailable", "message": "Learning could not be reached.",
                    "retryable": True})
            else:
                route.fulfill(json=self.catalog)
            return
        if request.url.startswith(self.base + "/api/") and path == "/api/v1/learning/preflight":
            selection = request.post_data_json
            self.checks.append({"body": selection, "csrf": request.headers.get("x-csrf-token")})
            if self.defer_check:
                self.pending_checks.append((route, selection))
            elif self.check_status != 200:
                route.fulfill(status=self.check_status, json={
                    "error": "learning_dataset_superseded", "message": "Learning refused this selection.",
                    "retryable": False})
            else:
                route.fulfill(json=self.check_response or receipt(selection, COMMON))
            return
        super().route(route)

    def open_learning_page(self):
        # Learning opens from the command palette; the workspace layout is unchanged.
        self.open_first_chat()
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Learning")
        self.page.locator("#commandSearch").press("Enter")
        expect(self.page.locator(".workspace-title h1")).to_have_text("Learning")

    def open_learning(self):
        self.open_learning_page()
        expect(self.page.get_by_role("button", name="Check readiness", exact=True)).to_be_enabled()

    def field(self, name):
        return self.page.locator(".learning-panel").get_by_role("combobox", name=name, exact=True)

    def check(self):
        self.page.locator(".learning-panel").get_by_role("button", name="Check readiness", exact=True).click()

    def test_defaults_choose_sft_qlora_local_weights_and_the_current_dataset(self):
        self.open_learning()
        expect(self.field("Method")).to_have_value("sft")
        expect(self.field("Role")).to_have_value("hub")
        expect(self.field("Adaptation")).to_have_value("qlora")
        expect(self.field("Model")).to_have_value(MODEL)
        expect(self.field("Dataset")).to_have_value(CURRENT)
        # A replaced dataset version is listed with its successor but cannot be chosen.
        replaced = self.field("Dataset").locator(f"option[value='{REPLACED}']")
        expect(replaced).to_be_disabled()
        expect(replaced).to_contain_text("replaced by v2")
        expect(self.page.locator(".learning-panel")).to_contain_text("never starts training")
        expect(self.page.locator(".workspace-rail").get_by_role("button", name="Learning", exact=True)).to_have_count(0)
        self.assertEqual(self.checks, [])
        self.assertEqual(self.errors, [])

    def test_checking_readiness_sends_the_exact_selection_and_lists_every_gate(self):
        self.open_learning()
        self.check()
        gates = self.page.locator(".learning-gate")
        expect(gates).to_have_count(len(COMMON))
        expect(self.page.locator(".learning-result")).to_contain_text("Not ready to train")
        expect(gates.filter(has_text="Bind an independent, fixed evaluation set.")).to_have_count(1)
        expect(self.page.locator(".learning-result")).to_contain_text("scripts/train_recipe.py")
        expect(self.page.locator(".learning-result")).to_contain_text("Ticket triage v2 · 11 training · 2 validation")
        self.assertEqual(self.checks, [{"body": {"method": "sft", "role": "hub", "tuning": "qlora",
                                                 "model_id": MODEL, "dataset_id": CURRENT,
                                                 "dataset_sha256": DIGEST},
                                        "csrf": "fixture-csrf"}])
        # Nothing on the page offers to start or promote a run.
        for name in ("Start training", "Train", "Promote", "Run"):
            expect(self.page.get_by_role("button", name=name, exact=True)).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_choosing_a_method_offers_only_its_supported_settings(self):
        self.open_learning()
        self.field("Method").select_option("dpo")
        expect(self.field("Role")).to_have_value("specialist")
        expect(self.field("Role").locator("option")).to_have_count(1)
        expect(self.field("Adaptation").locator("option")).to_have_count(1)
        self.field("Method").select_option("ppo")
        expect(self.field("Role")).to_have_value("hub")
        expect(self.field("Adaptation")).to_have_value("qlora")
        self.check()
        expect(self.page.locator(".learning-result")).to_be_visible()
        self.assertEqual(self.checks[-1]["body"]["method"], "ppo")

    def test_an_outbound_model_reports_that_it_is_inference_only(self):
        self.check_response = None
        self.open_learning()
        self.field("Model").select_option(REMOTE)
        selection = {"method": "sft", "role": "hub", "tuning": "qlora", "model_id": REMOTE,
                     "dataset_id": CURRENT, "dataset_sha256": DIGEST}
        self.check_response = receipt(selection, sorted(COMMON + ["outbound_connection_is_inference_only"]))
        self.check()
        expect(self.page.locator(".learning-gate").filter(
            has_text="training needs local weights")).to_have_count(1)

    def test_changing_the_selection_discards_a_check_still_in_flight(self):
        self.open_learning()
        self.defer_check = True
        with self.page.expect_request(lambda req: req.url.endswith("/api/v1/learning/preflight")):
            self.check()
        old_route, old_selection = self.pending_checks.pop()
        self.field("Adaptation").select_option("lora")
        old_route.fulfill(json=receipt(old_selection, COMMON))
        expect(self.page.locator(".learning-gate")).to_have_count(0)
        expect(self.page.get_by_role("button", name="Check readiness", exact=True)).to_be_enabled()
        self.defer_check = False
        self.check()
        expect(self.page.locator(".learning-gate")).to_have_count(len(COMMON))
        self.assertEqual(self.checks[-1]["body"]["tuning"], "lora")
        self.assertEqual(self.errors, [])

    def test_a_refused_check_is_stated_and_no_gates_are_shown(self):
        self.check_status = 422
        self.open_learning()
        self.check()
        expect(self.page.locator(".learning-panel").get_by_role("alert")).to_contain_text("learning_dataset_superseded")
        expect(self.page.locator(".learning-gate")).to_have_count(0)

    def test_a_receipt_that_claims_a_run_is_an_error(self):
        self.open_learning()
        selection = {"method": "sft", "role": "hub", "tuning": "qlora", "model_id": MODEL,
                     "dataset_id": CURRENT, "dataset_sha256": DIGEST}
        self.check_response = {**receipt(selection, COMMON), "execution_enabled": True}
        self.check()
        expect(self.page.locator(".learning-panel").get_by_role("alert")).to_be_visible()
        expect(self.page.locator(".learning-gate")).to_have_count(0)

    def test_an_unavailable_service_is_stated_not_shown_as_empty(self):
        self.catalog_status = 503
        self.open_learning_page()
        expect(self.page.locator(".learning-panel").get_by_role("alert")).to_contain_text("learning_service_unavailable")
        expect(self.page.locator(".learning-panel")).not_to_contain_text("No training datasets yet")
        expect(self.page.get_by_role("button", name="Check readiness", exact=True)).to_have_count(0)

    def test_without_training_data_the_page_says_how_to_add_it(self):
        self.catalog["datasets"] = []
        self.open_learning_page()
        expect(self.page.locator(".learning-panel")).to_contain_text("No training datasets yet")
        expect(self.page.get_by_role("button", name="Check readiness", exact=True)).to_have_count(0)
        self.assertEqual(self.checks, [])

    def test_learning_text_meets_wcag_aa_contrast_without_overflow(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_learning_page()
            self.check()
            expect(self.page.locator(".learning-gate")).to_have_count(len(COMMON))
            for selector in (".learning-panel .operation-note", ".learning-panel .review-label",
                             ".learning-select", ".learning-gate", ".learning-result .knowledge-meta",
                             ".learning-panel .secondary-action"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            overflow = self.page.evaluate(
                "document.documentElement.scrollWidth > document.documentElement.clientWidth")
            self.assertFalse(overflow, f"horizontal overflow at {width}px")


def load_tests(loader, _tests, _pattern):
    # The inherited chat tests need their own fixtures; run only this page's tests.
    return unittest.TestSuite(LearningTests(name) for name in loader.getTestCaseNames(LearningTests)
                             if name in LearningTests.__dict__)


if __name__ == "__main__":
    unittest.main()
