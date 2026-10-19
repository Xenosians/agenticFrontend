## One place where browser network and JSON failures become Nim errors.
##
## On the JavaScript backend a rejected fetch or an invalid JSON body raises a
## native JavaScript value. Native values are not CatchableError, so callers'
## `except CatchableError` handlers would never see a lost connection.

import std/[asyncjs, jsfetch, json]

type
  BackendUnreachable* = object of IOError
    ## No HTTP response was received. A request that changes state may or may
    ## not have reached the server.

  HttpReply* = object
    ok*: bool
    status*: int
    body*: string

  LogoutOutcome* = enum
    loSignedOut,       ## the server ended this session
    loAlreadyEnded,    ## the server no longer recognises the session (401)
    loUnconfirmed      ## no confirmation; the session may still be active


proc logoutOutcome*(status: int): LogoutOutcome =
  ## Only the server can end a session. 2xx confirms it; 401 means the
  ## session is already gone. Everything else, including 403 (rejected
  ## CSRF) and 503 (revocation not confirmed), leaves it possibly active.
  if status >= 200 and status < 300: loSignedOut
  elif status == 401: loAlreadyEnded
  else: loUnconfirmed


proc sendRequest*(url: string, options: FetchOptions): Future[HttpReply] {.async.} =
  try:
    let response = await fetch(url.cstring, options)
    let body = $(await response.text())
    result = HttpReply(ok: response.ok, status: response.status, body: body)
  except CatchableError, Defect:
    raise
  except:
    # A rejected fetch or an interrupted body read. A JavaScript value may
    # be thrown from another realm, so `except JsError` (instanceof Error)
    # could miss it; everything that is not a Nim exception lands here.
    raise newException(BackendUnreachable,
      "The backend could not be reached. " & getCurrentExceptionMsg())


proc decodeJson*(body: string): JsonNode =
  try:
    result = parseJson(body)
  except CatchableError, Defect:
    raise
  except:
    raise newException(ValueError, "The backend returned an unreadable response.")
