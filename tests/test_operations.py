"""Operations uses real snapshot data, and Proxmox power actions only through a confirmed proposal."""
import copy
import os
from pathlib import Path
import re
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
                                            "disk_total_bytes": None, "uptime_seconds": 0}]},
                     "databases": database_inventory()}}


def database_host(vmid, name, **changes):
    host = {"vmid": vmid, "node": "pve-a", "type": "lxc", "name": name, "engine": "postgres", "status": "running",
            "lock": None, "memory_bytes": 536870912, "memory_total_bytes": 1073741824, "disk_bytes": 322122547,
            "disk_total_bytes": 1073741824, "uptime_seconds": 7200, "backup_job": True, "issues": []}
    host.update(changes)
    return host


def database_inventory():
    hosts = [database_host(103, "reports-archive-with-a-long-name", engine=None, status="stopped",
                           memory_bytes=0, disk_bytes=None, uptime_seconds=None, issues=["not_running"]),
             database_host(102, "cache", engine="redis", disk_bytes=1020054733, backup_job=False,
                           issues=["disk_nearly_full", "no_backup_job"]),
             database_host(101, "orders-db", type="qemu", disk_bytes=None, disk_total_bytes=34359738368)]
    return {"schema": "proxmox-database-inventory.v1", "count": 3, "truncated": False,
            "summary": {"running": 2, "not_running": 1, "without_backup_job": 1, "with_issues": 2},
            "backup_coverage_known": True, "backup_coverage_note": None, "databases": hosts,
            "storage": [{"node": "pve-a", "storage": "local-lvm", "type": "lvmthin", "shared": False,
                         "status": "available", "used_bytes": 85899345920, "total_bytes": 107374182400}],
            "label_hint": None}


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


def tailnet_device(name, **changes):
    device = {"name": name, "dns_name": name + ".tail1234.ts.net", "os": "linux", "client_version": "1.104.4",
              "update_available": False, "online": True, "last_seen": "2026-11-16T05:00:00Z",
              "key_expires": "2027-05-01T00:00:00Z", "key_expiry_disabled": False, "key_expires_in_days": 166,
              "authorized": True, "shared_from_another_tailnet": False, "tags": [], "blocks_incoming": False,
              "routes_advertised": 0, "routes_waiting_for_approval": 0, "exit_node_offered": False,
              "tailnet_lock_error": False,
              "connectivity": {"udp": True, "hard_nat": False, "port_mapping": False, "nearest_relay": "Singapore",
                               "relay_latency_ms": 27.2},
              "issues": []}
    device.update(changes)
    return device


def tailnet_overview():
    devices = [tailnet_device("hummingbird"),
               tailnet_device("kiosk-with-a-long-device-name", os="windows", update_available=True,
                              key_expires_in_days=9,
                              connectivity={"udp": False, "hard_nat": True, "port_mapping": None,
                                            "nearest_relay": "Tokyo", "relay_latency_ms": 90.1},
                              issues=["key_expiring", "udp_blocked", "update_available"]),
               tailnet_device("phone", os="android", online=False, last_seen="2026-11-10T08:00:00Z",
                              connectivity=None)]
    return {"ok": True, "status": "success", "provider": "tailscale", "observed_at": "2026-11-16T05:00:00+00:00",
            "data": {"schema": "tailnet-overview.v1",
                     "devices": {"count": 3, "truncated": False,
                                 "summary": {"online": 2, "offline": 1, "with_issues": 1}, "devices": devices},
                     "dns": {"magic_dns": True, "override_local_dns": False,
                             "nameservers": [{"address": "1.1.1.1", "encrypted": True}], "split_dns": [],
                             "search_domains": []},
                     "dns_error": None}}


LINES_OF = """(selector) => [...document.querySelectorAll(selector)].map((node) => {
    const range = document.createRange();
    range.selectNodeContents(node);
    return new Set([...range.getClientRects()].filter((rect) => rect.width > 0)
        .map((rect) => Math.round(rect.top))).size;
})"""

# Each unit is one fact ("2.0 GiB"); report the units laid out over more than one line.
SPLIT_UNITS = """(units) => [...document.querySelectorAll('[data-fact="copy"]')].flatMap((value) => {
    const node = value.firstChild;
    const text = node.textContent.replace(/\\u00a0/g, " ");
    return units.filter((unit) => {
        const at = text.indexOf(unit);
        if (at < 0) return false;
        const range = document.createRange();
        range.setStart(node, at);
        range.setEnd(node, at + unit.length);
        return new Set([...range.getClientRects()].filter((rect) => rect.width > 0)
            .map((rect) => Math.round(rect.top))).size !== 1;
    });
})"""

# Count phrases of a summary line ("1 never backed up") that the browser broke across lines.
SPLIT_PHRASES = """(selector) => [...document.querySelectorAll(selector + ' .summary-part')].filter((part) =>
    new Set([...part.getClientRects()].filter((rect) => rect.width > 0).map((rect) => Math.round(rect.top))).size > 1
).map((part) => part.textContent)"""


def backup_guest(vmid, name, issues=(), age=None, **changes):
    latest = None if age is None else {"storage": "pbs", "time": 1794800000, "age_days": age,
                                       "size_bytes": 2147483648, "protected": False, "encrypted": True,
                                       "verified": "ok"}
    row = {"vmid": vmid, "node": "pve-a", "type": "lxc", "name": name, "backup_job": "no_backup_job" not in issues,
           "backups": 0 if latest is None else 3, "latest": latest, "issues": list(issues)}
    row.update(changes)
    return row


def proxmox_health():
    guests = [backup_guest(990, "janus-lab", ("never_backed_up", "no_backup_job")),
              backup_guest(102, "cache", ("backup_stale",), age=12.0),
              backup_guest(101, "orders-db-with-a-long-name", age=0.4, type="qemu")]
    disks = [{"device": "/dev/sda", "type": "hdd", "model": "WDC WD40EFRX", "size_bytes": 4000787030016,
              "health": "failed", "wear_used_percent": None, "used_by": "ZFS", "issues": ["smart_failed"]},
             {"device": "/dev/nvme0n1", "type": "nvme", "model": "INTEL SSDPEKNW512G8", "size_bytes": 512110190592,
              "health": "passed", "wear_used_percent": 12, "used_by": "BIOS boot", "issues": []}]
    return {"schema": "proxmox-health.v1",
            "backups": {"ok": True, "status": "success", "provider": "proxmox",
                        "observed_at": "2026-11-16T08:00:00Z",
                        "data": {"schema": "proxmox-backups.v1", "jobs": {"count": 1, "enabled": 1},
                                 "coverage_known": True, "coverage_note": None, "listing_complete": True,
                                 "stale_after_days": 8, "unreadable_storages": [],
                                 "summary": {"guests": 3, "with_recent_backup": 1, "stale": 1, "never": 1,
                                             "without_backup_job": 1},
                                 "storages": [{"node": "pve-a", "storage": "pbs", "type": "pbs", "shared": True,
                                               "backups": 6}],
                                 "count": 3, "truncated": False, "guests": guests}},
            "disks": [{"node": "pve-a", "result": {"ok": True, "status": "success", "provider": "proxmox",
                                                   "observed_at": "2026-11-16T08:00:00Z",
                                                   "data": {"node": "pve-a", "count": 2, "truncated": False,
                                                            "summary": {"disks": 2, "failing": 1, "worn": 0,
                                                                        "health_unknown": 0},
                                                            "disks": disks}}},
                      {"node": "pve-b", "result": {"ok": False, "status": "error", "provider": "proxmox",
                                                   "error_code": "provider_error",
                                                   "error": "Proxmox refused the read (HTTP 403)."}}]}


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
        self.proxmox_overview = None
        self.health_requests = []
        self.health_status = 200
        self.health_body = None
        self.action_posts = []
        self.action_decisions = []
        self.actions = []
        self.action_refusal = None
        self.tailnet_requests = []
        self.tailnet_status = 200
        self.tailnet_body = None
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
                    route.fulfill(json=self.proxmox_overview or proxmox_snapshot())
                else:
                    route.fulfill(status=self.proxmox_status, json=self.proxmox_body or
                                  {"error": getattr(self, "proxmox_error", "proxmox_not_configured")})
                return
            if path == "/api/v1/proxmox/health":
                self.health_requests.append(request.method)
                if self.health_status == 200:
                    route.fulfill(json=self.health_body or proxmox_health())
                else:
                    route.fulfill(status=self.health_status, json=self.health_body or
                                  {"error": "proxmox_dashboard_unavailable"})
                return
            if path == "/api/v1/tailnet/overview":
                self.tailnet_requests.append(request.method)
                if self.tailnet_status == 200:
                    route.fulfill(json=self.tailnet_body or tailnet_overview())
                else:
                    route.fulfill(status=self.tailnet_status, json=self.tailnet_body or {"error": "tailnet_unavailable"})
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
        self.assertTrue(all(method == "GET" for method in self.tailnet_requests))
        self.assertTrue(all(method == "GET" for method in self.health_requests))
        self.assertEqual(self.submissions, [])
        self.assertEqual(self.errors, [])

    def test_the_tailnet_shows_each_devices_observed_health(self):
        self.open_operations()
        panel = self.page.locator(".tailnet-dashboard")
        expect(panel.get_by_role("heading", name="Tailscale network", exact=True)).to_be_visible()
        expect(panel.locator(".tailnet-summary")).to_contain_text("2 online · 1 offline · 1 needs attention")
        healthy = panel.locator('.tailnet-device[data-name="hummingbird"]')
        expect(healthy.locator(".tailnet-device-facts")).to_contain_text("Direct")
        expect(healthy.locator(".tailnet-device-facts")).to_contain_text("Singapore 27 ms")
        expect(healthy.locator(".tailnet-device-facts")).to_contain_text("In 166 days")
        expect(healthy.locator(".tailnet-issue")).to_have_count(0)
        busy = panel.locator('.tailnet-device[data-name="kiosk-with-a-long-device-name"]')
        expect(busy.locator(".tailnet-issue")).to_have_text(["Key expires soon", "UDP blocked", "Update available"])
        expect(busy.locator(".tailnet-device-facts")).to_contain_text("Relayed")
        expect(busy.locator(".tailnet-device-facts")).to_contain_text("Tokyo 90 ms")
        quiet = panel.locator('.tailnet-device[data-name="phone"]')
        expect(quiet).to_contain_text("Offline since 2026-11-10")
        # Offline: there is no live path, so no connection or relay is shown as current.
        expect(quiet.locator('[data-fact="connection"], [data-fact="relay"]')).to_have_count(0)
        expect(quiet.locator('[data-fact="key"]')).to_have_text("In 166 days")
        expect(panel).to_contain_text("MagicDNS on")
        expect(panel).to_contain_text("1.1.1.1 (encrypted)")
        self.assertEqual(self.tailnet_requests, ["GET"])
        self.assert_safe()

    def test_devices_needing_attention_are_first_and_marked_at_a_glance(self):
        body = tailnet_overview()
        body["data"]["devices"]["devices"].append(
            tailnet_device("old-tablet", online=False, last_seen="2026-09-01T00:00:00Z", key_expires_in_days=-12,
                           connectivity=None, issues=["key_expired"]))
        body["data"]["devices"].update(count=4, summary={"online": 2, "offline": 2, "with_issues": 2})
        self.tailnet_body = body
        self.open_operations()
        cards = self.page.locator(".tailnet-dashboard .tailnet-device")
        expect(cards).to_have_count(4)
        # A device that is cut off comes first, then other issues, then healthy devices.
        self.assertEqual(cards.evaluate_all("cards => cards.map((card) => card.dataset.name)"),
                         ["old-tablet", "kiosk-with-a-long-device-name", "hummingbird", "phone"])
        self.assertEqual(cards.evaluate_all("cards => cards.map((card) => card.dataset.attention)"),
                         ["blocking", "warning", "none", "none"])
        styles = self.page.evaluate("""() => {
            const card = (name) => getComputedStyle(document.querySelector(`.tailnet-device[data-name="${name}"]`));
            const pill = getComputedStyle(document.querySelector('.tailnet-device[data-name="hummingbird"] .tailnet-device-state'));
            const issue = getComputedStyle(document.querySelector('.tailnet-issue'));
            return {blocking: card('old-tablet').borderLeftWidth, warning: card('kiosk-with-a-long-device-name').borderLeftWidth,
                    healthy: card('hummingbird').borderLeftWidth, pillRadius: pill.borderTopLeftRadius,
                    issueRadius: issue.borderTopLeftRadius, pillBorder: pill.borderTopStyle};
        }""")
        # Needing attention is visible on the card itself, strongest for a blocking problem.
        self.assertGreater(float(styles["blocking"][:-2]), float(styles["warning"][:-2]))
        self.assertGreater(float(styles["warning"][:-2]), float(styles["healthy"][:-2]))
        # The online/offline state is not drawn like an issue badge.
        self.assertNotEqual((styles["pillRadius"], styles["pillBorder"]), (styles["issueRadius"], "solid"))
        # A tailnet with devices needing attention does not show an all-clear dot.
        expect(self.page.locator(".tailnet-live-status .proxmox-status-dot")).to_have_count(0)
        self.assert_safe()

    def test_an_unavailable_tailnet_says_why_and_shows_no_devices(self):
        self.tailnet_status = 503
        self.tailnet_body = {"error": "tailnet_read_failed", "reason": "provider_timeout",
                             "message": "The Tailscale network did not answer in time."}
        self.open_operations()
        panel = self.page.locator(".tailnet-dashboard")
        failure = panel.locator(".tailnet-unavailable")
        expect(failure).to_have_attribute("data-error-code", "tailnet_read_failed")
        expect(failure).to_have_attribute("data-error-reason", "provider_timeout")
        expect(failure).to_contain_text("did not answer in time")
        expect(panel.locator(".tailnet-device")).to_have_count(0)
        self.tailnet_body = {"error": "tailnet_not_configured"}
        panel.get_by_role("button", name="Refresh Tailscale network", exact=True).click()
        expect(failure).to_have_attribute("data-error-code", "tailnet_not_configured")
        expect(failure.get_by_text("Connection not configured", exact=True)).to_be_visible()
        self.assert_safe()

    def test_a_failed_dns_read_is_named_beside_the_devices(self):
        body = tailnet_overview()
        body["data"]["dns"] = None
        body["data"]["dns_error"] = {"reason": "provider_error", "message": "Tailscale refused the read (HTTP 403)."}
        self.tailnet_body = body
        self.open_operations()
        panel = self.page.locator(".tailnet-dashboard")
        expect(panel.locator(".tailnet-device")).to_have_count(3)
        expect(panel.locator(".tailnet-dns")).to_contain_text("DNS settings could not be read: Tailscale refused")
        self.assert_safe()

    def test_the_tailnet_refreshes_only_while_operations_is_on_screen(self):
        self.page.clock.install()
        self.open_operations()
        self.page.locator(".tailnet-dashboard .tailnet-device").first.wait_for()
        self.assertEqual(self.tailnet_requests, ["GET"])
        self.page.clock.run_for(30_500)
        self.wait_for_count(self.tailnet_requests, 2)
        seen = len(self.tailnet_requests)
        self.set_visibility("hidden")
        self.page.clock.run_for(120_000)
        self.page.wait_for_timeout(200)
        self.assertEqual(len(self.tailnet_requests), seen, "a hidden page kept reading the tailnet")
        self.set_visibility("visible")
        self.wait_for_count(self.tailnet_requests, seen + 1)
        self.assert_safe()

    def test_the_tailnet_panel_is_legible_at_both_widths(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_operations()
            panel = self.page.locator(".tailnet-dashboard")
            panel.locator(".tailnet-device").first.wait_for()
            self.assertEqual(self.page.evaluate(SPLIT_PHRASES, ".tailnet-summary"), [],
                             f"a tailnet summary phrase breaks at {width}px")
            expect(panel.locator(".tailnet-summary .summary-part")).to_have_text(
                ["2 online", "1 offline", "1 needs attention"])
            for selector in (".tailnet-device-name", ".tailnet-device .operation-note", ".tailnet-issue",
                             ".tailnet-summary", ".tailnet-dns"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            self.assertGreaterEqual(self.font_px(".tailnet-issue"), 11)
            self.assertTrue(self.page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"),
                            f"Operations overflows at {width}px")
            # A long device name wraps inside its card instead of pushing the card wider.
            overflow = self.page.evaluate("""() => [...document.querySelectorAll('.tailnet-device')]
                .some((card) => card.scrollWidth > card.clientWidth + 1)""")
            self.assertFalse(overflow, f"a device card overflows at {width}px")
            # A short name is never broken mid-word to make room for its state.
            lines = self.page.evaluate("""() => {
                const name = document.querySelector('.tailnet-device[data-name="phone"] .tailnet-device-name');
                return Math.round(name.getBoundingClientRect().height / (parseFloat(getComputedStyle(name).fontSize) * 1.6));
            }""")
            self.assertEqual(lines, 1, f"a short device name wraps at {width}px")
            # Facts and issues stay readable: values are not squeezed into one-word lines.
            relay_lines = self.page.evaluate("""() => {
                const value = document.querySelector('.tailnet-device[data-name="hummingbird"] [data-fact="relay"]');
                return Math.round(value.getBoundingClientRect().height / (parseFloat(getComputedStyle(value).fontSize) * 1.6));
            }""")
            self.assertEqual(relay_lines, 1, f"the nearest relay wraps at {width}px")
            # Every card states its facts in the same place: key expiry first, whatever else it shows.
            first_facts = panel.locator(".tailnet-device").evaluate_all(
                "cards => cards.map((card) => card.querySelector('.tailnet-device-facts dt').textContent)")
            self.assertEqual(set(first_facts), {"Key expiry"})
            if width < 650:
                # On a phone the state always sits under the name, not beside some names and under others.
                misplaced = self.page.evaluate("""() => [...document.querySelectorAll('.tailnet-device')].filter((card) => {
                    const name = card.querySelector('.tailnet-device-name').getBoundingClientRect();
                    const state = card.querySelector('.tailnet-device-state').getBoundingClientRect();
                    return Math.abs(state.left - name.left) > 1 || state.top < name.bottom - 1;
                }).map((card) => card.dataset.name)""")
                self.assertEqual(misplaced, [], f"device state placement differs at {width}px")
        self.assert_safe()

    def test_database_hosts_show_their_observed_state_capacity_and_backup_coverage(self):
        self.open_operations()
        section = self.page.locator(".proxmox-databases")
        expect(section.get_by_role("heading", name="Database hosts", exact=True)).to_be_visible()
        expect(section.locator(".database-summary")).to_have_text("2 running · 1 not running · 2 need attention")
        hosts = section.locator(".database-host")
        expect(hosts).to_have_count(3)
        # The server orders hosts by their most urgent issue; that order is kept.
        self.assertEqual(hosts.evaluate_all("rows => rows.map((row) => row.dataset.vmid)"), ["103", "102", "101"])
        self.assertEqual(hosts.evaluate_all("rows => rows.map((row) => row.dataset.attention)"),
                         ["blocking", "warning", "none"])
        cache = section.locator('.database-host[data-vmid="102"]')
        expect(cache.locator(".database-engine")).to_have_text("redis")
        expect(cache.locator('[data-fact="disk"]')).to_have_text("973 MiB of 1.0 GiB (95%)")
        expect(cache.locator('[data-fact="backup"]')).to_have_text("No backup job")
        expect(cache.locator(".database-issue")).to_have_text(["Disk nearly full", "No backup job"])
        # A VM's disk use is not measured by Proxmox: its size is shown as a size, never as use.
        orders = section.locator('.database-host[data-vmid="101"]')
        expect(orders.locator('[data-fact="disk"]')).to_have_text("Size 32.0 GiB, use not measured")
        expect(orders.locator('[data-fact="disk"]')).to_have_attribute("title", re.compile("does not measure"))
        expect(orders.locator('[data-fact="backup"]')).to_have_text("Covered by a backup job")
        expect(orders.locator(".database-issue")).to_have_count(0)
        expect(cache.locator('[data-fact="memory"]')).to_have_text("512 MiB of 1.0 GiB")
        stopped = section.locator('.database-host[data-vmid="103"]')
        # A stopped host uses no memory; what it is assigned is the useful fact.
        expect(stopped.locator('[data-fact="memory"]')).to_have_text("1.0 GiB assigned")
        expect(stopped.locator(".database-engine")).to_have_count(0)
        expect(stopped.locator(".database-issue")).to_have_text(["Not running"])
        expect(stopped.locator('.database-issue[data-blocking="true"]')).to_have_count(1)
        expect(section.locator(".database-storage")).to_have_text(
            "Guest disk storage: local-lvm (lvmthin) on pve-a, 80.0 GiB of 100.0 GiB used (80%).")
        # Read-only: the section offers no actions of its own.
        expect(section.get_by_role("button")).to_have_count(0)
        self.assert_safe()

    def test_an_untagged_cluster_explains_how_to_list_a_database_host(self):
        body = proxmox_snapshot()
        body["data"]["databases"].update(count=0, databases=[], storage=[],
                                         summary={"running": 0, "not_running": 0, "without_backup_job": 0,
                                                  "with_issues": 0},
                                         label_hint='Tag a VM or container "db" or "db-<engine>" (for example '
                                                    '"db-postgres") in Proxmox to list it here.')
        self.proxmox_overview = body
        self.open_operations()
        section = self.page.locator(".proxmox-databases")
        expect(section.locator(".database-host")).to_have_count(0)
        expect(section.locator(".empty-card")).to_contain_text("No database hosts are tagged yet.")
        expect(section.locator(".empty-card")).to_contain_text('"db-postgres"')
        self.assertGreaterEqual(self.page.evaluate(CONTRAST, ".proxmox-databases .empty-card"), 4.5)
        self.assert_safe()

    def test_a_backup_lock_is_a_mild_warning_that_names_its_reason(self):
        body = proxmox_snapshot()
        inventory = body["data"]["databases"]
        inventory["databases"].insert(2, database_host(104, "billing", engine="mariadb", lock="backup",
                                                       issues=["locked"]))
        inventory.update(count=4, summary={"running": 3, "not_running": 1, "without_backup_job": 1,
                                           "with_issues": 3})
        self.proxmox_overview = body
        self.open_operations()
        billing = self.page.locator('.proxmox-databases .database-host[data-vmid="104"]')
        expect(billing).to_have_attribute("data-attention", "warning")
        expect(billing.locator(".database-issue")).to_have_text(["Locked: backup"])
        expect(billing.locator('.database-issue[data-blocking="true"]')).to_have_count(0)
        # The reason is said once, on the chip; the line under the name stays short.
        expect(billing.locator(".operation-note")).to_have_text("LXC 104 on pve-a · running")
        self.assert_safe()

    def test_unknown_backup_coverage_says_why_and_marks_no_host_unprotected(self):
        body = proxmox_snapshot()
        inventory = body["data"]["databases"]
        inventory.update(backup_coverage_known=False,
                         backup_coverage_note="Proxmox refused the backup coverage read (HTTP 403); "
                                              "the token needs Sys.Audit on / to see backup jobs.",
                         summary={"running": 2, "not_running": 1, "without_backup_job": None, "with_issues": 1})
        for host in inventory["databases"]:
            host["backup_job"] = None
            host["issues"] = [issue for issue in host["issues"] if issue != "no_backup_job"]
        self.proxmox_overview = body
        self.open_operations()
        section = self.page.locator(".proxmox-databases")
        expect(section.locator(".database-summary")).to_have_text("2 running · 1 not running · 1 needs attention")
        expect(section.locator(".database-coverage-note")).to_contain_text("Backup coverage unknown: Proxmox refused")
        expect(section.locator(".database-coverage-note")).to_contain_text("needs Sys.Audit")
        expect(section.locator('[data-fact="backup"]')).to_have_text(["Backup coverage unknown"] * 3)
        expect(section.locator('.database-issue[data-issue="no_backup_job"]')).to_have_count(0)
        self.assert_safe()

    def test_an_ai_service_without_the_database_section_shows_no_database_claims(self):
        body = proxmox_snapshot()
        del body["data"]["databases"]
        self.proxmox_overview = body
        self.open_operations()
        expect(self.page.locator(".proxmox-guest-row")).to_have_count(2)
        expect(self.page.locator(".proxmox-databases")).to_have_count(0)
        self.assert_safe()

    def test_the_database_hosts_are_legible_at_both_widths(self):
        body = proxmox_snapshot()
        body["data"]["databases"]["databases"][0]["engine"] = "postgresql-with-timescale"
        self.proxmox_overview = body
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_operations()
            section = self.page.locator(".proxmox-databases")
            section.locator(".database-host").first.wait_for()
            self.assertEqual(self.page.evaluate(SPLIT_PHRASES, ".database-summary"), [],
                             f"a database summary phrase breaks at {width}px")
            expect(section.locator(".database-summary .summary-part")).to_have_text(
                ["2 running", "1 not running", "2 need attention"])
            for selector in (".database-host-name", ".database-host .operation-note", ".database-issue",
                             ".database-summary", ".database-storage", ".database-facts dd"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            self.assertGreaterEqual(self.font_px(".database-issue"), 11)
            # An engine chip never covers its host's name, however long the name is.
            covered = self.page.evaluate("""() => [...document.querySelectorAll('.database-host')].filter((row) => {
                const chip = row.querySelector('.database-engine');
                if (!chip) return false;
                const a = row.querySelector('.database-host-name').getBoundingClientRect(), b = chip.getBoundingClientRect();
                return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
            }).map((row) => row.dataset.vmid)""")
            self.assertEqual(covered, [], f"an engine chip covers a name at {width}px")
            self.assertTrue(self.page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"),
                            f"Operations overflows at {width}px")
            overflow = self.page.evaluate("""() => [...document.querySelectorAll('.database-host')]
                .some((row) => row.scrollWidth > row.clientWidth + 1)""")
            self.assertFalse(overflow, f"a database host overflows at {width}px")
            # A measured disk value stays on one line; no number or unit is ever split.
            lines = self.page.evaluate("""() => {
                const value = document.querySelector('.database-host[data-vmid="102"] [data-fact="disk"]');
                return Math.round(value.getBoundingClientRect().height / (parseFloat(getComputedStyle(value).fontSize) * 1.6));
            }""")
            self.assertEqual(lines, 1, f"a disk value wraps at {width}px")
            split = self.page.evaluate("""() => [...document.querySelectorAll('.database-fact-value')]
                .filter((value) => value.getClientRects().length > 1).map((value) => value.textContent)""")
            self.assertEqual(split, [], f"a fact value breaks inside itself at {width}px")
            # Every host states its facts in the same order.
            orders = section.locator(".database-host").evaluate_all(
                "rows => rows.map((row) => [...row.querySelectorAll('.database-facts dt')].map((term) => term.textContent).join('|'))")
            self.assertEqual(set(orders), {"Memory|Disk|Backup"})
        self.assert_safe()

    def test_backups_show_each_guests_newest_backup_and_what_is_overdue(self):
        self.open_operations()
        section = self.page.locator(".proxmox-backups")
        expect(section.get_by_role("heading", name="Backups", exact=True)).to_be_visible()
        expect(section.locator(".backup-summary")).to_have_text(
            "3 guests: 1 up to date · 1 overdue · 1 never backed up · 1 backup job")
        rows = section.locator(".backup-guest")
        expect(rows).to_have_count(3)
        self.assertEqual(rows.evaluate_all("rows => rows.map((row) => row.dataset.vmid)"), ["990", "102", "101"])
        self.assertEqual(rows.evaluate_all("rows => rows.map((row) => row.dataset.attention)"),
                         ["blocking", "warning", "none"])
        lab = section.locator('.backup-guest[data-vmid="990"]')
        expect(lab.locator('[data-fact="latest"]')).to_have_text("Never")
        expect(lab.locator(".backup-issue")).to_have_text(["Never backed up", "No backup job"])
        cache = section.locator('.backup-guest[data-vmid="102"]')
        expect(cache.locator('[data-fact="latest"]')).to_have_text("12 days ago")
        expect(cache.locator(".backup-issue")).to_have_text(["Overdue: older than 8 days"])
        orders = section.locator('.backup-guest[data-vmid="101"]')
        expect(orders.locator('[data-fact="latest"]')).to_have_text("Today")
        expect(orders.locator('[data-fact="copy"]')).to_have_text("2.0 GiB on pbs, encrypted, verified ok")
        # Every card keeps its facts in the same places; the long copy line comes last.
        self.assertEqual(orders.locator("dt").all_text_contents(), ["Newest backup", "Backup job", "Newest copy"])
        self.assertEqual(lab.locator("dt").all_text_contents(), ["Newest backup", "Backup job"])
        expect(section.get_by_role("button")).to_have_count(0)
        self.assertEqual(self.health_requests, ["GET"])
        self.assert_safe()

    def test_physical_disks_name_a_failing_disk_and_a_node_that_could_not_be_read(self):
        self.open_operations()
        section = self.page.locator(".proxmox-disks")
        expect(section.get_by_role("heading", name="Physical disks", exact=True)).to_be_visible()
        failing = section.locator('.physical-disk[data-device="/dev/sda"]')
        expect(failing).to_have_attribute("data-attention", "blocking")
        expect(failing.locator('[data-fact="health"]')).to_have_text("SMART failed")
        expect(failing.locator(".disk-issue")).to_have_text(["Failing: replace it"])
        expect(failing.locator('[data-fact="wear"]')).to_have_text("Not reported")
        expect(failing.locator('[data-fact="usage"]')).to_have_text("ZFS")
        nvme = section.locator('.physical-disk[data-device="/dev/nvme0n1"]')
        expect(nvme.locator('[data-fact="wear"]')).to_have_text("12% of rated life used")
        expect(nvme.locator(".disk-issue")).to_have_count(0)
        # The failing disk first, then the node whose disks could not be read (marked, not hidden), then the rest.
        self.assertEqual(section.locator(".physical-disk-list > li").evaluate_all(
            "rows => rows.map((row) => row.dataset.device || row.dataset.node)"), ["/dev/sda", "pve-b", "/dev/nvme0n1"])
        unreadable = section.locator('.disk-node-unavailable[data-node="pve-b"]')
        expect(unreadable).to_have_attribute("data-attention", "warning")
        expect(unreadable.locator(".physical-disk-name")).to_have_text("pve-b")
        expect(unreadable.locator(".disk-issue")).to_have_text(["Disks unknown"])
        expect(unreadable.locator(".operation-note")).to_have_text(
            "Disks could not be read: Proxmox refused the read (HTTP 403).")
        self.assert_safe()

    def test_a_guest_that_missed_its_scheduled_run_is_a_warning_with_its_rule(self):
        body = proxmox_health()
        data = body["backups"]["data"]
        data["guests"][1] = backup_guest(102, "cache", ("missed_run",), age=2.0, last_scheduled_run=1794810000)
        data["summary"] = {"guests": 3, "with_recent_backup": 1, "stale": 0, "missed_run": 1, "never": 1,
                           "without_backup_job": 1}
        data["missed_run_grace_hours"] = 12
        self.health_body = body
        self.open_operations()
        section = self.page.locator(".proxmox-backups")
        expect(section.locator(".backup-summary")).to_have_text(
            "3 guests: 1 up to date · 1 missed a scheduled run · 0 overdue · 1 never backed up · 1 backup job")
        cache = section.locator('.backup-guest[data-vmid="102"]')
        expect(cache.locator(".backup-issue")).to_have_text(["Missed its last scheduled run"])
        self.assertEqual(cache.get_attribute("data-attention"), "warning")
        expect(cache.locator('.backup-issue[data-issue="missed_run"]')).to_have_attribute("data-blocking", "false")
        # On a phone the summary wraps between phrases, never inside one ("1" / "never backed up").
        self.page.set_viewport_size({"width": 390, "height": 844})
        expect(section.locator(".backup-summary .summary-part")).to_have_text(
            ["3 guests:", "1 up to date", "1 missed a scheduled run", "0 overdue", "1 never backed up", "1 backup job"])
        self.assertEqual(self.page.evaluate(SPLIT_PHRASES, ".backup-summary"), [])
        self.assert_safe()

    def test_an_unreadable_backup_storage_says_backups_cannot_be_confirmed(self):
        body = proxmox_health()
        data = body["backups"]["data"]
        data.update(listing_complete=False, unreadable_storages=[
            {"node": "pve-a", "storage": "nas", "reason": "Proxmox refused the read (HTTP 403)."}],
            summary={"guests": 3, "with_recent_backup": 1, "stale": 0, "never": 0, "without_backup_job": 1})
        for guest in data["guests"]:
            guest["issues"] = [issue for issue in guest["issues"] if issue == "no_backup_job"]
        self.health_body = body
        self.open_operations()
        section = self.page.locator(".proxmox-backups")
        expect(section.locator(".backup-incomplete")).to_contain_text(
            "nas on pve-a: Proxmox refused the read (HTTP 403).")
        expect(section.locator(".backup-incomplete")).to_contain_text("cannot be confirmed")
        expect(section.locator('.backup-issue[data-issue="never_backed_up"]')).to_have_count(0)
        self.assert_safe()

    def test_backups_and_disks_refresh_less_often_and_only_while_on_screen(self):
        self.page.clock.install()
        self.open_operations()
        self.page.locator(".proxmox-backups .backup-guest").first.wait_for()
        self.assertEqual(self.health_requests, ["GET"])
        self.page.clock.run_for(30_500)
        self.page.wait_for_timeout(200)
        self.assertEqual(self.health_requests, ["GET"], "backups and disks re-read sooner than every minute")
        self.page.clock.run_for(30_000)
        self.wait_for_count(self.health_requests, 2)
        seen = len(self.health_requests)
        self.set_visibility("hidden")
        self.page.clock.run_for(180_000)
        self.page.wait_for_timeout(200)
        self.assertEqual(len(self.health_requests), seen, "a hidden page kept reading backups and disks")
        self.assert_safe()

    def test_an_unavailable_health_read_never_shows_empty_backups(self):
        self.health_status = 503
        self.health_body = {"error": "proxmox_read_failed", "reason": "provider_timeout",
                            "message": "Proxmox VE did not answer in time."}
        self.open_operations()
        failure = self.page.locator(".proxmox-health-unavailable")
        expect(failure).to_contain_text("Backups and disks could not be read")
        expect(failure).to_contain_text("did not answer in time")
        # It says how it recovers and what it does not affect.
        expect(failure).to_contain_text("read again every minute while this page is open")
        expect(failure).to_contain_text("The guest inventory is unaffected.")
        expect(self.page.locator(".backup-guest, .physical-disk")).to_have_count(0)
        self.assert_safe()

    def test_a_failing_disk_on_any_node_comes_before_healthy_disks_on_every_node(self):
        body = proxmox_health()
        first, second = body["disks"]
        failing, healthy = first["result"]["data"]["disks"]
        first["result"]["data"].update(disks=[healthy], count=1)
        second["result"] = {"ok": True, "status": "success", "provider": "proxmox",
                            "observed_at": "2026-11-16T08:00:00Z",
                            "data": {"node": "pve-b", "count": 1, "truncated": False,
                                     "summary": {"disks": 1, "failing": 1, "worn": 0, "health_unknown": 0},
                                     "disks": [failing]}}
        self.health_body = body
        self.open_operations()
        rows = self.page.locator(".proxmox-disks .physical-disk-list > li")
        rows.first.wait_for()
        self.assertEqual(rows.evaluate_all("rows => rows.map((row) => row.dataset.node + ' ' + row.dataset.device)"),
                         ["pve-b /dev/sda", "pve-a /dev/nvme0n1"])
        self.assert_safe()

    def test_the_dashboard_refresh_also_rereads_backups_and_disks(self):
        self.open_operations()
        self.page.locator(".proxmox-backups .backup-guest").first.wait_for()
        self.assertEqual(self.health_requests, ["GET"])
        self.page.locator(".proxmox-dashboard").get_by_role("button", name="Refresh Proxmox dashboard",
                                                            exact=True).click()
        self.wait_for_count(self.health_requests, 2)
        self.assert_safe()

    def test_backups_and_disks_are_legible_at_both_widths(self):
        for width, height in ((1440, 900), (390, 760)):
            self.page.set_viewport_size({"width": width, "height": height})
            self.open_operations()
            self.page.locator(".proxmox-backups .backup-guest").first.wait_for()
            for selector in (".backup-guest-name", ".backup-guest .operation-note", ".backup-issue",
                             ".backup-summary", ".physical-disk-name", ".disk-issue", ".backup-facts dd",
                             ".disk-facts dd", ".backup-facts dt", ".disk-facts dt",
                             ".disk-node-unavailable .operation-note"):
                with self.subTest(width=width, selector=selector):
                    self.assertGreaterEqual(self.page.evaluate(CONTRAST, selector), 4.5)
            self.assertTrue(self.page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"),
                            f"Operations overflows at {width}px")
            overflow = self.page.evaluate("""() => [...document.querySelectorAll('.backup-guest, .physical-disk')]
                .filter((row) => row.scrollWidth > row.clientWidth + 1).map((row) => row.className)""")
            self.assertEqual(overflow, [], f"a card overflows at {width}px")
            split = self.page.evaluate("""() => [...document.querySelectorAll('.backup-facts dd, .disk-facts dd')]
                .filter((value) => {
                    const lines = Math.round(value.getBoundingClientRect().height / (parseFloat(getComputedStyle(value).fontSize) * 1.6));
                    return lines > 2;
                }).map((value) => value.textContent)""")
            self.assertEqual(split, [], f"a fact is squeezed into many lines at {width}px")
            # The newest copy fits one line on a desktop; on a phone it may wrap, but only at a comma,
            # never inside a size or "verified ok".
            lines = self.page.evaluate(LINES_OF, '[data-fact="copy"]')
            if width >= 1024:
                self.assertEqual(lines, [1, 1], f"a backup copy line wraps at {width}px")
            split = self.page.evaluate(SPLIT_UNITS, ["2.0 GiB", "verified ok"])
            self.assertEqual(split, [], f"a backup copy breaks inside a fact at {width}px")
            # A section heading and its count each keep to one line; the count goes below when the row is narrow.
            self.assertEqual(self.page.evaluate(LINES_OF, ".proxmox-health .section-heading-row h4"), [1, 1],
                             f"a section heading wraps at {width}px")
            self.assertEqual(self.page.evaluate(LINES_OF, ".proxmox-health .section-heading-row span"), [1, 1],
                             f"a section count wraps at {width}px")
        self.assert_safe()

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
