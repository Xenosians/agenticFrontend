## Each account's own Proxmox and Tailscale link (owner decision, 17 November: "user
## dependant not machine dependant"). The catalog lists the signed-in account's links
## without their secrets; the AI service stores a saved link encrypted for this account
## and uses it for the account's chat, tools and dashboards. An account without a link
## uses the machine's default, when the machine has one.

import std/[json, strutils]

type
  ServerLink* = object
    kind*: string        ## "proxmox" or "tailscale"; "" when the account has none
    host*: string        ## the Proxmox host name; "" for Tailscale
    identity*: string    ## the Proxmox API token id or the Tailscale OAuth client id
    verifyTls*: bool
    serverName*: string  ## the Proxmox certificate name when it differs from the host

proc text(node: JsonNode, key: string): string =
  if node.hasKey(key) and node[key].kind == JString: node[key].getStr else: ""

proc serverLinks*(catalog: JsonNode): seq[ServerLink] =
  ## The account's links as the catalog lists them; malformed entries are ignored.
  if catalog == nil or catalog.kind != JObject or not catalog.hasKey("links") or
      catalog["links"].kind != JArray:
    return
  for row in catalog["links"]:
    if row.kind != JObject: continue
    case row.text("kind")
    of "proxmox":
      if row.text("host").len == 0 or row.text("token_id").len == 0: continue
      let verify = not (row.hasKey("verify_tls") and row["verify_tls"].kind == JBool) or row["verify_tls"].getBool
      result.add ServerLink(kind: "proxmox", host: row.text("host"), identity: row.text("token_id"),
                            verifyTls: verify, serverName: row.text("server_name"))
    of "tailscale":
      if row.text("client_id").len == 0: continue
      result.add ServerLink(kind: "tailscale", identity: row.text("client_id"), verifyTls: true)
    else: discard

proc linkOf*(links: seq[ServerLink], kind: string): ServerLink =
  ## The account's link of one kind, or an empty one.
  for link in links:
    if link.kind == kind: return link

proc proxmoxLinkPayload*(url, tokenId, secret: string, verifyTls: bool, serverName: string): JsonNode =
  ## An empty secret keeps the stored one; the AI service refuses it for a new link.
  %*{"kind": "proxmox", "link": {"url": url.strip().strip(leading = false, chars = {'/'}),
     "token_id": tokenId.strip(), "token_secret": secret, "verify_tls": verifyTls,
     "server_name": serverName.strip()}}

proc tailscaleLinkPayload*(clientId, secret: string): JsonNode =
  %*{"kind": "tailscale", "link": {"client_id": clientId.strip(), "client_secret": secret}}

proc proxmoxLinkReady*(url, tokenId, secret: string, existing: bool): bool =
  url.strip().len > 0 and tokenId.strip().len > 0 and (existing or secret.len > 0)

proc tailscaleLinkReady*(clientId, secret: string, existing: bool): bool =
  clientId.strip().len > 0 and (existing or secret.len > 0)
