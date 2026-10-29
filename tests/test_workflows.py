"""Built workflow UI with isolated APIs: no application/provider effects.

Delayed and malformed receipts exercise recovery and owner separation through
the actual generated frontend, rather than imitating its state transitions.
"""
import copy
import json
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation

WORKFLOW, OTHER, CREATED = "a" * 32, "b" * 32, "d" * 32
DIGEST, JOB, CHAT = "e" * 64, "f" * 32, "c" * 32


def saved(identity=WORKFLOW, version=2, name="Provision identity"):
    return {"workflow_id": identity, "name": name, "version": version,
            "definition_sha256": DIGEST, "execution": "durable_job",
            "definition": {"version": 1, "steps": [{"id": "step_1", "capability": "fixture_identity_create",
                "grounded_arguments": {"login": ["Dana"]}, "after_success_of": None}]},
            "layout": {"step_1": {"x": 40, "y": 40}}}


class WorkflowTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.owner = "fixture-owner"
        self.records = {WORKFLOW: saved(), OTHER: saved(OTHER, name="Other workflow")}
        self.saves, self.archives, self.runs, self.history = [], [], [], []
        self.pending_lists, self.pending_runs = [], []
        self.hold_list = self.hold_run = False
        self.save_override = self.archive_override = self.run_override = None
        self.run_http_status = 200
        super().setUp()
        self.page.set_default_timeout(5000)

    def tearDown(self):
        for route in self.pending_lists + [entry[0] for entry in self.pending_runs]:
            route.abort()
        self.pending_lists.clear()
        self.pending_runs.clear()
        super().tearDown()

    def summaries(self):
        return [{key: row[key] for key in ("workflow_id", "name", "version", "definition_sha256")}
                for row in self.records.values()] if self.owner == "fixture-owner" else []

    def run_receipt(self, identity, body):
        row = self.records[identity]
        return {"job_id": JOB, "chat_id": CHAT, "status": "pending",
                "submission_id": body["submission_id"], "workflow_id": identity,
                "workflow_version": body["version"], "workflow_contract": row["definition"],
                "workflow_contract_hash": row["definition_sha256"]}

    def route(self, route):
        request, path = route.request, urlparse(route.request.url).path
        if request.url.startswith(self.base + "/api/"):
            if path in {"/api/v1/auth/me", "/api/v1/auth/login"}:
                route.fulfill(json={"user": {"user_id": self.owner, "email": "owner@example.test",
                    "display_name": "Fixture Owner", "role": "user"},
                    "session_id": "fixture-session" if self.owner == "fixture-owner" else "new-session",
                    "csrf_token": "fixture-csrf"})
                return
            if path == "/api/v1/auth/logout":
                route.fulfill(json={"status": "logged_out"})
                return
            if path == "/api/v1/auth/preferences":
                route.fulfill(json={"preferences": {"task_completed": False}})
                return
            if path == "/api/v1/auth/sessions":
                route.fulfill(json={"sessions": []})
                return
            if path == "/api/v1/workflows":
                if request.method == "GET":
                    if self.hold_list:
                        self.pending_lists.append(route)
                    else:
                        route.fulfill(json={"workflows": self.summaries()})
                else:
                    self.save(route, CREATED, 1)
                return
            if path.startswith("/api/v1/workflows/"):
                identity = path.split("/")[4]
                if path.endswith("/runs"):
                    if request.method == "GET":
                        route.fulfill(json={"runs": self.history})
                    else:
                        body = request.post_data_json
                        self.runs.append({"id": identity, "body": copy.deepcopy(body),
                                          "csrf": request.headers.get("x-csrf-token")})
                        receipt = copy.deepcopy(self.run_override or self.run_receipt(identity, body))
                        if self.hold_run:
                            self.pending_runs.append((route, receipt))
                        elif self.run_http_status == 409:
                            # Phoenix refused the exact run before admission and released its slot.
                            slot = self.intent_slots[(self.owner, "workflow", identity)]
                            slot["state"], slot["receipt"] = "rejected", {"error": "workflow_version_conflict"}
                            route.fulfill(status=409, json={"error": "workflow_version_conflict"})
                        elif self.run_http_status != 200:
                            route.fulfill(status=self.run_http_status, json={"error": "workflow_unavailable"})
                        else:
                            route.fulfill(json=receipt)
                    return
                if request.method == "GET":
                    route.fulfill(json={"workflow": self.records[identity]})
                elif request.method == "PUT":
                    self.save(route, identity, request.post_data_json["base_version"] + 1)
                elif request.method == "DELETE":
                    self.archives.append({"id": identity, "csrf": request.headers.get("x-csrf-token")})
                    receipt = self.archive_override or {"workflow_id": identity, "archived": True}
                    if receipt.get("archived") is True and receipt.get("workflow_id") == identity:
                        self.records.pop(identity, None)
                    route.fulfill(json=receipt)
                return
        super().route(route)

    def save(self, route, identity, version):
        body = route.request.post_data_json
        self.saves.append({"id": identity, "body": copy.deepcopy(body),
                           "csrf": route.request.headers.get("x-csrf-token")})
        row = {**saved(identity, version, body["name"]), "definition": copy.deepcopy(body["definition"]),
               "layout": copy.deepcopy(body["layout"])}
        self.records[identity] = row
        route.fulfill(json=self.save_override if self.save_override is not None else {"workflow": row})

    def open_automation_page(self):
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Automation")
        self.page.locator("#commandSearch").press("Enter")
        expect(self.page.locator(".workflow-panel h2")).to_have_text("Automation")

    def open_workflow(self):
        self.open_first_chat()
        self.open_automation_page()
        select = self.page.locator("#workflowOpen")
        expect(select).to_be_enabled()
        select.select_option(WORKFLOW)
        expect(self.page.locator("#workflowName")).to_have_value("Provision identity")
        expect(self.page.get_by_role("button", name="Run saved version", exact=True)).to_be_enabled()

    def start_run(self):
        self.page.locator("#automationRunMessage").fill("Provision the reviewed identity")
        self.page.get_by_role("button", name="Run saved version", exact=True).click()

    def change_owner(self):
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Account settings")
        self.page.locator("#commandSearch").press("Enter")
        self.page.locator(".account-view").get_by_role("button", name="Sign out", exact=True).click()
        expect(self.page.get_by_role("heading", name="Sign in", exact=True)).to_be_visible()
        self.owner = "second-owner"
        self.hold_list = False
        self.page.get_by_placeholder("you@example.com").fill("second@example.test")
        self.page.get_by_placeholder("Password", exact=True).fill("fixture-password")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Account")
        self.open_automation_page()
        expect(self.page.locator("#workflowOpen")).to_be_enabled()
        expect(self.page.locator("#workflowName")).to_have_value("New workflow")

    def assert_clean(self):
        self.assertEqual(self.errors, [])

    def test_save_and_archive_confirm_exact_receipts_and_leave_editor_usable(self):
        self.open_workflow()
        self.page.locator("#workflowName").fill("Reviewed identity workflow")
        self.page.get_by_role("button", name="Save version", exact=True).click()
        expect(self.page.get_by_text("Saved version 3.", exact=True)).to_be_visible()
        self.assertEqual(self.saves[0]["id"], WORKFLOW)
        self.assertEqual(self.saves[0]["body"]["base_version"], 2)
        self.assertEqual(self.saves[0]["csrf"], "fixture-csrf")
        self.page.get_by_role("button", name="Archive", exact=True).click()
        expect(self.page.get_by_text("Workflow archived. Its past runs and chats are kept.", exact=True)).to_be_visible()
        expect(self.page.locator("#workflowOpen")).to_be_enabled()
        expect(self.page.locator("#workflowName")).to_be_enabled()
        expect(self.page.locator("#workflowName")).to_have_value("New workflow")
        self.assertEqual(self.archives, [{"id": WORKFLOW, "csrf": "fixture-csrf"}])
        self.assert_clean()

    def test_archive_clears_old_canvas_dependency_before_a_new_workflow(self):
        self.open_workflow()
        self.page.locator("#automationAddAfter").select_option("step_1")
        self.page.get_by_role("button", name="Archive", exact=True).click()
        expect(self.page.locator("#workflowName")).to_have_value("New workflow")
        expect(self.page.locator("#automationAddAfter")).to_have_value("")
        add = self.page.get_by_role("button", name="Add step", exact=True)
        expect(add).to_be_enabled()
        add.click()
        expect(self.page.locator(".workflow-step")).to_have_count(1)
        self.assert_clean()

    def test_malformed_save_and_archive_never_claim_confirmation(self):
        self.save_override = {"workflow": saved(OTHER, version=3, name="Other workflow")}
        self.open_workflow()
        self.page.locator("#workflowName").fill("Reviewed identity workflow")
        self.page.get_by_role("button", name="Save version", exact=True).click()
        expect(self.page.locator(".workflow-panel [role=alert]")).to_contain_text("differs from this exact save request")
        expect(self.page.get_by_text("Saved version 3.", exact=True)).to_have_count(0)
        expect(self.page.get_by_role("button", name="Run saved version", exact=True)).to_be_disabled()
        self.archive_override = {"workflow_id": OTHER, "archived": True}
        self.page.get_by_role("button", name="Archive", exact=True).click()
        expect(self.page.locator(".workflow-panel [role=alert]")).to_contain_text("did not confirm this workflow")
        expect(self.page.locator("#workflowName")).to_have_value("Reviewed identity workflow")
        expect(self.page.get_by_text("Workflow archived. Its past runs and chats are kept.", exact=True)).to_have_count(0)
        self.assert_clean()

    def test_a_run_refused_before_admission_unlocks_the_editor(self):
        self.run_http_status = 409
        self.open_workflow()
        self.start_run()
        expect(self.page.locator(".workflow-panel [role=alert]")).to_contain_text("This workflow changed since you opened it.")
        expect(self.page.get_by_role("button", name="Retry same run", exact=True)).to_have_count(0)
        expect(self.page.get_by_role("button", name="Run saved version", exact=True)).to_be_enabled()
        expect(self.page.locator("#workflowName")).to_be_enabled()
        self.assertEqual(len(self.runs), 1)
        self.assert_clean()

    def test_lost_run_ack_freezes_edits_navigation_and_exact_retry_after_refresh(self):
        self.run_http_status = 503
        self.open_workflow()
        self.start_run()
        retry = self.page.get_by_role("button", name="Retry same run", exact=True)
        expect(retry).to_be_enabled()
        first = copy.deepcopy(self.runs[0])
        for selector in ("#workflowOpen", "#workflowName", "#automationRunMessage", "#automationAddCapability"):
            expect(self.page.locator(selector)).to_be_disabled()
        # Handler guards still apply when native disabled behavior is bypassed.
        self.page.locator("#workflowOpen").evaluate("el => {el.value='';el.dispatchEvent(new Event('change',{bubbles:true}));}")
        self.page.locator("#automationRunMessage").evaluate("el => {el.value='Another run';el.dispatchEvent(new Event('input',{bubbles:true}));}")
        self.page.get_by_role("button", name="Archive", exact=True).dispatch_event("click")
        self.page.get_by_role("button", name="Refresh workflows", exact=True).click()
        expect(retry).to_be_enabled()
        self.assertEqual(len(self.runs), 1)
        self.assertEqual(self.archives, [])
        self.assertEqual(self.saves, [])
        self.run_http_status = 200
        retry.click()
        expect(self.page.get_by_text("Run confirmed: Queued. Open its chat for approvals and results.", exact=True)).to_be_visible()
        self.assertEqual(self.runs[1], first)
        self.assert_clean()

    def test_reload_after_a_lost_run_reply_preserves_the_exact_original_request(self):
        self.run_http_status = 503
        self.open_workflow()
        self.start_run()
        expect(self.page.get_by_role("button", name="Retry same run", exact=True)).to_be_enabled()
        original = copy.deepcopy(self.runs[0])
        # The server saved the run; only its answer was lost.
        self.history = [{"job_id": JOB, "chat_id": CHAT, "workflow_id": WORKFLOW, "workflow_version": 2,
                         "definition_sha256": DIGEST, "status": "pending", "created_at": "2026-10-29T12:00:00Z"}]
        self.page.reload(wait_until="networkidle")
        self.open_automation_page()
        self.page.locator("#workflowOpen").select_option(WORKFLOW)
        expect(self.page.locator(".workflow-run")).to_have_count(1)
        expect(self.page.locator(".workflow-run")).to_contain_text("Queued")
        expect(self.page.get_by_role("button", name="Retry same run", exact=True)).to_be_enabled()
        expect(self.page.get_by_role("button", name="Run saved version", exact=True)).to_have_count(0)
        self.assertEqual(len(self.runs), 1)
        self.run_http_status = 200
        self.page.get_by_role("button", name="Retry same run", exact=True).click()
        expect(self.page.get_by_text("Run confirmed: Queued. Open its chat for approvals and results.", exact=True)).to_be_visible()
        self.assertEqual(self.runs, [original, original])
        self.assert_clean()

    def test_malformed_run_receipt_keeps_recovery_and_never_claims_started(self):
        self.open_workflow()
        self.hold_run = True
        self.start_run()
        self.page.wait_for_function("document.querySelector('#workflowName').disabled")
        self.assertEqual(len(self.pending_runs), 1)
        route, receipt = self.pending_runs.pop()
        receipt["workflow_contract_hash"] = "9" * 64
        route.fulfill(json=receipt)
        expect(self.page.get_by_role("button", name="Retry same run", exact=True)).to_be_enabled()
        expect(self.page.locator(".workflow-panel [role=alert]")).to_contain_text("does not match this workflow version")
        expect(self.page.get_by_text("Run confirmed:", exact=False)).to_have_count(0)
        self.assertEqual(len(self.runs), 1)
        self.assert_clean()

    def test_late_save_list_cannot_replace_another_owners_workflows(self):
        self.open_workflow()
        self.hold_list = True
        self.page.locator("#workflowName").fill("Old owner save")
        self.page.get_by_role("button", name="Save version", exact=True).click()
        expect(self.page.get_by_text("Saved version 3.", exact=True)).to_be_visible()
        self.assertEqual(len(self.pending_lists), 1)
        old_rows = self.summaries()
        self.change_owner()
        self.pending_lists.pop().fulfill(json={"workflows": old_rows})
        expect(self.page.locator("#workflowOpen option")).to_have_count(1)
        expect(self.page.locator("#workflowName")).to_have_value("New workflow")
        expect(self.page.get_by_text("Saved version 3.", exact=True)).to_have_count(0)
        self.assert_clean()

    def test_late_archive_list_cannot_replace_another_owners_workflows_or_busy_state(self):
        self.open_workflow()
        self.hold_list = True
        self.page.get_by_role("button", name="Archive", exact=True).click()
        expect(self.page.get_by_text("Workflow archived. Its past runs and chats are kept.", exact=True)).to_be_visible()
        self.assertEqual(len(self.pending_lists), 1)
        old_rows = self.summaries()
        self.change_owner()
        self.pending_lists.pop().fulfill(json={"workflows": old_rows})
        expect(self.page.locator("#workflowOpen option")).to_have_count(1)
        expect(self.page.locator("#workflowName")).to_be_enabled()
        expect(self.page.get_by_text("Workflow archived. Its past runs and chats are kept.", exact=True)).to_have_count(0)
        self.assert_clean()

    def test_late_run_receipt_cannot_clear_or_populate_another_owner(self):
        self.open_workflow()
        self.hold_run = True
        self.start_run()
        self.page.wait_for_function("document.querySelector('#workflowName').disabled")
        self.assertEqual(len(self.pending_runs), 1)
        self.change_owner()
        route, receipt = self.pending_runs.pop()
        route.fulfill(json=receipt)
        expect(self.page.locator("#workflowName")).to_have_value("New workflow")
        expect(self.page.get_by_text("Run confirmed:", exact=False)).to_have_count(0)
        # Signing out drops the old owner's pending request from the page.
        expect(self.page.get_by_role("button", name="Retry same run", exact=True)).to_have_count(0)
        self.assertEqual(len(self.runs), 1)
        self.assert_clean()


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(WorkflowTests(name) for name in loader.getTestCaseNames(WorkflowTests)
                             if name in WorkflowTests.__dict__)


if __name__ == "__main__":
    unittest.main()
