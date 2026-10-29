"""The Learning surface (FR-087/088), with isolated HTTP fixtures.

Shows the owner's models and training dataset versions and checks one
selection. A ready check can start one candidate SFT run; the page lists runs
with progress, losses and outcome, can cancel an active run, and never serves
or promotes a candidate.
"""
import copy
import hashlib
import json
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST

MODEL, REMOTE, MISSING = "a" * 32, "b" * 32, "e" * 32
CURRENT, REPLACED = "c" * 32, "d" * 32
DIGEST, CHECK = "1" * 64, "9" * 64
RUN, OLD_RUN = "f" * 32, "0" * 32
LATER = ["fixed_evaluation_required", "separate_promotion_required"]


def method(identity, roles, tuning, entrypoint):
    return {"id": identity, "roles": roles, "tuning": tuning, "entrypoint": entrypoint,
            "requires": "reviewed data with independent validation"}


CATALOG = {
    "schema": "learning-catalog.v2", "promotion_enabled": False,
    "methods": [method("sft", ["hub", "specialist"], ["full", "lora", "qlora"], "scripts/train_recipe.py"),
                method("dpo", ["specialist"], ["qlora"], "scripts/train_preferences.py"),
                method("ppo", ["hub"], ["qlora"], "scripts/train_ppo.py")],
    "models": [
        {"id": REMOTE, "name": "Outbound model", "backend": "http", "state": "ready", "source_kind": "outbound",
         "training_available": False},
        {"id": MODEL, "name": "Hub model", "backend": "local", "state": "ready", "source_kind": "local",
         "training_available": True},
        {"id": MISSING, "name": "Moved weights", "backend": "uploaded", "state": "ready", "source_kind": "local",
         "training_available": False}],
    "datasets": [
        {"id": REPLACED, "name": "Ticket triage", "purpose": "training", "state": "ready", "sha256": "2" * 64,
         "lineage_id": REPLACED, "version": 1, "train_count": 10, "validation_count": 2, "superseded_by": CURRENT},
        {"id": CURRENT, "name": "Ticket triage", "purpose": "training", "state": "ready", "sha256": DIGEST,
         "lineage_id": REPLACED, "version": 2, "train_count": 11, "validation_count": 2, "superseded_by": None}],
}


def receipt(selection, blockers=()):
    model = next(row for row in CATALOG["models"] if row["id"] == selection["model_id"])
    data = next(row for row in CATALOG["datasets"] if row["id"] == selection["dataset_id"])
    entrypoint = next(row["entrypoint"] for row in CATALOG["methods"] if row["id"] == selection["method"])
    return {"schema": "learning-selection-preflight.v2", "status": "blocked" if blockers else "ready",
            "preflight_sha256": CHECK,
            "method": selection["method"], "role": selection["role"], "tuning": selection["tuning"],
            "entrypoint": entrypoint,
            "model": {key: model[key] for key in ("id", "backend", "source_kind", "state")},
            "dataset": {key: data[key] for key in ("id", "sha256", "lineage_id", "version", "train_count",
                                                   "validation_count")},
            "blockers": list(blockers), "later_gates": LATER, "model_loaded": False,
            "live_tool_execution": False, "promotion_enabled": False}


def run(identity=RUN, state="running", step=0, **changes):
    submission = changes.pop("submission_id", identity)
    row = {"schema": "learning-run.v2", "run_id": identity, "submission_id": submission, "state": state, "method": "sft", "role": "hub",
           "tuning": "qlora", "model": {"id": MODEL, "backend": "local", "source_kind": "local"},
           "dataset": {"id": CURRENT, "sha256": DIGEST, "version": 2, "train_count": 11, "validation_count": 2},
           "preflight_sha256": CHECK, "progress": {"step": step, "max_steps": 9},
           "metrics": {"train_loss": None, "validation_loss": None}, "candidate_sha256": None, "error": None,
           "started_at": "2026-10-29T07:00:00+00:00", "finished_at": None,
           "serving_changed": False, "promotion_enabled": False}
    if state != "running":
        row["finished_at"] = "2026-10-29T07:10:00+00:00"
    if state == "completed":
        row.update(candidate_sha256="8" * 64, metrics={"train_loss": 0.4696, "validation_loss": 0.417})
    row.update(changes)
    request = {key: row[key] for key in ("method", "role", "tuning", "preflight_sha256", "submission_id")}
    request.update(model_id=row["model"]["id"], dataset_id=row["dataset"]["id"], dataset_sha256=row["dataset"]["sha256"])
    row["request_sha256"] = hashlib.sha256(json.dumps(request, sort_keys=True, separators=(",", ":")).encode()).hexdigest() if submission is not None else None
    return row


class LearningTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog_status = 200
        self.checks, self.starts, self.cancels = [], [], []
        self.check_status = 200
        self.check_response = None
        self.defer_check = False
        self.pending_checks = []
        self.runs = []
        self.start_reply = None
        self.hold_start = False
        self.pending_starts = []
        self.hold_cancel = False
        self.pending_cancels = []
        self.hold_runs = False
        self.pending_runs = []
        self.resolves = []
        self.resolve_reply = None
        self.signed_out = False
        self.sessions = 0
        self.run_reads = 0
        self.health_interval_ms = None
        super().setUp()
        self.page.set_default_timeout(5000)

    def tearDown(self):
        for route in self.pending_starts + self.pending_runs + self.pending_cancels:
            route.abort()
        super().tearDown()

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if path == "/config.js" and self.health_interval_ms:
            route.fulfill(content_type="application/javascript", body=(
                "window.AGENTIC_CONFIG = Object.freeze({backendBaseUrl:" + json.dumps(self.base)
                + ",pollIntervalMs:10,requiredOperations:true,healthIntervalMs:"
                + str(self.health_interval_ms) + "});"))
            return
        if path == "/api/health":
            route.fulfill(json={"status": "ok", "ai_service": {"reachable": True, "healthy": True, "ready": True}})
            return
        if not request.url.startswith(self.base + "/api/"):
            super().route(route)
            return
        if path in {"/api/v1/auth/me", "/api/v1/auth/login"}:
            if self.signed_out and path == "/api/v1/auth/me":
                route.fulfill(status=401, json={"error": "unauthenticated"})
                return
            self.signed_out = False
            route.fulfill(json={"user": {"user_id": "fixture-owner", "email": "owner@example.test",
                                         "display_name": "Fixture Owner", "role": "user"},
                                "session_id": f"fixture-session-{self.sessions}", "csrf_token": "fixture-csrf"})
            self.sessions += 1
            return
        if path == "/api/v1/auth/logout":
            self.signed_out = True
            route.fulfill(json={"status": "logged_out"})
            return
        if path == "/api/v1/auth/preferences":
            route.fulfill(json={"preferences": {"task_completed": False}})
            return
        if path == "/api/v1/auth/sessions":
            route.fulfill(json={"sessions": []})
            return
        if path == "/api/v1/learning":
            if self.catalog_status != 200:
                route.fulfill(status=self.catalog_status, json={
                    "error": "learning_service_unavailable", "message": "Learning could not be reached.",
                    "retryable": True})
            else:
                route.fulfill(json=self.catalog)
            return
        if path == "/api/v1/learning/preflight":
            selection = request.post_data_json
            self.checks.append({"body": selection, "csrf": request.headers.get("x-csrf-token")})
            if self.defer_check:
                self.pending_checks.append((route, selection))
            elif self.check_status != 200:
                route.fulfill(status=self.check_status, json={
                    "error": "learning_dataset_superseded", "message": "Learning refused this selection.",
                    "retryable": False})
            else:
                route.fulfill(json=self.check_response or receipt(selection))
            return
        if path == "/api/v1/learning/runs" and request.method == "GET":
            self.run_reads += 1
            if self.hold_runs:
                self.pending_runs.append(route)
                return
            route.fulfill(json={"schema": "learning-runs.v2", "runs": self.runs})
            return
        if path == "/api/v1/learning/runs" and request.method == "POST":
            self.starts.append({"body": request.post_data_json, "csrf": request.headers.get("x-csrf-token")})
            if self.hold_start:
                self.pending_starts.append(route)
                return
            body = request.post_data_json
            reply = self.start_reply or run(submission_id=body["submission_id"], role=body["role"], tuning=body["tuning"])
            if isinstance(reply, tuple):
                route.fulfill(status=reply[0], json=reply[1])
            else:
                self.runs.insert(0, reply)
                route.fulfill(json=reply)
            return
        if path == "/api/v1/learning/runs/resolve":
            from urllib.parse import parse_qs
            submission = parse_qs(urlparse(request.url).query).get("submission_id", [None])[0]
            self.resolves.append(submission)
            reply = self.resolve_reply or next((row for row in self.runs if row["submission_id"] == submission),
                                               (404, {"error": "learning_run_unavailable"}))
            if isinstance(reply, tuple): route.fulfill(status=reply[0], json=reply[1])
            else: route.fulfill(json=reply)
            return
        if path.startswith("/api/v1/learning/runs/") and path.endswith("/cancel"):
            identity = path.split("/")[-2]
            self.cancels.append({"run": identity, "csrf": request.headers.get("x-csrf-token")})
            if self.hold_cancel:
                self.pending_cancels.append(route)
                return
            original = next(row for row in self.runs if row["run_id"] == identity)
            cancelled = {**original, "state": "cancelled", "finished_at": "2026-10-29T07:10:00+00:00"}
            self.runs = [cancelled if row["run_id"] == identity else row for row in self.runs]
            route.fulfill(json=cancelled)
            return
        super().route(route)

    def open_learning_page(self):
        # Learning opens from the command palette; the workspace layout is unchanged.
        if self.health_interval_ms:
            # A fast health cadence keeps the network busy, so wait for content, not network idle.
            self.page.goto(self.base + "/")
            expect(self.page.get_by_text("First chat history", exact=True)).to_be_visible()
        else:
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

    def start_button(self):
        return self.page.get_by_role("button", name="Start candidate run", exact=True)

    def test_defaults_choose_sft_qlora_trainable_local_weights_and_the_current_dataset(self):
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
        expect(self.field("Model").locator(f"option[value='{MISSING}']")).to_contain_text(
            "local weights unavailable on this host")
        expect(self.page.locator(".learning-panel")).to_contain_text("never changes what serves your requests")
        expect(self.page.locator(".learning-runs")).to_contain_text("No runs yet.")
        expect(self.page.locator(".workspace-rail").get_by_role("button", name="Learning", exact=True)).to_have_count(0)
        self.assertEqual((self.checks, self.starts), ([], []))
        self.assertEqual(self.errors, [])

    def test_a_ready_check_starts_one_run_from_exactly_that_check(self):
        self.open_learning()
        self.check()
        result = self.page.locator(".learning-result")
        expect(result).to_contain_text("Ready for a candidate run")
        expect(result.get_by_role("list", name="Blockers")).to_have_count(0)
        expect(result.get_by_role("list", name="Later gates").locator("li")).to_have_count(2)
        expect(result).to_contain_text("Ticket triage v2 · 11 training · 2 validation")
        self.start_button().click()
        row = self.page.locator(f'.learning-run[data-run="{RUN}"]')
        expect(row).to_contain_text("Training")
        expect(row).to_contain_text("Step 0 of 9")
        expect(row.get_by_role("button", name="Cancel run")).to_be_enabled()
        submission = self.starts[0]["body"]["submission_id"]
        self.assertRegex(submission, r"^[0-9a-f]{32}$")
        self.assertEqual(self.starts, [{"body": {"method": "sft", "role": "hub", "tuning": "qlora",
                                                 "model_id": MODEL, "dataset_id": CURRENT,
                                                 "dataset_sha256": DIGEST, "preflight_sha256": CHECK, "submission_id": submission},
                                        "csrf": "fixture-csrf"}])
        # A started check is spent: starting again needs a new check.
        expect(self.start_button()).to_have_count(0)
        expect(self.page.locator(".learning-result")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_while_a_run_trains_no_second_run_can_start(self):
        self.runs = [run(step=4)]
        self.open_learning()
        self.check()
        expect(self.start_button()).to_be_disabled()
        expect(self.page.locator(".learning-result")).to_contain_text("A run is already training on this host.")
        # Even a forced click on the disabled button cannot start a second run.
        self.start_button().dispatch_event("click")
        self.page.wait_for_timeout(300)
        self.assertEqual(self.starts, [])

    def test_a_blocked_check_lists_its_blockers_and_offers_no_run(self):
        self.open_learning()
        self.field("Model").select_option(REMOTE)
        selection = {"method": "sft", "role": "hub", "tuning": "qlora", "model_id": REMOTE,
                     "dataset_id": CURRENT, "dataset_sha256": DIGEST}
        self.check_response = receipt(selection, ["outbound_connection_is_inference_only"])
        self.check()
        result = self.page.locator(".learning-result")
        expect(result).to_contain_text("Not ready to train")
        expect(result.get_by_role("list", name="Blockers")).to_contain_text("training needs local weights")
        expect(self.start_button()).to_have_count(0)

    def test_choosing_a_method_offers_only_its_supported_settings(self):
        self.open_learning()
        self.field("Method").select_option("dpo")
        expect(self.field("Role")).to_have_value("specialist")
        expect(self.field("Role").locator("option")).to_have_count(1)
        expect(self.field("Adaptation").locator("option")).to_have_count(1)
        self.field("Method").select_option("ppo")
        expect(self.field("Role")).to_have_value("hub")
        expect(self.field("Adaptation")).to_have_value("qlora")
        selection = {"method": "ppo", "role": "hub", "tuning": "qlora", "model_id": MODEL,
                     "dataset_id": CURRENT, "dataset_sha256": DIGEST}
        self.check_response = receipt(selection, ["evaluated_adapter_checkpoint_required",
                                                  "host_dispatch_not_integrated",
                                                  "independent_simulator_episodes_required"])
        self.check()
        expect(self.page.locator(".learning-result")).to_contain_text("cannot be started from the web yet")
        self.assertEqual(self.checks[-1]["body"]["method"], "ppo")
        expect(self.start_button()).to_have_count(0)

    def test_changing_the_selection_discards_a_check_still_in_flight(self):
        self.open_learning()
        self.defer_check = True
        with self.page.expect_request(lambda req: req.url.endswith("/api/v1/learning/preflight")):
            self.check()
        old_route, old_selection = self.pending_checks.pop()
        self.field("Adaptation").select_option("lora")
        old_route.fulfill(json=receipt(old_selection))
        expect(self.page.locator(".learning-result")).to_have_count(0)
        expect(self.start_button()).to_have_count(0)
        self.defer_check = False
        self.check()
        expect(self.start_button()).to_be_enabled()
        self.assertEqual(self.checks[-1]["body"]["tuning"], "lora")
        self.assertEqual(self.errors, [])

    def test_changing_the_selection_after_a_ready_check_withdraws_the_start(self):
        self.open_learning()
        self.check()
        expect(self.start_button()).to_be_enabled()
        self.field("Role").select_option("specialist")
        expect(self.start_button()).to_have_count(0)
        self.assertEqual(self.starts, [])

    def test_a_refused_start_is_stated_and_never_retried(self):
        self.start_reply = (422, {"error": "learning_check_changed",
                                  "message": "Learning refused this selection.", "retryable": False})
        self.open_learning()
        self.check()
        self.start_button().click()
        expect(self.page.locator(".learning-runs").get_by_role("alert")).to_contain_text("learning_check_changed")
        expect(self.page.locator(".learning-run")).to_have_count(0)
        self.page.wait_for_timeout(300)
        self.assertEqual(len(self.starts), 1)

    def sign_out_and_back_in(self):
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Account settings")
        self.page.locator("#commandSearch").press("Enter")
        self.page.locator(".account-view").get_by_role("button", name="Sign out", exact=True).click()
        expect(self.page.get_by_role("heading", name="Sign in", exact=True)).to_be_visible()
        self.page.get_by_placeholder("you@example.com").fill("owner@example.test")
        self.page.get_by_placeholder("Password", exact=True).fill("fixture-password")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Account")

    def test_a_start_answered_after_sign_out_never_reaches_the_next_session(self):
        self.runs = [run(identity=OLD_RUN, state="completed", step=9)]
        self.open_learning()
        expect(self.page.locator(f'.learning-run[data-run="{OLD_RUN}"]')).to_be_visible()
        self.check()
        self.hold_start = True
        self.start_button().click()
        expect(self.page.get_by_role("button", name="Starting…", exact=True)).to_be_disabled()
        route = self.pending_starts.pop()
        self.hold_start = False
        self.sign_out_and_back_in()
        route.fulfill(json=run())
        # Hold the next run list, so only runs kept in memory from the last session could show.
        self.hold_runs = True
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Learning")
        self.page.locator("#commandSearch").press("Enter")
        expect(self.page.locator(".workspace-title h1")).to_have_text("Learning")
        expect(self.page.locator(".learning-runs")).to_contain_text("Loading runs…")
        expect(self.page.locator(".learning-run")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_runs_show_progress_losses_and_outcome_and_a_candidate_is_never_served(self):
        self.runs = [run(state="failed", step=1, error="insufficient_gpu_memory", identity="1" * 32),
                     run(state="completed", step=9, identity=OLD_RUN)]
        self.open_learning()
        failed = self.page.locator(f'.learning-run[data-run="{"1" * 32}"]')
        expect(failed).to_contain_text("Failed")
        expect(failed.get_by_role("alert")).to_have_text("Not enough free GPU memory for this model.")
        done = self.page.locator(f'.learning-run[data-run="{OLD_RUN}"]')
        expect(done).to_contain_text("Candidate ready")
        expect(done).to_contain_text("Step 9 of 9")
        expect(done).to_contain_text("Training loss 0.470 · validation loss 0.417")
        expect(done).to_contain_text("8" * 64)
        expect(done).to_contain_text("Not serving.")
        for name in ("Promote", "Serve", "Use this model", "Cancel run"):
            expect(done.get_by_role("button", name=name, exact=True)).to_have_count(0)

    def test_cancel_stops_only_that_run(self):
        self.runs = [run(step=3)]
        self.open_learning()
        row = self.page.locator(f'.learning-run[data-run="{RUN}"]')
        row.get_by_role("button", name="Cancel run").click()
        expect(row).to_contain_text("Cancelled")
        expect(row.get_by_role("button", name="Cancel run")).to_have_count(0)
        self.assertEqual(self.cancels, [{"run": RUN, "csrf": "fixture-csrf"}])

    def test_refresh_during_a_start_does_not_discard_its_receipt_or_strand_starting(self):
        self.open_learning()
        self.check()
        self.hold_start = True
        with self.page.expect_request(lambda req: req.url.endswith("/api/v1/learning/runs") and req.method == "POST"):
            self.start_button().click()
        pending = self.pending_starts.pop()
        with self.page.expect_request(lambda req: req.url.endswith("/api/v1/learning/runs") and req.method == "GET"):
            self.page.locator(".learning-runs").get_by_role("button", name="Refresh", exact=True).click()
        pending.fulfill(json=run(submission_id=self.starts[-1]["body"]["submission_id"]))
        expect(self.page.locator(f'.learning-run[data-run="{RUN}"]')).to_be_visible()
        expect(self.page.get_by_role("button", name="Starting…", exact=True)).to_have_count(0)
        self.assertEqual(len(self.starts), 1)

    def test_refresh_during_cancel_does_not_discard_its_receipt_or_strand_cancelling(self):
        self.runs = [run(step=3)]
        self.hold_cancel = True
        self.open_learning()
        row = self.page.locator(f'.learning-run[data-run="{RUN}"]')
        with self.page.expect_request(lambda req: req.url.endswith("/cancel")):
            row.get_by_role("button", name="Cancel run", exact=True).click()
        pending = self.pending_cancels.pop()
        with self.page.expect_request(lambda req: req.url.endswith("/api/v1/learning/runs") and req.method == "GET"):
            self.page.locator(".learning-runs").get_by_role("button", name="Refresh", exact=True).click()
        pending.fulfill(json=run(state="cancelled", step=3))
        expect(row).to_contain_text("Cancelled")
        expect(self.page.get_by_role("button", name="Cancelling…", exact=True)).to_have_count(0)

    def test_a_lost_start_reply_retries_only_the_exact_frozen_submission(self):
        self.start_reply = (503, {"error": "learning_service_unavailable"})
        self.open_learning()
        self.check()
        self.start_button().click()
        pending = self.page.locator(".learning-pending")
        retry = pending.get_by_role("button", name="Retry exact start", exact=True)
        expect(retry).to_be_enabled()
        expected = copy.deepcopy(self.starts[0]["body"])
        expect(self.field("Model")).to_be_disabled()
        expect(self.start_button()).to_have_count(0)
        self.start_reply = None
        retry.click()
        expect(self.page.locator(f'.learning-run[data-run="{RUN}"]')).to_be_visible()
        expect(pending).to_have_count(0)
        self.assertEqual([entry["body"] for entry in self.starts], [expected, expected])

    def test_reload_after_an_unknown_start_shows_the_servers_runs_and_never_resends(self):
        self.start_reply = (503, {"error": "learning_run_outcome_unknown"})
        self.open_learning()
        self.check()
        self.start_button().click()
        expect(self.page.locator(".learning-pending")).to_be_visible()
        expected = copy.deepcopy(self.starts[0]["body"])
        # The server started the run; only its answer was lost.
        self.runs = [run(state="completed", step=9, submission_id=expected["submission_id"])]
        self.page.reload()
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Learning")
        self.page.locator("#commandSearch").press("Enter")
        expect(self.page.locator(f'.learning-run[data-run="{RUN}"]')).to_contain_text("Candidate ready")
        # Nothing was kept in the browser: nothing is resent or left pending.
        expect(self.page.locator(".learning-pending")).to_have_count(0)
        self.assertEqual(len(self.starts), 1, "reload must never submit")

    def test_a_resolution_for_another_submission_cannot_clear_the_unknown_start(self):
        self.start_reply = (503, {"error": "learning_service_unavailable"})
        self.open_learning()
        self.check()
        self.start_button().click()
        pending = self.page.locator(".learning-pending")
        self.resolve_reply = run(state="completed", step=9, submission_id="6" * 32)
        pending.get_by_role("button", name="Check previous start", exact=True).click()
        expect(self.page.locator(".learning-runs").get_by_role("alert")).to_contain_text("still unconfirmed")
        expect(pending).to_be_visible()
        expect(self.page.locator(".learning-run")).to_have_count(0)
        self.assertEqual(len(self.starts), 1)

    def test_run_list_reconciles_a_lost_start_but_never_dispatches_it(self):
        self.start_reply = (503, {"error": "learning_service_unavailable"})
        self.open_learning()
        self.check()
        self.start_button().click()
        pending = self.page.locator(".learning-pending")
        expect(pending).to_be_visible()
        submission = self.starts[0]["body"]["submission_id"]
        self.runs = [run(state="completed", step=9, submission_id=submission)]
        self.page.locator(".learning-runs").get_by_role("button", name="Refresh", exact=True).click()
        expect(pending).to_have_count(0)
        expect(self.page.locator(".learning-run")).to_contain_text("Candidate ready")
        self.assertEqual(len(self.starts), 1)

    def test_a_start_receipt_for_another_selection_remains_unknown(self):
        self.start_reply = run(model={"id": REMOTE, "backend": "local", "source_kind": "local"})
        self.open_learning()
        self.check()
        self.start_button().click()
        expect(self.page.locator(".learning-pending")).to_be_visible()
        expect(self.page.locator(".learning-runs").get_by_role("alert")).to_contain_text("unconfirmed")
        expect(self.page.locator(".learning-run")).to_have_count(0)
        self.assertEqual(len(self.starts), 1)

    def test_a_training_run_updates_itself_and_stops_polling_when_it_ends(self):
        self.health_interval_ms = 60
        self.runs = [run(step=2)]
        self.open_learning()
        row = self.page.locator(f'.learning-run[data-run="{RUN}"]')
        expect(row).to_contain_text("Step 2 of 9")
        self.runs = [run(step=5, metrics={"train_loss": 0.9, "validation_loss": None})]
        expect(row).to_contain_text("Step 5 of 9")
        expect(row).to_contain_text("Training loss 0.900")
        self.runs = [run(state="completed", step=9)]
        expect(row).to_contain_text("Candidate ready")
        settled = self.run_reads
        self.page.wait_for_timeout(400)
        self.assertEqual(self.run_reads, settled, "a finished run is not polled")

    def test_a_run_that_claims_it_is_serving_is_an_error_not_a_run(self):
        self.runs = [run(state="completed", step=9, serving_changed=True)]
        self.open_learning()
        expect(self.page.locator(".learning-runs").get_by_role("alert")).to_be_visible()
        expect(self.page.locator(".learning-run")).to_have_count(0)

    def test_a_refused_check_is_stated_and_no_gates_are_shown(self):
        self.check_status = 422
        self.open_learning()
        self.check()
        expect(self.page.locator(".learning-panel").get_by_role("alert")).to_contain_text("learning_dataset_superseded")
        expect(self.page.locator(".learning-gate")).to_have_count(0)

    def test_a_contradictory_receipt_is_an_error(self):
        self.open_learning()
        selection = {"method": "sft", "role": "hub", "tuning": "qlora", "model_id": MODEL,
                     "dataset_id": CURRENT, "dataset_sha256": DIGEST}
        self.check_response = {**receipt(selection), "blockers": ["local_weights_unavailable"]}
        self.check()
        expect(self.page.locator(".learning-panel").get_by_role("alert")).to_be_visible()
        expect(self.start_button()).to_have_count(0)

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
        self.runs = [run(step=4), run(state="completed", step=9, identity=OLD_RUN)]
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_learning_page()
            self.check()
            expect(self.page.locator(".learning-later .learning-gate")).to_have_count(2)
            for selector in (".learning-panel .operation-note", ".learning-panel .review-label",
                             ".learning-select", ".learning-gate", ".learning-later .learning-gate",
                             ".learning-result .knowledge-meta", ".learning-panel .secondary-action",
                             ".learning-panel .primary-action", ".learning-run .knowledge-meta",
                             ".learning-run .review-status"):
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
