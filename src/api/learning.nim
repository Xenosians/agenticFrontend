import std/[asyncjs, jsfetch, jsheaders, json]
from std/httpcore import HttpGet, HttpPost
import ../config/runtime_config
import http_call

type LearningRequestError* = object of ValueError
  status*: int
  code*: string

proc learningError(body: string, status: int): string

proc requestError(body: string, status: int): ref LearningRequestError =
  result = newException(LearningRequestError, learningError(body, status))
  result.status = status
  try:
    let data = decodeJson(body)
    if data.kind == JObject and data.hasKey("error") and data["error"].kind == JString:
      result.code = data["error"].getStr
  except CatchableError: discard

proc learningError(body: string, status: int): string =
  try:
    let data = decodeJson(body)
    if data.kind == JObject and data.hasKey("error") and data["error"].kind == JString:
      return "Learning request rejected (" & data["error"].getStr & "). Refresh your inputs and try again."
  except CatchableError: discard
  "Learning could not be reached (HTTP " & $status & "). Refresh to check again."

proc fetchLearningCatalog*(): Future[JsonNode] {.async.} =
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/learning",
    newFetchOptions(metod = HttpGet, credentials = fcInclude, mode = fmCors))
  if not response.ok: raise requestError(response.body, response.status)
  return decodeJson(response.body)

proc checkLearningReadiness*(payload: JsonNode, csrf: string): Future[JsonNode] {.async.} =
  let headers = newHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-CSRF-Token"] = csrf
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/learning/preflight",
    newFetchOptions(metod = HttpPost, credentials = fcInclude, mode = fmCors, headers = headers, body = cstring($payload)))
  if not response.ok: raise requestError(response.body, response.status)
  return decodeJson(response.body)

proc fetchLearningRuns*(): Future[JsonNode] {.async.} =
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/learning/runs",
    newFetchOptions(metod = HttpGet, credentials = fcInclude, mode = fmCors))
  if not response.ok: raise requestError(response.body, response.status)
  return decodeJson(response.body)

proc postLearning(path: string, payload: JsonNode, csrf: string): Future[JsonNode] {.async.} =
  let headers = newHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-CSRF-Token"] = csrf
  let response = await sendRequest(frontendConfig.backendBaseUrl & path,
    newFetchOptions(metod = HttpPost, credentials = fcInclude, mode = fmCors, headers = headers, body = cstring($payload)))
  if not response.ok: raise requestError(response.body, response.status)
  return decodeJson(response.body)

proc startLearningRun*(payload: JsonNode, csrf: string): Future[JsonNode] =
  postLearning("/api/v1/learning/runs", payload, csrf)

proc cancelLearningRun*(runId, csrf: string): Future[JsonNode] =
  postLearning("/api/v1/learning/runs/" & runId & "/cancel", newJObject(), csrf)

proc resolveLearningRun*(submissionId: string): Future[JsonNode] {.async.} =
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/learning/runs/resolve?submission_id=" & submissionId,
    newFetchOptions(metod = HttpGet, credentials = fcInclude, mode = fmCors))
  if not response.ok: raise requestError(response.body, response.status)
  return decodeJson(response.body)
