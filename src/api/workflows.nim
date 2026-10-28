import std/[asyncjs, jsfetch, jsheaders, json, uri]
from std/httpcore import HttpMethod, HttpGet, HttpPost, HttpPut, HttpDelete
import ../config/runtime_config
import http_call

type WorkflowReply* = object
  status*: int
  data*: JsonNode

proc errorCode(body: string): string =
  try:
    let data = decodeJson(body)
    if data.kind == JObject and data.hasKey("error") and data["error"].kind == JString:
      return data["error"].getStr
  except CatchableError: discard

proc workflowError*(status: int, body: string): string =
  case errorCode(body)
  of "workflow_version_conflict": "This workflow changed since you opened it. Reload it, then save or run again."
  of "invalid_workflow": "The servers refused this workflow. Check each step's targets and its dependency."
  of "workflow_not_found": "This workflow no longer exists."
  of "submission_conflict": "This run identity already belongs to a different request. Start a new run."
  of "csrf_failed": "Your session check expired. Reload the page and try again."
  else: "The workflow could not be confirmed (HTTP " & $status & "). Reload before trying again."

proc workflowPath(id = "", suffix = ""): string =
  result = frontendConfig.backendBaseUrl & "/api/v1/workflows"
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
  if not response.ok: raise newException(ValueError, workflowError(response.status, response.body))
  return decodeJson(response.body)

proc listWorkflows*(): Future[JsonNode] = send(workflowPath(), HttpGet)
proc getWorkflow*(id: string): Future[JsonNode] = send(workflowPath(id), HttpGet)
proc listWorkflowRuns*(id: string): Future[JsonNode] = send(workflowPath(id, "/runs"), HttpGet)

proc saveWorkflow*(id: string, payload: JsonNode, csrf: string): Future[JsonNode] =
  if id.len == 0: send(workflowPath(), HttpPost, csrf, payload)
  else: send(workflowPath(id), HttpPut, csrf, payload)

proc archiveWorkflow*(id: string, csrf: string): Future[JsonNode] = send(workflowPath(id), HttpDelete, csrf)

proc runWorkflow*(id: string, payload: JsonNode, csrf: string): Future[JsonNode] =
  send(workflowPath(id, "/runs"), HttpPost, csrf, payload)
