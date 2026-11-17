## Plugins > Servers: the signed-in account connects its own Proxmox and Tailscale
## (owner decision, 17 November). Saved links are listed without secrets; the AI
## service stores each secret encrypted for this account and uses the link for the
## account's chat, tools and dashboards. An account without a link uses the
## machine's default, when the machine has one.

include karax/prelude
import ../app/[types, extension_bridge, server_links]

proc linkStatus(link: ServerLink, connected: string): VNode =
  buildHtml(p(class = "server-link-status")):
    if link.kind.len == 0:
      text "Not connected. Janus uses this computer's default link, if it has one."
    else:
      text connected

proc renderProxmoxLink(state: AppState, link: ServerLink): VNode =
  let existing = link.kind.len > 0
  result = buildHtml(section(class = "server-link", `data-kind` = "proxmox")):
    h4: text "Proxmox VE"
    linkStatus(link, "Connected: " & link.host & " as " & link.identity &
      (if link.verifyTls: "" else: " (certificate not verified)"))
    tdiv(class = "plugin-field"):
      label(`for` = "proxmoxLinkUrl"): text "Address"
      input(id = "proxmoxLinkUrl", `type` = "url", placeholder = "https://pve.example.org:8006",
            value = cstring(state.proxmoxLinkUrl), spellcheck = "false", autocomplete = "off"):
        proc oninput(event: Event, node: VNode) = state.proxmoxLinkUrl = $node.value
    tdiv(class = "plugin-field"):
      label(`for` = "proxmoxLinkTokenId"): text "API token"
      input(id = "proxmoxLinkTokenId", `type` = "text", placeholder = "user@realm!token-name",
            value = cstring(state.proxmoxLinkTokenId), spellcheck = "false", autocomplete = "off"):
        proc oninput(event: Event, node: VNode) = state.proxmoxLinkTokenId = $node.value
    tdiv(class = "plugin-field"):
      label(`for` = "proxmoxLinkSecret"): text "Token secret"
      input(id = "proxmoxLinkSecret", `type` = "password", autocomplete = "new-password",
            placeholder = (if existing: "Leave empty to keep the stored secret" else: ""),
            value = cstring(state.proxmoxLinkSecret)):
        proc oninput(event: Event, node: VNode) = state.proxmoxLinkSecret = $node.value
    tdiv(class = "plugin-field"):
      label(`for` = "proxmoxLinkServerName"): text "Certificate name (optional)"
      input(id = "proxmoxLinkServerName", `type` = "text", placeholder = "pve.local",
            value = cstring(state.proxmoxLinkServerName), spellcheck = "false", autocomplete = "off"):
        proc oninput(event: Event, node: VNode) = state.proxmoxLinkServerName = $node.value
    label(class = "server-link-check"):
      input(`type` = "checkbox", checked = state.proxmoxLinkVerifyTls):
        proc onchange(event: Event, node: VNode) = state.proxmoxLinkVerifyTls = not state.proxmoxLinkVerifyTls
      text "Verify the server's certificate"
    tdiv(class = "server-link-actions"):
      button(class = "plugin-primary", disabled = state.extensionBusy or not proxmoxLinkReady(
             state.proxmoxLinkUrl, state.proxmoxLinkTokenId, state.proxmoxLinkSecret, existing)):
        text "Save Proxmox link"
        proc onclick(event: Event, node: VNode) = discard saveProxmoxLink(state)
      if existing:
        button(class = "plugin-secondary", disabled = state.extensionBusy):
          text "Remove Proxmox link"
          proc onclick(event: Event, node: VNode) = discard removeServerLink(state, "proxmox")

proc renderTailscaleLink(state: AppState, link: ServerLink): VNode =
  let existing = link.kind.len > 0
  result = buildHtml(section(class = "server-link", `data-kind` = "tailscale")):
    h4: text "Tailscale"
    linkStatus(link, "Connected as " & link.identity)
    tdiv(class = "plugin-field"):
      label(`for` = "tailscaleLinkClientId"): text "OAuth client ID"
      input(id = "tailscaleLinkClientId", `type` = "text", value = cstring(state.tailscaleLinkClientId),
            spellcheck = "false", autocomplete = "off"):
        proc oninput(event: Event, node: VNode) = state.tailscaleLinkClientId = $node.value
    tdiv(class = "plugin-field"):
      label(`for` = "tailscaleLinkSecret"): text "Client secret"
      input(id = "tailscaleLinkSecret", `type` = "password", autocomplete = "new-password",
            placeholder = (if existing: "Leave empty to keep the stored secret" else: ""),
            value = cstring(state.tailscaleLinkSecret)):
        proc oninput(event: Event, node: VNode) = state.tailscaleLinkSecret = $node.value
    tdiv(class = "server-link-actions"):
      button(class = "plugin-primary", disabled = state.extensionBusy or not tailscaleLinkReady(
             state.tailscaleLinkClientId, state.tailscaleLinkSecret, existing)):
        text "Save Tailscale link"
        proc onclick(event: Event, node: VNode) = discard saveTailscaleLink(state)
      if existing:
        button(class = "plugin-secondary", disabled = state.extensionBusy):
          text "Remove Tailscale link"
          proc onclick(event: Event, node: VNode) = discard removeServerLink(state, "tailscale")

proc renderServerLinks*(state: AppState): VNode =
  let links = serverLinks(state.extensionCatalog)
  result = buildHtml(tdiv(class = "plugin-content-section server-links")):
    tdiv(class = "plugin-section-heading"):
      tdiv:
        h3: text "Servers"
        p: text "Your own Proxmox and Tailscale. Janus stores each secret encrypted for your account " &
          "and uses these links for your chats, tools and dashboards."
    renderProxmoxLink(state, linkOf(links, "proxmox"))
    renderTailscaleLink(state, linkOf(links, "tailscale"))
