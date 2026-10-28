import std/[asyncjs, jsfetch, jsheaders, json]
from std/httpcore import HttpGet, HttpPost
import ../config/runtime_config
import http_call

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
  if not response.ok: raise newException(ValueError, learningError(response.body, response.status))
  return decodeJson(response.body)

proc checkLearningReadiness*(payload: JsonNode, csrf: string): Future[JsonNode] {.async.} =
  let headers = newHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-CSRF-Token"] = csrf
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/learning/preflight",
    newFetchOptions(metod = HttpPost, credentials = fcInclude, mode = fmCors, headers = headers, body = cstring($payload)))
  if not response.ok: raise newException(ValueError, learningError(response.body, response.status))
  return decodeJson(response.body)
