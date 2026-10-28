"""Built Engineering UI (FR-093) with isolated APIs: no application or provider effects.

Covers saving desired topologies, refusing drift reports that are not advisory
for the exact open version, owner separation of late answers, PCB netlist
inspection and readable monochrome text.
"""
import copy
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST

TOPOLOGY, OTHER, CREATED = "a" * 32, "b" * 32, "d" * 32
DIGEST = "e" * 64


def saved(identity=TOPOLOGY, version=2, name="Lab stack"):
    return {"topology_id": identity, "name": name, "version": version, "design_sha256": DIGEST,
            "state_kind": "desired",
            "design": {"nodes": [
                {"id": "container:itsm-surrealdb", "kind": "container", "label": "Database",
                 "properties": {"state": "running"}},
                {"id": "endpoint:phoenix", "kind": "endpoint", "label": "Backend", "properties": {"up": True}}],
                "edges": [{"from": "endpoint:phoenix", "to": "container:itsm-surrealdb", "relation": "depends_on"}]},
            "layout": {"container:itsm-surrealdb": {"x": 40, "y": 40}, "endpoint:phoenix": {"x": 300, "y": 40}}}


def drift(identity=TOPOLOGY, version=2):
    return {"schema": "topology-drift.v1", "state_kind": "simulated", "topology_id": identity,
            "topology_version": version, "observed_at": "2026-10-29T01:00:00+00:00",
            "observation_sha256": "c" * 64,
            "sources": [{"id": "containers", "state": "observed", "error_code": None},
                        {"id": "endpoints", "state": "observed", "error_code": None},
                        {"id": "router", "state": "unavailable", "error_code": "provider_timeout"}],
            "nodes": [{"id": "container:itsm-surrealdb", "status": "drifted", "differences": [
                {"property": "state", "expected": "running", "observed": "exited", "observed_present": True}]},
                {"id": "endpoint:phoenix", "status": "matches", "differences": []}],
            "counts": {"matches": 1, "drifted": 1, "missing": 0, "unknown": 0},
            "potentially_affected": ["endpoint:phoenix"], "not_in_design": ["container:itsm-git-lab"],
            "execution_enabled": False, "apply_to_live": False,
            "notes": ["A drift report never changes a device; live changes use governed, approved tools."]}


NETLIST_REPORT = {
    "schema": "pcb-netlist-inspection.v1", "state_kind": "desired", "actuation": "none", "format": "kicad",
    "tool": "Eeschema 7.0.10", "sha256": "f" * 64,
    "summary": {"components": 3, "nets": 3, "connections": 7, "errors": 1, "warnings": 0},
    "components": [], "nets": [],
    "findings": [{"severity": "error", "code": "missing_footprint", "subject": "R1",
                  "message": "This component has no footprint, so it cannot be placed on the board."}],
    "findings_truncated": False}


class EngineeringTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.owner = "fixture-owner"
        self.records = {TOPOLOGY: saved(), OTHER: saved(OTHER, name="Other stack")}
        self.saves, self.checks, self.netlists = [], [], []
        self.pending_lists, self.pending_checks = [], []
        self.hold_list = self.hold_check = self.fail_list = False
        self.drift_override = self.netlist_override = None
        super().setUp()
        self.page.set_default_timeout(5000)

    def tearDown(self):
        for route in self.pending_lists + self.pending_checks:
            route.abort()
        super().tearDown()

    def summaries(self):
        return [{key: row[key] for key in ("topology_id", "name", "version", "design_sha256")}
                for row in self.records.values()] if self.owner == "fixture-owner" else []

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
            if path == "/api/v1/topologies":
                if request.method == "GET":
                    if self.fail_list:
                        route.fulfill(status=503, json={"error": "engineering_unavailable"})
                    elif self.hold_list:
                        self.pending_lists.append(route)
                    else:
                        route.fulfill(json={"topologies": self.summaries()})
                else:
                    self.save(route, CREATED, 1)
                return
            if path.startswith("/api/v1/topologies/"):
                identity = path.split("/")[4]
                if path.endswith("/drift"):
                    self.checks.append({"id": identity, "body": request.post_data_json,
                                        "csrf": request.headers.get("x-csrf-token")})
                    if self.hold_check:
                        self.pending_checks.append(route)
                    else:
                        route.fulfill(json=self.drift_override or drift(identity, request.post_data_json["version"]))
                    return
                if request.method == "GET":
                    route.fulfill(json={"topology": self.records[identity]})
                elif request.method == "PUT":
                    self.save(route, identity, request.post_data_json["base_version"] + 1)
                elif request.method == "DELETE":
                    self.records.pop(identity, None)
                    route.fulfill(json={"topology_id": identity, "archived": True})
                return
            if path == "/api/v1/engineering/netlist":
                self.netlists.append({"body": request.post_data_json, "csrf": request.headers.get("x-csrf-token")})
                route.fulfill(json=self.netlist_override or NETLIST_REPORT)
                return
        super().route(route)

    def save(self, route, identity, version):
        body = route.request.post_data_json
        self.saves.append({"id": identity, "body": copy.deepcopy(body),
                           "csrf": route.request.headers.get("x-csrf-token")})
        row = {**saved(identity, version, body["name"]), "design": copy.deepcopy(body["design"]),
               "layout": copy.deepcopy(body["layout"])}
        self.records[identity] = row
        route.fulfill(json={"topology": row})

    def open_engineering(self, command="Infrastructure topology"):
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill(command)
        self.page.locator("#commandSearch").press("Enter")
        expect(self.page.locator(".workflow-panel h2")).to_have_text("PCB / Infrastructure Simulator")

    def open_topology(self):
        self.open_first_chat()
        self.open_engineering()
        select = self.page.locator("#topologyOpen")
        expect(select).to_be_enabled()
        select.select_option(TOPOLOGY)
        expect(self.page.locator("#topologyName")).to_have_value("Lab stack")

    def assert_clean(self):
        self.assertEqual(self.errors, [])

    def test_the_rail_keeps_its_place_and_opens_the_same_view(self):
        self.open_first_chat()
        rail = self.page.get_by_role("button", name="PCB / Infra Simulator", exact=True)
        expect(rail).to_be_visible()
        rail.click()
        expect(self.page.locator(".workflow-panel h2")).to_have_text("PCB / Infrastructure Simulator")
        expect(self.page.locator("#topologyOpen option")).to_have_count(3)
        self.assert_clean()

    def test_a_new_topology_is_drawn_typed_and_saved_with_csrf(self):
        self.open_first_chat()
        self.open_engineering()
        expect(self.page.get_by_text("Add a node to start your desired topology.", exact=True)).to_be_visible()
        self.page.locator("#topologyNodeKind").select_option("container")
        self.page.locator("#topologyNodeName").fill("itsm-surrealdb")
        self.page.get_by_role("button", name="Add node", exact=True).click()
        self.page.locator("#topologyNodeKind").select_option("endpoint")
        self.page.locator("#topologyNodeName").fill("phoenix")
        self.page.get_by_role("button", name="Add node", exact=True).click()
        expect(self.page.locator(".topology-node")).to_have_count(2)
        properties = self.page.locator("#topologyNodeProperties")
        properties.fill("up=true\nport=4000")
        properties.dispatch_event("change")
        self.page.locator("#topologyEdgeRelation").select_option("depends_on")
        self.page.locator("#topologyEdgeTarget").select_option("container:itsm-surrealdb")
        self.page.get_by_role("button", name="Add connection", exact=True).click()
        self.page.locator("#topologyName").fill("Fresh stack")
        self.page.get_by_role("button", name="Save", exact=True).click()
        expect(self.page.get_by_text("Saved version 1.", exact=True)).to_be_visible()
        body = self.saves[0]["body"]
        self.assertEqual(self.saves[0]["csrf"], "fixture-csrf")
        self.assertNotIn("base_version", body)
        self.assertEqual(body["design"]["nodes"][1]["properties"], {"up": True, "port": 4000})
        self.assertEqual(body["design"]["edges"], [
            {"from": "endpoint:phoenix", "to": "container:itsm-surrealdb", "relation": "depends_on"}])
        self.assertEqual(set(body["layout"]), {"container:itsm-surrealdb", "endpoint:phoenix"})
        self.assert_clean()

    def test_credentials_in_properties_are_refused_before_saving(self):
        self.open_topology()
        self.page.locator(".topology-node").first.click()
        properties = self.page.locator("#topologyNodeProperties")
        properties.fill("admin_password=hunter2")
        properties.dispatch_event("change")
        expect(self.page.locator(".workflow-panel [role=alert]")).to_contain_text("cannot hold credentials")
        self.assertEqual(self.saves, [])
        self.assert_clean()

    def test_drift_check_sends_only_the_saved_version_and_labels_every_state(self):
        self.open_topology()
        self.page.get_by_role("button", name="Check drift", exact=True).click()
        expect(self.page.get_by_text("Simulated comparison · version 2", exact=True)).to_be_visible()
        self.assertEqual(self.checks, [{"id": TOPOLOGY, "body": {"version": 2}, "csrf": "fixture-csrf"}])
        node = self.page.locator('.topology-node[data-node="container:itsm-surrealdb"]')
        expect(node).to_have_attribute("data-status", "drifted")
        expect(node).to_contain_text("Drifted")
        expect(self.page.locator('[data-source="router"]')).to_contain_text("unavailable · provider_timeout")
        expect(self.page.get_by_text("Potentially affected (graph reach, not an outage): endpoint:phoenix",
                                     exact=True)).to_be_visible()
        node.click()
        expect(self.page.get_by_text('state: expected "running", observed "exited"', exact=True)).to_be_visible()
        self.assert_clean()

    def test_unsaved_changes_block_the_check_and_clear_an_old_report(self):
        self.open_topology()
        self.page.get_by_role("button", name="Check drift", exact=True).click()
        expect(self.page.get_by_text("Simulated comparison · version 2", exact=True)).to_be_visible()
        self.page.locator("#topologyName").fill("Edited stack")
        expect(self.page.get_by_text("Simulated comparison · version 2", exact=True)).to_have_count(0)
        check = self.page.get_by_role("button", name="Check drift", exact=True)
        expect(check).to_be_disabled()
        # The handler refuses on its own too, not only through the disabled button.
        check.evaluate("button => { button.disabled = false; button.click(); }")
        expect(self.page.locator(".workflow-panel [role=alert]")).to_contain_text("Save your changes first")
        self.assertEqual(len(self.checks), 1)
        self.assert_clean()

    def test_reports_that_are_not_advisory_for_this_version_are_refused(self):
        for override, message in (({**drift(), "execution_enabled": True}, "not an advisory comparison"),
                                  ({**drift(), "state_kind": "observed"}, "not an advisory comparison"),
                                  (drift(version=3), "describes another topology version")):
            self.drift_override = override
            self.open_topology()
            self.page.get_by_role("button", name="Check drift", exact=True).click()
            expect(self.page.locator(".workflow-panel [role=alert]")).to_contain_text(message)
            expect(self.page.locator(".topology-drift")).to_have_count(0)
        self.assert_clean()

    def test_a_late_drift_report_never_reaches_another_owner(self):
        self.open_topology()
        self.hold_check = True
        self.page.get_by_role("button", name="Check drift", exact=True).click()
        self.page.wait_for_function("document.querySelector('#topologyName').disabled")
        route = self.pending_checks.pop()
        self.page.keyboard.press("Control+k")
        self.page.locator("#commandSearch").fill("Account settings")
        self.page.locator("#commandSearch").press("Enter")
        self.page.locator(".account-view").get_by_role("button", name="Sign out", exact=True).click()
        expect(self.page.get_by_role("heading", name="Sign in", exact=True)).to_be_visible()
        self.owner = "second-owner"
        self.page.get_by_placeholder("you@example.com").fill("second@example.test")
        self.page.get_by_placeholder("Password", exact=True).fill("fixture-password")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Account")
        route.fulfill(json=drift())
        # If the new owner's list cannot load, the previous owner's rows must not be offered.
        self.fail_list = True
        self.open_engineering()
        expect(self.page.locator(".workflow-panel [role=alert]")).to_be_visible()
        expect(self.page.locator("#topologyOpen option")).to_have_count(1)
        self.fail_list = False
        self.open_engineering()
        expect(self.page.locator("#topologyOpen option")).to_have_count(1)
        expect(self.page.locator("#topologyName")).to_have_value("New topology")
        expect(self.page.locator(".topology-drift")).to_have_count(0)
        self.assert_clean()

    def test_pcb_netlist_is_read_from_a_file_and_inspected(self):
        self.open_first_chat()
        self.open_engineering("PCB netlist")
        expect(self.page.get_by_role("tab", name="PCB", exact=True)).to_have_attribute("aria-selected", "true")
        self.page.locator("#netlistFile").set_input_files({"name": "board.net", "mimeType": "text/plain",
                                                           "buffer": b'(export (version "E"))'})
        expect(self.page.get_by_text("Selected: board.net", exact=True)).to_be_visible()
        self.page.get_by_role("button", name="Inspect netlist", exact=True).click()
        expect(self.page.get_by_text("3 components, 3 nets, 7 connections. 1 error, 0 warnings.",
                                     exact=True)).to_be_visible()
        expect(self.page.locator('[data-severity="error"]')).to_contain_text("R1")
        self.assertEqual(self.netlists, [{"body": {"netlist": '(export (version "E"))'}, "csrf": "fixture-csrf"}])
        self.assert_clean()

    def test_a_netlist_report_that_claims_actuation_is_refused(self):
        self.netlist_override = {**NETLIST_REPORT, "actuation": "flash"}
        self.open_first_chat()
        self.open_engineering("PCB netlist")
        self.page.locator("#netlistFile").set_input_files({"name": "board.net", "mimeType": "text/plain",
                                                           "buffer": b"(export)"})
        self.page.get_by_role("button", name="Inspect netlist", exact=True).click()
        expect(self.page.locator(".workflow-panel [role=alert]")).to_contain_text("not a design inspection")
        expect(self.page.locator('[aria-label="Netlist inspection"]')).to_have_count(0)
        self.assert_clean()

    def test_engineering_text_is_readable_at_desktop_and_phone_widths(self):
        self.open_topology()
        self.page.get_by_role("button", name="Check drift", exact=True).click()
        expect(self.page.get_by_text("Simulated comparison · version 2", exact=True)).to_be_visible()
        for width in (1280, 390):
            self.page.set_viewport_size({"width": width, "height": 900})
            for selector in (".workflow-panel .operation-note", ".topology-node strong", ".topology-node small",
                             ".topology-drift .workflow-run span", ".simulation-tab:not(.active)"):
                self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5, (width, selector))
        self.assert_clean()

    def test_desktop_layout_fits_the_saved_design_and_keeps_fields_single_line(self):
        self.page.set_viewport_size({"width": 1440, "height": 1000})
        self.open_topology()
        canvas = self.page.locator(".topology-canvas")
        # Both saved nodes are visible without scrolling the canvas sideways.
        self.assertLessEqual(canvas.evaluate("el => el.scrollWidth - el.clientWidth"), 0)
        self.page.locator(".topology-node").first.click()
        for selector in ("#topologyNodeName", "#topologyNodeLabel"):
            self.assertLessEqual(self.page.locator(selector).bounding_box()["height"], 48, selector)
        self.assert_clean()

    def test_netlist_picker_shows_one_selection_and_findings_read_left_to_right(self):
        self.open_first_chat()
        self.open_engineering("PCB netlist")
        picker = self.page.locator("label[for=netlistFile]")
        expect(picker).to_have_text("Choose netlist file")
        self.assertLessEqual(self.page.locator("#netlistFile").bounding_box()["width"], 1)
        self.page.locator("#netlistFile").set_input_files({"name": "board.net", "mimeType": "text/plain",
                                                           "buffer": b"(export)"})
        self.page.get_by_role("button", name="Inspect netlist", exact=True).click()
        expect(self.page.get_by_text("3 components, 3 nets, 7 connections. 1 error, 0 warnings.",
                                     exact=True)).to_be_visible()
        finding = self.page.locator('[data-severity="error"]')
        label, message = finding.locator("span").nth(0).bounding_box(), finding.locator("span").nth(1).bounding_box()
        # The message starts right after its label, not at the far edge of the row.
        self.assertLess(message["x"] - (label["x"] + label["width"]), 40)
        self.assert_clean()


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(EngineeringTests(name) for name in loader.getTestCaseNames(EngineeringTests)
                             if name in EngineeringTests.__dict__)


if __name__ == "__main__":
    unittest.main()
