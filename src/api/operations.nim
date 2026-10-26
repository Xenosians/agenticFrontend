import std/[asyncjs, jsfetch]
from std/httpcore import HttpGet
import ../config/runtime_config
import ../app/operations_snapshot
import http_call

proc fetchOperations*(): Future[OperationsSnapshot] {.async.} =
  var response: HttpReply
  try:
    response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/operations",
      newFetchOptions(metod = HttpGet, mode = fmCors, credentials = fcInclude))
  except CatchableError:
    raise newException(ValueError, "Operations could not be reached. Check the connection, then refresh.")
  if not response.ok:
    raise newException(ValueError, "Operations could not be loaded (HTTP " & $response.status & ").")
  try:
    result = parseOperationsSnapshot(decodeJson(response.body))
  except CatchableError:
    raise newException(ValueError, "The operations response was invalid. Refresh to check again.")
