## Backend calls for Proxmox power actions started from the dashboard.
##
## A proposal only prepares the action; the owner's confirmation decides it.
## Every write carries the session's CSRF token, and a refused request keeps
## the server's own fixed reason so the dashboard can say why.
import std/[asyncjs, jsfetch, jsheaders, json, uri]
from std/httpcore import HttpGet, HttpPost
import ../config/runtime_config
import ../app/proxmox_actions
import http_call

type
  ProxmoxActionRefused* = object of ValueError
    ## The backend answered and refused; nothing was proposed or decided.

proc refusal(reply: HttpReply, fallback: string): ref ValueError =
  var message = fallback
  try:
    let body = decodeJson(reply.body)
    let text = body{"message"}
    if text != nil and text.kind == JString and text.getStr.len > 0 and text.getStr.len <= 300:
      message = text.getStr
  except CatchableError:
    discard
  if reply.status >= 400 and reply.status < 500 and reply.status != 408:
    return newException(ProxmoxActionRefused, message)
  newException(ValueError, message & " (HTTP " & $reply.status & ")")

proc writeOptions(csrfToken: string, body: JsonNode): FetchOptions =
  let headers = newHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-CSRF-Token"] = csrfToken
  newFetchOptions(metod = HttpPost, body = cstring($body), mode = fmCors,
                  credentials = fcInclude, headers = headers)

proc fetchProxmoxActions*(): Future[seq[ProxmoxAction]] {.async.} =
  let reply = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/proxmox/actions",
    newFetchOptions(metod = HttpGet, mode = fmCors, credentials = fcInclude))
  if not reply.ok:
    raise refusal(reply, "Recent Proxmox actions could not be loaded.")
  return parseProxmoxActions(decodeJson(reply.body))

proc proposeProxmoxAction*(csrfToken, node: string, vmid: int,
                           action, submissionId: string): Future[ProxmoxAction] {.async.} =
  let payload = proxmoxActionPayload(node, vmid, action, submissionId)
  let reply = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/proxmox/actions",
    writeOptions(csrfToken, payload))
  if not reply.ok:
    raise refusal(reply, "The action could not be prepared.")
  let proposed = parseProxmoxAction(decodeJson(reply.body))
  if proposed.node != node or proposed.vmid != vmid or proposed.action != action:
    raise newException(ValueError, "The prepared action did not match the chosen guest.")
  return proposed

proc decideProxmoxAction*(csrfToken, actionId: string, approve: bool): Future[ProxmoxAction] {.async.} =
  let decision = if approve: "approve" else: "reject"
  let path = "/api/v1/proxmox/actions/" & encodeUrl(actionId, usePlus = false) & "/" & decision
  let reply = await sendRequest(frontendConfig.backendBaseUrl & path, writeOptions(csrfToken, newJObject()))
  if not reply.ok:
    raise refusal(reply, "The decision was not recorded.")
  let decided = parseProxmoxAction(decodeJson(reply.body))
  if decided.actionId != actionId:
    raise newException(ValueError, "The decision answer named another action.")
  return decided
