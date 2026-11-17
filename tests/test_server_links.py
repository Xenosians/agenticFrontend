"""Each account connects its own Proxmox and Tailscale in Plugins > Servers (owner decision, 17 November).

"because this is an agnostic program or user dependant not machine dependant":
the connection belongs to the signed-in account. The tab lists the account's
links without their secrets, saves a link through the AI service (which keeps
the secret encrypted for this account) and removes it, returning the account to
the machine's default. Isolated HTTP fixtures only.
Run after rebuilding: python tests/test_server_links.py
"""
import copy
import os
import unittest
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation
from test_workspace_context import CATALOG

PROXMOX_ROW = {"kind": "proxmox", "host": "pve.example.test", "token_id": "janus@pve!dashboard",
               "verify_tls": True, "server_name": None, "credential_configured": True}


class ServerLinkTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.catalog = copy.deepcopy(CATALOG)
        self.catalog["links"] = []
        self.mutations = []
        self.reply = None
        super().setUp()
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        bundle = os.getenv("SUITE_TEST_BUNDLE")
        if bundle and request.url.startswith(self.base + "/") and path == "/js/app.js":
            route.fulfill(content_type="application/javascript", headers=navigation.SECURITY_HEADERS,
                          body=Path(bundle).read_text())
            return
        if path == "/api/v1/extensions" and request.url.startswith(self.base + "/api/"):
            if request.method == "GET":
                route.fulfill(json=self.catalog)
                return
            body = request.post_data_json
            self.mutations.append(body)
            if self.reply is not None:
                route.fulfill(status=self.reply[0], json=self.reply[1])
                return
            if body["action"] == "link_save":
                link = body["payload"]["link"]
                row = (dict(PROXMOX_ROW, host=urlparse(link["url"]).hostname, token_id=link["token_id"])
                       if body["payload"]["kind"] == "proxmox"
                       else {"kind": "tailscale", "client_id": link["client_id"], "credential_configured": True})
                self.catalog["links"] = [item for item in self.catalog["links"] if item["kind"] != row["kind"]]
                self.catalog["links"].append(row)
                route.fulfill(json=row)
                return
            if body["action"] == "link_remove":
                self.catalog["links"] = [item for item in self.catalog["links"]
                                         if item["kind"] != body["payload"]["kind"]]
                route.fulfill(json={"kind": body["payload"]["kind"], "removed": True})
                return
        super().route(route)

    def open_servers(self):
        self.open_first_chat()
        self.page.keyboard.press("Control+,")
        self.page.locator(".plugin-tabs").get_by_role("button", name="Servers", exact=True).click()

    def card(self, kind):
        return self.page.locator(f".server-link[data-kind='{kind}']")

    def test_an_account_saves_its_own_proxmox_and_the_secret_never_comes_back(self):
        self.open_servers()
        card = self.card("proxmox")
        expect(card).to_contain_text("Not connected")
        card.get_by_role("textbox", name="Address", exact=True).fill(" https://pve.example.test:8006/ ")
        card.get_by_role("textbox", name="API token", exact=True).fill("janus@pve!dashboard")
        card.get_by_label("Token secret", exact=True).fill("synthetic-secret")
        card.get_by_role("button", name="Save Proxmox link", exact=True).click()
        expect(card).to_contain_text("Connected: pve.example.test as janus@pve!dashboard")
        self.assertEqual(self.mutations, [{"action": "link_save", "payload": {"kind": "proxmox", "link": {
            "url": "https://pve.example.test:8006", "token_id": "janus@pve!dashboard",
            "token_secret": "synthetic-secret", "verify_tls": True, "server_name": ""}}}])
        # The secret field is cleared and the page never shows a stored secret.
        expect(card.get_by_label("Token secret", exact=True)).to_have_value("")
        self.assertNotIn("synthetic-secret", self.page.content())
        self.assertEqual(self.errors, [])

    def test_a_secret_is_required_only_for_a_new_link(self):
        self.open_servers()
        card = self.card("tailscale")
        save = card.get_by_role("button", name="Save Tailscale link", exact=True)
        card.get_by_role("textbox", name="OAuth client ID", exact=True).fill("client-1")
        expect(save).to_be_disabled()
        card.get_by_label("Client secret", exact=True).fill("synthetic-secret")
        expect(save).to_be_enabled()
        save.click()
        expect(card).to_contain_text("Connected as client-1")
        # Changing the client id of a saved link may keep the stored secret.
        card.get_by_role("textbox", name="OAuth client ID", exact=True).fill("client-2")
        expect(save).to_be_enabled()

    def test_a_refused_link_shows_the_reason_and_is_not_listed(self):
        self.reply = (422, {"error": "extension_request_rejected", "detail": {
            "code": "link_url_invalid", "message": "Enter the HTTPS address of the server, without a path."}})
        self.open_servers()
        card = self.card("proxmox")
        card.get_by_role("textbox", name="Address", exact=True).fill("http://pve.example.test")
        card.get_by_role("textbox", name="API token", exact=True).fill("janus@pve!dashboard")
        card.get_by_label("Token secret", exact=True).fill("synthetic-secret")
        card.get_by_role("button", name="Save Proxmox link", exact=True).click()
        expect(self.page.locator(".plugin-notice.error")).to_contain_text(
            "Enter the HTTPS address of the server, without a path. (link_url_invalid)")
        expect(card).to_contain_text("Not connected")

    def test_removing_a_link_returns_the_account_to_the_machine_default(self):
        self.catalog["links"] = [copy.deepcopy(PROXMOX_ROW)]
        self.open_servers()
        card = self.card("proxmox")
        expect(card).to_contain_text("Connected: pve.example.test as janus@pve!dashboard")
        card.get_by_role("button", name="Remove Proxmox link", exact=True).click()
        expect(card).to_contain_text("Not connected")
        self.assertEqual(self.mutations[-1], {"action": "link_remove", "payload": {"kind": "proxmox"}})


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(ServerLinkTests(name) for name in loader.getTestCaseNames(ServerLinkTests)
                             if name in ServerLinkTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
