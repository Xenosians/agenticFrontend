import std/[json, unittest]
import ../src/app/[server_links, types, connection_draft]

suite "server links: each account connects its own Proxmox and Tailscale":
  test "the catalog's links are read without any secret, in kind order":
    let links = serverLinks(%*{"links": [
      {"kind": "proxmox", "host": "pve.example.test", "token_id": "janus@pve!dashboard",
       "verify_tls": true, "server_name": nil, "credential_configured": true},
      {"kind": "tailscale", "client_id": "client-1", "credential_configured": true}]})
    check links.len == 2
    check links[0] == ServerLink(kind: "proxmox", host: "pve.example.test", identity: "janus@pve!dashboard",
                                 verifyTls: true, serverName: "")
    check links[1] == ServerLink(kind: "tailscale", host: "", identity: "client-1", verifyTls: true,
                                 serverName: "")
    check linkOf(links, "tailscale").identity == "client-1"
    check linkOf(links, "openwrt").kind == ""

  test "a catalog without links, or with malformed ones, offers none":
    for catalog in [newJNull(), %*{}, %*{"links": "x"}, %*{"links": [7, {}, {"kind": "openwrt"},
                    {"kind": "proxmox"}, {"kind": "tailscale", "client_id": 3}]}]:
      check serverLinks(catalog).len == 0

  test "a Proxmox link to save carries exactly its fields, trimmed":
    check proxmoxLinkPayload(" https://pve.example.test:8006/ ", " janus@pve!dashboard ", "secret-1", true,
                             " hummingbird.local.pve ") ==
      %*{"kind": "proxmox", "link": {"url": "https://pve.example.test:8006", "token_id": "janus@pve!dashboard",
         "token_secret": "secret-1", "verify_tls": true, "server_name": "hummingbird.local.pve"}}

  test "an empty secret on an existing link keeps the stored one; the server decides":
    check proxmoxLinkPayload("https://pve.example.test", "janus@pve!dashboard", "", false, "") ==
      %*{"kind": "proxmox", "link": {"url": "https://pve.example.test", "token_id": "janus@pve!dashboard",
         "token_secret": "", "verify_tls": false, "server_name": ""}}
    check tailscaleLinkPayload(" client-1 ", "") ==
      %*{"kind": "tailscale", "link": {"client_id": "client-1", "client_secret": ""}}

  test "a link can be saved only with its address and identity, and a secret when it is new":
    check proxmoxLinkReady("https://pve.example.test", "janus@pve!dashboard", "s", existing = false)
    check not proxmoxLinkReady("https://pve.example.test", "janus@pve!dashboard", "", existing = false)
    check proxmoxLinkReady("https://pve.example.test", "janus@pve!dashboard", "", existing = true)
    check not proxmoxLinkReady("", "janus@pve!dashboard", "s", existing = false)
    check not proxmoxLinkReady("https://pve.example.test", "  ", "s", existing = false)
    check tailscaleLinkReady("client-1", "s", existing = false)
    check not tailscaleLinkReady("client-1", "", existing = false)
    check tailscaleLinkReady("client-1", "", existing = true)

  test "signing out clears every typed link field, so no secret reaches another account":
    let state = AppState(proxmoxLinkUrl: "https://pve.example.test", proxmoxLinkTokenId: "janus@pve!x",
      proxmoxLinkSecret: "private", proxmoxLinkServerName: "pve.local", proxmoxLinkVerifyTls: false,
      tailscaleLinkClientId: "client-1", tailscaleLinkSecret: "private")
    state.clearExtensionDrafts()
    check state.proxmoxLinkUrl == "" and state.proxmoxLinkTokenId == "" and state.proxmoxLinkSecret == ""
    check state.proxmoxLinkServerName == "" and state.proxmoxLinkVerifyTls
    check state.tailscaleLinkClientId == "" and state.tailscaleLinkSecret == ""
