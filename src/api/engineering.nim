import std/[asyncjs, jsfetch, jsheaders, json, uri]
from std/httpcore import HttpMethod, HttpGet, HttpPost, HttpPut, HttpDelete
import ../config/runtime_config
import http_call

proc errorCode(body: string): string =
  try:
    let data = decodeJson(body)
    if data.kind == JObject and data.hasKey("error") and data["error"].kind == JString:
      return data["error"].getStr
  except CatchableError: discard

proc engineeringError*(status: int, body: string): string =
  case errorCode(body)
  of "topology_version_conflict": "This topology changed since you opened it. Reload it, then save or check again."
  of "invalid_topology": "The servers refused this topology. Check each node, property and connection."
  of "private_topology_content": "Topologies cannot hold credentials or personal data. Remove them and save again."
  of "topology_not_found": "This topology no longer exists."
  of "invalid_netlist": "This is not a KiCad netlist export. Export one with File → Export → Netlist."
  of "invalid_engineering_request": "The servers refused this request. Review it and try again."
  of "engineering_unavailable": "The check could not be completed. Try again."
  of "csrf_failed": "Your session check expired. Reload the page and try again."
  else: "The engineering request could not be confirmed (HTTP " & $status & "). Reload before trying again."

proc topologyPath(id = "", suffix = ""): string =
  result = frontendConfig.backendBaseUrl & "/api/v1/topologies"
  if id.len > 0: result &= "/" & encodeUrl(id, usePlus = false)
  result &= suffix

proc send(url: string, verb: HttpMethod, csrf = "", payload: JsonNode = nil): Future[JsonNode] {.async.} =
  let headers = newHeaders()
  if payload != nil: headers["Content-Type"] = "application/json"
  if csrf.len > 0: headers["X-CSRF-Token"] = csrf
  let options = if payload == nil:
      newFetchOptions(metod = verb, credentials = fcInclude, mode = fmCors, headers = headers)
    else:
      newFetchOptions(metod = verb, credentials = fcInclude, mode = fmCors, headers = headers,
                      body = cstring($payload))
  let response = await sendRequest(url, options)
  if not response.ok: raise newException(ValueError, engineeringError(response.status, response.body))
  return decodeJson(response.body)

proc listTopologies*(): Future[JsonNode] = send(topologyPath(), HttpGet)
proc getTopology*(id: string): Future[JsonNode] = send(topologyPath(id), HttpGet)

proc saveTopology*(id: string, payload: JsonNode, csrf: string): Future[JsonNode] =
  if id.len == 0: send(topologyPath(), HttpPost, csrf, payload)
  else: send(topologyPath(id), HttpPut, csrf, payload)

proc archiveTopology*(id: string, csrf: string): Future[JsonNode] = send(topologyPath(id), HttpDelete, csrf)

proc checkTopologyDrift*(id: string, payload: JsonNode, csrf: string): Future[JsonNode] =
  send(topologyPath(id, "/drift"), HttpPost, csrf, payload)

proc inspectNetlist*(text: string, csrf: string): Future[JsonNode] =
  send(frontendConfig.backendBaseUrl & "/api/v1/engineering/netlist", HttpPost, csrf, %*{"netlist": text})
