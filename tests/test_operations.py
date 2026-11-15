"""Operations uses real snapshot data, and Proxmox power actions only through a confirmed proposal."""
import copy
import os
from pathlib import Path
import time
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_statusbar import CONTRAST


def metric():
    return {"event_id": "e" * 32, "attempt": 1, "recorded_at": "2026-10-26T09:00:00Z",
            "stage": "SPECIALIST_REASONING", "operation": "generate", "adapter": "http",
            "role": "fixture-specialist", "outcome": "success", "repair_of": None,
            "duration_ms": 1250, "queue_ms": None, "execution_ms": None, "first_token_ms": None,
            "generated_tokens": None, "estimated_input_tokens": None, "request_token_budget": None,
            "output_token_cap": None, "dropped_messages": None}


def job(identity, chat, status, metrics):
    return {"job_id": identity * 32, "chat_id": "fixture-" + chat, "status": status, "attempt": 1,
            "selected_agent": "fixture-specialist", "created_at": "2026-10-26T08:00:00Z",
            "claimed_at": "2026-10-26T08:00:01Z", "completed_at": None,
            "queue_wait_ms": 1000, "elapsed_ms": 3000, "metrics_truncated": False, "metrics": metrics}


def snapshot():
    return {"schema": "operations-snapshot.v1", "observed_at": "2026-10-26T09:00:00Z",
            "counts": {"pending": 13, "processing": 3, "waiting_approval": 7,
                       "reconciliation_required": 0, "denied": 0, "outcome_unknown": 1,
                       "completed": 28, "failed": 2, "cancelled": 0},
            "jobs": [job("a", "first", "processing", [metric()]), job("b", "second", "completed", [])]}


def proxmox_snapshot():
    return {"ok": True, "status": "success", "provider": "proxmox", "observed_at": "2026-11-06T09:00:00Z",
            "data": {"schema": "proxmox-overview.v1",
                     "cluster": {"count": 1, "truncated": False,
                                 "members": [{"id": "cluster", "type": "cluster", "name": "lab", "online": None}]},
                     "nodes": {"count": 2, "truncated": False,
                               "nodes": [{"node": "pve-a", "status": "online", "cpu_fraction": 0.25,
                                          "cpu_count": 8, "memory_bytes": 536870912, "memory_total_bytes": 1073741824,
                                          "disk_bytes": 1073741824, "disk_total_bytes": 2147483648, "uptime_seconds": 7200},
                                         {"node": "pve-b", "status": "offline", "cpu_fraction": None,
                                          "cpu_count": 8, "memory_bytes": None, "memory_total_bytes": 1073741824,
                                          "disk_bytes": None, "disk_total_bytes": 2147483648, "uptime_seconds": None}]},
                     "guests": {"count": 2, "truncated": False,
                                "guests": [{"vmid": 101, "node": "pve-a", "type": "qemu", "name": "router-lab",
                                            "status": "running", "cpu_fraction": 0.1, "memory_bytes": 268435456,
                                            "memory_total_bytes": 536870912, "disk_bytes": None,
                                            "disk_total_bytes": None, "uptime_seconds": None},
                                           {"vmid": 102, "node": "pve-b", "type": "lxc", "name": None,
                                            "status": "stopped", "cpu_fraction": None, "memory_bytes": 0,
                                            "memory_total_bytes": 0, "disk_bytes": None,
                                            "disk_total_bytes": None, "uptime_seconds": 0}]}}}


def proxmox_action(action, vmid, node):
    # Mirrors the AI's approval wording: the frozen type and the effect of this action.
    text = {"start": "Start", "shutdown": "Shut down", "reboot": "Reboot", "force_stop": "Force stop"}[action]
    effect = {"start": "It boots the guest.",
              "shutdown": "The guest's own operating system is asked to shut down cleanly (up to 60 seconds).",
              "reboot": "The guest's own operating system is asked to restart cleanly (up to 60 seconds).",
              "force_stop": "The guest is cut off immediately like pulling its power; unsaved data inside it is lost."}
    kind = "qemu" if vmid == 101 else "lxc"
    label = "VM" if kind == "qemu" else "LXC"
    return {"action_id": "f" * 32, "action": action, "node": node, "vmid": vmid, "type": kind, "name": None,
            "risk": "high" if action == "force_stop" else "medium", "status": "waiting_approval",
            "approval_text": f"{text} {label} {vmid} on Proxmox node {node}. {effect[action]} "
                             "Janus waits for the Proxmox task and reads the guest back.",
            "created_at": "2026-11-16T03:00:00Z", "decided_at": None, "error": None}


class OperationsTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.snapshot = snapshot()
        self.operations_status = 200
        self.operations_requests = []
        self.operations_pending = []
        self.hold_operations = False
        self.proxmox_status = 200
        self.proxmox_requests = []
        self.proxmox_body = None
        self.action_posts = []
        self.action_decisions = []
        self.actions = []
        self.action_refusal = None
        self.owner = "fixture-owner"
        self.history_reads = []
        super().setUp()
        self.page.set_default_timeout(5000)

    def tearDown(self):
        for route in self.operations_pending:
            route.abort()
        self.operations_pending.clear()
        super().tearDown()

    def auth(self):
        return {"user": {"user_id": self.owner, "email": "owner@example.test",
                         "display_name": "Fixture Owner" if self.owner == "fixture-owner" else "Second Owner",
                         "role": "user"}, "session_id": "session-" + self.owner, "csrf_token": "fixture-csrf"}

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        bundle = os.getenv("OPERATIONS_TEST_BUNDLE")
        if bundle and request.url.startswith(self.base + "/") and path == "/js/app.js":
            route.fulfill(content_type="application/javascript", body=Path(bundle).read_text())
            return
        if request.url.startswith(self.base + "/api/"):
            if path in {"/api/v1/auth/me", "/api/v1/auth/login"}:
                route.fulfill(json=self.auth())
                return
            if path == "/api/v1/auth/logout":
                route.fulfill(json={"status": "signed_out"})
                return
            if path == "/api/v1/operations":
                self.operations_requests.append(request.method)
                if self.hold_operations:
                    self.operations_pending.append(route)
                elif self.operations_status != 200:
                    route.fulfill(status=self.operations_status, json={"error": "fixture-private-error-do-not-display"})
                else:
                    route.fulfill(json=self.snapshot)
                return
            if path == "/api/v1/proxmox/overview":
                self.proxmox_requests.append(request.method)
                if self.proxmox_status == 200:
                    route.fulfill(json=proxmox_snapshot())
                else:
                    route.fulfill(status=self.proxmox_status, json=self.proxmox_body or
                                  {"error": getattr(self, "proxmox_error", "proxmox_not_configured")})
                return
            if path == "/api/v1/proxmox/actions":
                if request.method == "GET":
                    route.fulfill(json={"actions": self.actions})
                    return
                body = request.post_data_json
                self.action_posts.append((body, request.headers.get("x-csrf-token")))
                if self.action_refusal:
                    route.fulfill(status=409, json=self.action_refusal)
                    return
                action = proxmox_action(body["action"], body["vmid"], body["node"])
                self.actions.insert(0, action)
                route.fulfill(status=201, json=action)
                return
            if path.startswith("/api/v1/proxmox/actions/"):
                action_id, decision = path.split("/")[-2:]
                self.action_decisions.append((action_id, decision, request.headers.get("x-csrf-token")))
                action = next(item for item in self.actions if item["action_id"] == action_id)
                if decision == "approve":
                    action.update(status="succeeded", observed_status="running", verification_ok=True,
                                  upid="UPID:pve-b:0001:0002:0003:vzstart:102:janus@pve!dashboard:")
                else:
                    action.update(status="rejected")
                route.fulfill(json=action)
                return
            if path.startswith("/api/v2/chats/") and path.endswith("/history"):
                key = path.split("/")[-2]
                self.history_reads.append(key)
                route.fulfill(json={"messages": [{"role": "user", "content":
                    "First chat history" if key == "fixture-first" else "Second chat history"}]})
                return
        super().route(route)

    def open_operations(self):
        self.open_first_chat()
        self.page.locator(".sidebar").get_by_role("button", name="Operations", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Operations")

    def assert_safe(self):
        self.assertTrue(self.operations_requests)
        self.assertTrue(all(method == "GET" for method in self.operations_requests))
        self.assertTrue(all(method == "GET" for method in self.proxmox_requests))
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_queue_counts_and_call_measurements_come_from_snapshot(self):
        self.open_operations()
        expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("13")
        expect(self.page.locator('.operation-count[data-status="completed"] strong')).to_have_text("28")
        expect(self.page.locator(".operation-job")).to_have_count(2)
        row = self.page.locator('.operation-job[data-job-id="' + "a" * 32 + '"]')
        row.get_by_role("button", name="Show recorded calls", exact=True).click()
        expect(row.locator(".operation-call")).to_have_count(1)
        expect(row.locator(".operation-call")).to_contain_text("Specialist reasoning")
        expect(row.locator(".operation-call")).to_contain_text("1.25 s")
        expect(row.locator(".operation-call")).to_contain_text("Not recorded")
        historical = self.page.locator('.operation-job[data-job-id="' + "b" * 32 + '"]')
        expect(historical).to_contain_text("Inference timings: Not recorded")
        expect(historical.get_by_role("button", name="Show recorded calls", exact=True)).to_have_count(0)
        self.assert_safe()

    def test_proxmox_dashboard_renders_only_observed_inventory(self):
        self.open_operations()
        dashboard = self.page.locator(".proxmox-dashboard")
        self.page.locator(".proxmox-dashboard .proxmox-live-status, .proxmox-dashboard .proxmox-unavailable").wait_for()
        unavailable = dashboard.locator(".proxmox-unavailable")
        if unavailable.count():
            self.fail("Proxmox request failed: " + str(unavailable.get_attribute("data-error-code")))
        expect(dashboard.get_by_text("Connected", exact=True)).to_be_visible()
        expect(dashboard.locator(".proxmox-summary-card").nth(0)).to_contain_text("1")
        expect(dashboard.locator(".proxmox-summary-card").nth(1)).to_contain_text("1 / 2")
        expect(dashboard.locator(".proxmox-summary-card").nth(2)).to_contain_text("1")
        expect(dashboard.locator(".proxmox-summary-card").nth(3)).to_contain_text("1")
        expect(dashboard.locator(".proxmox-table").first).to_contain_text("pve-a")
        expect(dashboard.locator(".proxmox-table").last).to_contain_text("router-lab")
        expect(dashboard.locator(".proxmox-table").last).to_contain_text("Unnamed")
        self.assertEqual(self.proxmox_requests, ["GET"])
        self.assert_safe()

    def test_unconfigured_proxmox_is_not_presented_as_an_empty_cluster(self):
        self.proxmox_status = 503
        self.proxmox_error = "proxmox_not_configured"
        self.open_operations()
        dashboard = self.page.locator(".proxmox-dashboard")
        expect(dashboard.get_by_text("Connection not configured", exact=True)).to_be_visible()
        expect(dashboard.locator(".proxmox-summary-card")).to_have_count(0)
        self.assertEqual(self.proxmox_requests, ["GET"])
        self.assert_safe()

    def test_invalid_proxmox_configuration_is_named_distinctly(self):
        self.proxmox_status = 503
        self.proxmox_error = "proxmox_configuration_invalid"
        self.open_operations()
        dashboard = self.page.locator(".proxmox-dashboard")
        expect(dashboard.get_by_text("Configuration invalid", exact=True)).to_be_visible()
        expect(dashboard.locator(".proxmox-summary-card")).to_have_count(0)
        expect(dashboard.locator(".proxmox-unavailable")).to_have_attribute("data-error-code", "proxmox_configuration_invalid")
        self.assertEqual(self.proxmox_requests, ["GET"])
        self.assert_safe()

    def test_failed_proxmox_reads_stay_unavailable_without_fabricating_data(self):
        self.proxmox_status = 503
        self.proxmox_error = "proxmox_read_failed"
        self.open_operations()
        dashboard = self.page.locator(".proxmox-dashboard")
        expect(dashboard.get_by_text("Proxmox data unavailable", exact=True)).to_be_visible()
        expect(dashboard.locator(".proxmox-summary-card")).to_have_count(0)
        expect(dashboard.locator(".proxmox-unavailable")).to_have_attribute("data-error-code", "proxmox_read_failed")
        self.assertEqual(self.proxmox_requests, ["GET"])
        self.assert_safe()

    def test_a_failed_read_shows_the_cause_the_service_named(self):
        self.proxmox_status = 503
        self.proxmox_body = {"error": "proxmox_read_failed", "reason": "provider_unreachable",
                             "message": "Proxmox VE could not be reached, or it closed the connection before answering."}
        self.open_operations()
        dashboard = self.page.locator(".proxmox-dashboard")
        failure = dashboard.locator(".proxmox-unavailable")
        expect(failure).to_have_attribute("data-error-code", "proxmox_read_failed")
        expect(failure).to_have_attribute("data-error-reason", "provider_unreachable")
        expect(failure.get_by_text("Proxmox data unavailable", exact=True)).to_be_visible()
        expect(failure).to_contain_text("could not be reached")
        self.assert_safe()

    def test_the_dashboard_refreshes_itself_only_while_it_is_on_screen(self):
        self.page.clock.install()
        self.open_operations()
        self.page.locator(".proxmox-dashboard .proxmox-live-status").wait_for()
        self.assertEqual(self.proxmox_requests, ["GET"])
        # One interval at a time: a read still in flight is never doubled.
        for expected in (2, 3):
            self.page.clock.run_for(10_500)
            self.wait_for_count(self.proxmox_requests, expected)
            self.page.locator(".proxmox-dashboard .proxmox-live-status").wait_for()
        seen = len(self.proxmox_requests)
        self.set_visibility("hidden")
        self.page.clock.run_for(60_000)
        self.page.wait_for_timeout(200)
        self.assertEqual(len(self.proxmox_requests), seen, "a hidden page kept reading Proxmox")
        # Coming back reads at once instead of showing a stale snapshot.
        self.set_visibility("visible")
        self.wait_for_count(self.proxmox_requests, seen + 1)
        seen = len(self.proxmox_requests)
        self.page.locator('.operation-job[data-job-id="' + "a" * 32 + '"]').get_by_role(
            "button", name="Open chat", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Chat")
        self.page.clock.run_for(60_000)
        self.page.wait_for_timeout(200)
        self.assertEqual(len(self.proxmox_requests), seen, "another view kept reading Proxmox")
        self.assert_safe()

    def test_a_power_action_needs_the_exact_target_confirmed_before_anything_runs(self):
        self.open_operations()
        guest = self.page.locator('.proxmox-guest-row[data-vmid="102"]')
        guest.get_by_role("button", name="Start 102", exact=True).click()
        dialog = self.page.get_by_role("dialog", name="Confirm Proxmox action")
        expect(dialog).to_contain_text("Start LXC 102 on Proxmox node pve-b.")
        self.assertEqual(len(self.action_posts), 1)
        body, csrf = self.action_posts[0]
        self.assertEqual({key: body[key] for key in ("node", "vmid", "action")},
                         {"node": "pve-b", "vmid": 102, "action": "start"})
        self.assertEqual(csrf, "fixture-csrf")
        self.assertEqual(self.action_decisions, [])
        dialog.get_by_role("button", name="Start", exact=True).click()
        expect(self.page.locator(".proxmox-actions")).to_contain_text("Succeeded")
        expect(self.page.locator(".proxmox-actions")).to_contain_text("running")
        self.assertEqual([decision[:2] for decision in self.action_decisions], [("f" * 32, "approve")])
        self.assertEqual(self.action_decisions[0][2], "fixture-csrf")

    def test_cancelling_the_confirmation_rejects_the_proposal_and_runs_nothing(self):
        self.open_operations()
        guest = self.page.locator('.proxmox-guest-row[data-vmid="101"]')
        guest.get_by_role("button", name="Force stop 101", exact=True).click()
        dialog = self.page.get_by_role("dialog", name="Confirm Proxmox action")
        expect(dialog).to_contain_text("Force stop")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        expect(dialog).to_have_count(0)
        self.assertEqual([decision[1] for decision in self.action_decisions], ["reject"])
        expect(self.page.locator(".proxmox-actions")).to_contain_text("Rejected")

    def test_only_actions_that_apply_to_a_guest_state_are_offered(self):
        self.open_operations()
        running = self.page.locator('.proxmox-guest-row[data-vmid="101"]')
        stopped = self.page.locator('.proxmox-guest-row[data-vmid="102"]')
        for name in ("Shut down 101", "Reboot 101", "Force stop 101"):
            expect(running.get_by_role("button", name=name, exact=True)).to_be_visible()
        expect(running.get_by_role("button", name="Start 101", exact=True)).to_have_count(0)
        expect(stopped.get_by_role("button", name="Start 102", exact=True)).to_be_visible()
        expect(stopped.get_by_role("button", name="Shut down 102", exact=True)).to_have_count(0)

    def test_a_refused_action_shows_why_and_opens_no_confirmation(self):
        self.action_refusal = {"error": "proxmox_action_refused", "message": "LXC 102 is locked (backup)."}
        self.open_operations()
        self.page.locator('.proxmox-guest-row[data-vmid="102"]').get_by_role("button", name="Start 102",
                                                                              exact=True).click()
        expect(self.page.locator(".proxmox-dashboard").get_by_role("alert")).to_contain_text("locked (backup)")
        expect(self.page.get_by_role("dialog", name="Confirm Proxmox action")).to_have_count(0)
        self.assertEqual(self.action_decisions, [])

    def test_ask_in_chat_prefills_an_exact_request_without_sending_it(self):
        self.open_operations()
        self.page.locator('.proxmox-guest-row[data-vmid="101"]').get_by_role(
            "button", name="Ask in chat about 101", exact=True).click()
        expect(self.page.locator(".workspace-title h1")).to_have_text("Chat")
        expect(self.page.locator("#messageInput")).to_have_value("What is the current status of VMID 101 on node pve-a?")
        self.assertEqual(self.submissions, [])

    def test_a_pending_action_left_from_earlier_can_still_be_reviewed(self):
        self.actions = [proxmox_action("reboot", 101, "pve-a")]
        self.open_operations()
        row = self.page.locator(".proxmox-action").first
        expect(row).to_contain_text("Waiting for your confirmation")
        row.get_by_role("button", name="Review", exact=True).click()
        dialog = self.page.get_by_role("dialog", name="Confirm Proxmox action")
        expect(dialog).to_contain_text("Reboot VM 101 on Proxmox node pve-a.")
        self.page.keyboard.press("Escape")
        expect(dialog).to_have_count(0)
        self.assertEqual([decision[1] for decision in self.action_decisions], ["reject"])

    def test_action_text_and_the_confirmation_are_legible_at_both_widths(self):
        self.actions = [proxmox_action("start", 102, "pve-b")]
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_operations()
            guest = self.page.locator('.proxmox-guest-row[data-vmid="101"]')
            expect(guest.get_by_role("button", name="Ask in chat about 101", exact=True)).to_have_text("Ask in chat")
            for selector in (".proxmox-guest-actions .secondary-action", ".proxmox-action-heading .capability-badge",
                             ".proxmox-action .operation-note"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            # A status is read at a glance, not squinted at.
            self.assertGreaterEqual(self.font_px(".proxmox-action-heading .capability-badge"), 11)
            # The destructive button in a row is not the most prominent control.
            self.assertEqual(self.page.evaluate("""() => [...document.querySelectorAll(
                '.proxmox-guest-row[data-vmid="101"] .proxmox-power')].map((n) => getComputedStyle(n).fontWeight)
                .filter((value, index, all) => all.indexOf(value) === index).length"""), 1)
            guest.get_by_role("button", name="Force stop 101", exact=True).click()
            dialog = self.page.get_by_role("dialog", name="Confirm Proxmox action")
            expect(dialog).to_be_visible()
            for selector in (".proxmox-confirm-target dt", ".proxmox-confirm .secondary-action",
                             ".proxmox-confirm-warning"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            # The data-loss warning reads at least as large as the general description.
            self.assertGreaterEqual(self.font_px(".proxmox-confirm-warning"), self.font_px(".proxmox-confirm-text"))
            box = dialog.bounding_box()
            self.assertGreaterEqual(box["x"], 0)
            self.assertLessEqual(box["x"] + box["width"], width)
            self.assertLessEqual(box["y"] + box["height"], height)
            dialog.get_by_role("button", name="Cancel", exact=True).click()
            expect(dialog).to_have_count(0)
        self.assertEqual(self.errors, [])

    def font_px(self, selector):
        return self.page.evaluate("(s) => parseFloat(getComputedStyle(document.querySelector(s)).fontSize)", selector)

    def wait_for_count(self, items, count, timeout_ms=5000):
        deadline = time.monotonic() + timeout_ms / 1000
        while len(items) < count:
            if time.monotonic() > deadline:
                self.fail(f"expected {count} requests, saw {len(items)}")
            self.page.wait_for_timeout(25)

    def set_visibility(self, state):
        self.page.evaluate("""(state) => {
            Object.defineProperty(document, 'visibilityState', {configurable: true, get: () => state});
            Object.defineProperty(document, 'hidden', {configurable: true, get: () => state === 'hidden'});
            document.dispatchEvent(new Event('visibilitychange'));
        }""", state)

    def test_counts_status_and_secondary_text_meet_wcag_aa_contrast(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_first_chat()
            # The palette reaches Operations at every width; phones hide the sidebar.
            self.page.keyboard.press("Control+k")
            self.page.locator("#commandSearch").fill("Operations")
            self.page.locator("#commandSearch").press("Enter")
            expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("13")
            self.page.get_by_role("button", name="Show recorded calls", exact=True).click()
            for selector in (".operation-count .run-label", ".operations-panel .section-heading-row span",
                             ".operation-job-heading .capability-badge", ".operation-call-outcome",
                             ".operation-measurement span", ".operations-panel .operation-note"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            # A long status label wraps inside its card instead of pushing the number out of line.
            tops = self.page.locator(".operation-count strong").evaluate_all(
                "nodes => nodes.map((node) => Math.round(node.getBoundingClientRect().bottom))")
            rows = 4 if width > 650 else 2
            for start in range(0, len(tops), rows):
                self.assertEqual(len(set(tops[start:start + rows])), 1, f"count values misaligned at {width}px")
        self.assert_safe()

    def test_refresh_uses_new_data_and_failures_cannot_display_a_zero_queue(self):
        self.open_operations()
        expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("13")
        self.operations_status = 503
        self.page.get_by_role("button", name="Refresh operations", exact=True).click()
        expect(self.page.get_by_role("alert")).to_contain_text("HTTP 503")
        expect(self.page.locator(".operation-count")).to_have_count(0)
        expect(self.page.get_by_text("fixture-private-error-do-not-display")).to_have_count(0)
        self.operations_status = 200
        self.snapshot["counts"] = {key: 0 for key in self.snapshot["counts"]}
        self.snapshot["jobs"] = []
        self.page.get_by_role("button", name="Refresh operations", exact=True).click()
        expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("0")
        expect(self.page.get_by_text("No recent tasks were returned.", exact=True)).to_be_visible()
        self.assert_safe()

    def test_invalid_snapshot_and_auth_failure_are_explicit(self):
        self.snapshot["counts"]["pending"] = False
        self.open_operations()
        expect(self.page.get_by_role("alert")).to_contain_text("response was invalid")
        expect(self.page.locator(".operation-count")).to_have_count(0)
        self.operations_status = 401
        self.page.get_by_role("button", name="Refresh operations", exact=True).click()
        expect(self.page.get_by_role("alert")).to_contain_text("HTTP 401")
        expect(self.page.locator(".operation-job")).to_have_count(0)
        self.assert_safe()

    def test_first_and_last_job_open_their_exact_saved_chat(self):
        self.open_first_chat()
        for identity, expected in (("b", "fixture-second"), ("a", "fixture-first")):
            self.page.locator(".sidebar").get_by_role("button", name="Operations", exact=True).click()
            row = self.page.locator('.operation-job[data-job-id="' + identity * 32 + '"]')
            row.get_by_role("button", name="Open chat", exact=True).click()
            expect(self.page.locator(".workspace-title h1")).to_have_text("Chat")
            expect(self.page.get_by_text("Second chat history" if expected == "fixture-second" else "First chat history",
                                         exact=True)).to_be_visible()
            self.assertEqual(self.history_reads[-1], expected)
        self.assert_safe()

    def test_command_palette_opens_operations_and_mobile_layout_keeps_measurements(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_first_chat()
            self.page.keyboard.press("Control+k")
            self.page.locator("#commandSearch").fill("Operations")
            self.page.locator("#commandSearch").press("Enter")
            expect(self.page.locator(".workspace-title h1")).to_have_text("Operations")
            expect(self.page.locator(".operation-job")).to_have_count(2)
            self.page.get_by_role("button", name="Show recorded calls", exact=True).click()
            self.assertTrue(self.page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"),
                            f"Operations overflows at {width}px")
            expect(self.page.locator(".operation-call")).to_contain_text("Generated tokens")
        self.assert_safe()

    def test_a_late_response_cannot_cross_confirmed_sign_out_and_new_owner(self):
        self.hold_operations = True
        self.open_operations()
        expect(self.page.get_by_text("Loading your operations…", exact=True)).to_be_visible()
        self.assertEqual(len(self.operations_pending), 1)
        old = copy.deepcopy(self.snapshot)
        self.page.get_by_title("More", exact=True).click()
        self.page.get_by_role("button", name="Sign out", exact=True).click()
        expect(self.page.get_by_role("button", name="Sign in", exact=True)).to_be_visible()
        self.owner = "second-owner"
        self.page.locator("label.auth-field", has_text="Email").locator("input").fill("second@example.test")
        self.page.locator("label.auth-field", has_text="Password").locator("input").fill("fixture-password")
        self.page.get_by_role("button", name="Sign in", exact=True).click()
        expect(self.page.locator(".sidebar-footer")).to_contain_text("Second Owner")
        with self.page.expect_request(lambda request: urlparse(request.url).path == "/api/v1/operations"):
            self.page.locator(".sidebar").get_by_role("button", name="Operations", exact=True).click()
        self.assertEqual(len(self.operations_pending), 2)
        self.operations_pending.pop(0).fulfill(json=old)
        self.page.evaluate("() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
        expect(self.page.get_by_text("Loading your operations…", exact=True)).to_be_visible()
        expect(self.page.locator(".operation-count")).to_have_count(0)
        own = snapshot()
        own["counts"]["pending"] = 2
        own["jobs"] = []
        self.operations_pending.pop(0).fulfill(json=own)
        expect(self.page.locator('.operation-count[data-status="pending"] strong')).to_have_text("2")
        expect(self.page.locator(".operation-job")).to_have_count(0)
        self.assert_safe()


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(OperationsTests(name) for name in loader.getTestCaseNames(OperationsTests)
                             if name in OperationsTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
