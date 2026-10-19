import std/[
  asyncjs,
  jsfetch,
  jsheaders,
  json
]

from std/httpcore import
  HttpDelete,
  HttpGet,
  HttpPost

import ../config/runtime_config
import chat_history
import http_call
export chat_history, http_call


type
  AuthUser* = object
    userId*: string
    email*: string
    displayName*: string
    role*: string
    status*: string

  AuthResponse* = object
    user*: AuthUser
    sessionId*: string
    expiresAt*: string
    csrfToken*: string

  ChatSummary* = object
    chatId*: string
    title*: string
    createdAt*: string
    updatedAt*: string

  SessionSummary* = object
    sessionId*: string
    createdAt*: string
    lastSeenAt*: string
    expiresAt*: string
    revokedAt*: string
    userAgent*: string
    current*: bool


proc jsonText(
  node: JsonNode,
  key: string
): string =
  if node.kind != JObject or not node.hasKey(key):
    return ""

  let value = node[key]

  case value.kind
  of JString:
    return value.getStr()
  of JNull:
    return ""
  else:
    return $value


proc jsonBool(
  node: JsonNode,
  key: string
): bool =
  if node.kind != JObject or not node.hasKey(key):
    return false

  let value = node[key]

  if value.kind == JBool:
    return value.getBool()

  return false


proc parseUser(
  node: JsonNode
): AuthUser =
  AuthUser(
    userId: jsonText(node, "user_id"),
    email: jsonText(node, "email"),
    displayName: jsonText(node, "display_name"),
    role: jsonText(node, "role"),
    status: jsonText(node, "status")
  )


proc parseAuthResponse(
  data: JsonNode
): AuthResponse =
  if data.kind != JObject or not data.hasKey("user"):
    raise newException(ValueError, "Backend auth response is invalid.")

  AuthResponse(
    user: parseUser(data["user"]),
    sessionId: jsonText(data, "session_id"),
    expiresAt: jsonText(data, "expires_at"),
    csrfToken: jsonText(data, "csrf_token")
  )


proc jsonHeaders(
  csrfToken: string = ""
): auto =
  result = newHeaders()
  result["Content-Type"] = "application/json"

  if csrfToken.len > 0:
    result["X-CSRF-Token"] = csrfToken


proc apiError(
  responseStatus: string,
  responseBody: string
): ref ValueError =
  var
    code = "request_failed"
    message = "The request could not be completed."

  try:
    let data = decodeJson(responseBody)

    let parsedCode =
      jsonText(
        data,
        "error"
      )

    let parsedMessage =
      jsonText(
        data,
        "message"
      )

    if parsedCode.len > 0:
      code = parsedCode

    if parsedMessage.len > 0:
      message = parsedMessage

  except CatchableError:
    discard

  newException(
    ValueError,
    "HTTP " & responseStatus &
    " · " & code &
    " · " & message
  )


proc login*(
  email: string,
  password: string
): Future[AuthResponse] {.async.} =
  let payload = %*{
    "email": email,
    "password": password
  }

  let options = newFetchOptions(
    metod = HttpPost,
    body = ($payload).cstring,
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders()
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/login",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)

  result = parseAuthResponse(decodeJson(response.body))


proc me*(): Future[AuthResponse] {.async.} =
  let options = newFetchOptions(
    metod = HttpGet,
    mode = fmCors,
    credentials = fcInclude
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/me",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)

  result = parseAuthResponse(decodeJson(response.body))


proc register*(
  displayName: string,
  email: string,
  password: string
): Future[void] {.async.} =
  let payload = %*{
    "display_name": displayName,
    "email": email,
    "password": password
  }

  let options = newFetchOptions(
    metod = HttpPost,
    body = ($payload).cstring,
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders()
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/register",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)


proc verifyEmail*(
  token: string
): Future[void] {.async.} =
  let payload = %*{
    "token": token
  }

  let options = newFetchOptions(
    metod = HttpPost,
    body = ($payload).cstring,
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders()
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/verify-email",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)


proc resendVerification*(
  email: string
): Future[void] {.async.} =
  let payload = %*{
    "email": email
  }

  let options = newFetchOptions(
    metod = HttpPost,
    body = ($payload).cstring,
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders()
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/resend-verification",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)


proc forgotPassword*(
  email: string
): Future[void] {.async.} =
  let payload = %*{
    "email": email
  }

  let options = newFetchOptions(
    metod = HttpPost,
    body = ($payload).cstring,
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders()
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/forgot-password",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)


proc resetPassword*(
  token: string,
  newPassword: string
): Future[void] {.async.} =
  let payload = %*{
    "token": token,
    "new_password": newPassword
  }

  let options = newFetchOptions(
    metod = HttpPost,
    body = ($payload).cstring,
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders()
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/reset-password",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)


proc logout*(
  csrfToken: string
): Future[LogoutOutcome] {.async.} =
  let options = newFetchOptions(
    metod = HttpPost,
    body = cstring"{}",
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders(csrfToken)
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/logout",
    options
  )

  result = logoutOutcome(response.status)


proc listChats*(): Future[seq[ChatSummary]] {.async.} =
  let options = newFetchOptions(
    metod = HttpGet,
    mode = fmCors,
    credentials = fcInclude
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/chats",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)

  let data = decodeJson(response.body)
  var items = newSeq[ChatSummary]()

  if data.kind == JObject and data.hasKey("chats") and data["chats"].kind == JArray:
    for node in data["chats"].items:
      items.add(
        ChatSummary(
          chatId: jsonText(node, "chat_id"),
          title: jsonText(node, "title"),
          createdAt: jsonText(node, "created_at"),
          updatedAt: jsonText(node, "updated_at")
        )
      )

  return items


proc createChat*(
  csrfToken: string,
  title: string = "New chat"
): Future[ChatSummary] {.async.} =
  let payload = %*{
    "title": title
  }

  let options = newFetchOptions(
    metod = HttpPost,
    body = ($payload).cstring,
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders(csrfToken)
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/chats",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)

  let data = decodeJson(response.body)

  if data.kind != JObject or not data.hasKey("chat"):
    raise newException(ValueError, "Backend chat response is invalid.")

  let node = data["chat"]

  result = ChatSummary(
    chatId: jsonText(node, "chat_id"),
    title: jsonText(node, "title"),
    createdAt: jsonText(node, "created_at"),
    updatedAt: jsonText(node, "updated_at")
  )



proc deleteChat*(
  chatId: string,
  csrfToken: string
): Future[void] {.async.} =
  if chatId.len == 0:
    raise newException(
      ValueError,
      "A chat ID is required."
    )

  let options =
    newFetchOptions(
      metod = HttpDelete,
      mode = fmCors,
      credentials = fcInclude,
      headers = jsonHeaders(
        csrfToken
      )
    )

  let response =
    await sendRequest(
      frontendConfig.backendBaseUrl &
      "/api/v1/chats/" &
      chatId,
      options
    )

  if not response.ok:
    raise apiError(
      $response.status,
      response.body
    )


proc getChatHistory*(
  chatId: string
): Future[seq[ChatHistoryMessage]] {.async.} =
  let options = newFetchOptions(
    metod = HttpGet,
    mode = fmCors,
    credentials = fcInclude
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl &
    "/api/v2/chats/" & chatId & "/history?limit=200",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)

  let data = decodeJson(response.body)
  var items = newSeq[ChatHistoryMessage]()

  if data.kind == JObject and data.hasKey("messages") and data["messages"].kind == JArray:
    for node in data["messages"].items:
      items.add(
        ChatHistoryMessage(
          role: jsonText(node, "role"),
          content: jsonText(node, "content"),
          jobId: jsonText(node, "job_id"),
          status: jsonText(node, "status")
        )
      )

  return items


proc listSessions*(): Future[seq[SessionSummary]] {.async.} =
  let options = newFetchOptions(
    metod = HttpGet,
    mode = fmCors,
    credentials = fcInclude
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/sessions",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)

  let data = decodeJson(response.body)
  var items = newSeq[SessionSummary]()

  if data.kind == JObject and data.hasKey("sessions") and data["sessions"].kind == JArray:
    for node in data["sessions"].items:
      items.add(
        SessionSummary(
          sessionId: jsonText(node, "session_id"),
          createdAt: jsonText(node, "created_at"),
          lastSeenAt: jsonText(node, "last_seen_at"),
          expiresAt: jsonText(node, "expires_at"),
          revokedAt: jsonText(node, "revoked_at"),
          userAgent: jsonText(node, "user_agent"),
          current: jsonBool(node, "current")
        )
      )

  return items


proc revokeSession*(
  csrfToken: string,
  sessionId: string
): Future[void] {.async.} =
  let options = newFetchOptions(
    metod = HttpPost,
    body = cstring"{}",
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders(csrfToken)
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl &
    "/api/v1/auth/sessions/" & sessionId & "/revoke",
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)
