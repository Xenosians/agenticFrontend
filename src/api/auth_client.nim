import std/[
  asyncjs,
  jsfetch,
  jsheaders,
  json,
  strutils,
  uri
]

from std/httpcore import
  HttpDelete,
  HttpGet,
  HttpPatch,
  HttpPost

import ../config/runtime_config
import chat_history
import http_call
import ../app/chat_list
import ../app/account_settings
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

  ChatSummary* = ChatItem

  ## A registration waiting for its email to be verified. The server keeps the
  ## step (an HttpOnly cookie names the account) and the wait between emails.
  VerificationStep* = object
    pending*: bool
    verified*: bool
    resendAfterSeconds*: int
    emailHint*: string
    tooSoon*: bool
    mailFailed*: bool

  ## Sign-in reached an account whose email is not verified yet.
  EmailNotVerified* = object of ValueError
    step*: VerificationStep

  ## One saved chat matching a search: by its title, or by a saved turn
  ## (`excerpt` is that turn's text).
  ChatSearchResult* = object
    chatId*: string
    title*: string
    matched*: string
    excerpt*: string

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


proc jsonInt(
  node: JsonNode,
  key: string
): int =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
    return max(node[key].getInt(), 0)


proc parseVerificationStep(
  data: JsonNode
): VerificationStep =
  if data.kind != JObject or not data.hasKey("resend_after_seconds") or
      data["resend_after_seconds"].kind != JInt or data["resend_after_seconds"].getInt < 0 or
      not data.hasKey("email_hint") or data["email_hint"].kind != JString or
      data["email_hint"].getStr.len == 0:
    raise newException(ValueError, "The verification step was not confirmed. Reload to check its current state.")
  VerificationStep(
    resendAfterSeconds: jsonInt(data, "resend_after_seconds"),
    emailHint: jsonText(data, "email_hint")
  )


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


proc jsonHeaders*(
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

  if response.status == 403:
    let data = decodeJson(response.body)
    if jsonText(data, "error") == "email_not_verified":
      var step = parseVerificationStep(data)
      step.pending = true
      let error = newException(EmailNotVerified,
        "This email is not verified yet. Use the link we sent, or send a new one when the wait ends.")
      error.step = step
      raise error

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
): Future[VerificationStep] {.async.} =
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

  let data = decodeJson(response.body)
  if data.kind != JObject or not jsonBool(data, "verification_required") or
      jsonText(data, "mail_delivery") notin ["sent", "failed"] or
      not data.hasKey("user") or data["user"].kind != JObject or
      jsonText(data["user"], "user_id").len == 0 or
      jsonText(data["user"], "email").toLowerAscii() != email.strip().toLowerAscii():
    raise newException(ValueError, "Account creation was not confirmed. Sign in to check the account before registering again.")
  var step = parseVerificationStep(data)
  step.pending = true
  step.mailFailed = jsonText(data, "mail_delivery") == "failed"
  return step


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

  let data = decodeJson(response.body)
  if data.kind != JObject or not jsonBool(data, "verified") or not data.hasKey("user") or
      data["user"].kind != JObject or jsonText(data["user"], "user_id").len == 0:
    raise newException(ValueError, "Email verification was not confirmed. Sign in to check the account.")


proc resendVerification*(): Future[VerificationStep] {.async.} =
  ## The server identifies the pending account by its HttpOnly verification
  ## cookie and decides whether another email may be sent yet.
  let options = newFetchOptions(
    metod = HttpPost,
    body = "{}".cstring,
    mode = fmCors,
    credentials = fcInclude,
    headers = jsonHeaders()
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/resend-verification",
    options
  )

  if response.status == 429:
    let data = decodeJson(response.body)
    if jsonText(data, "error") != "verification_resend_too_soon" or
        not data.hasKey("retry_after_seconds") or data["retry_after_seconds"].kind != JInt or
        data["retry_after_seconds"].getInt < 1:
      raise newException(ValueError, "The resend wait could not be confirmed. Reload to check the verification step.")
    return VerificationStep(pending: true,
      resendAfterSeconds: max(jsonInt(data, "retry_after_seconds"), 1), tooSoon: true)

  if not response.ok:
    raise apiError($response.status, response.body)

  let data = decodeJson(response.body)
  if jsonText(data, "mail_delivery") notin ["sent", "failed"] or
      jsonText(data, "status") != jsonText(data, "mail_delivery"):
    raise newException(ValueError, "The verification email outcome was not confirmed. Reload before requesting another.")
  var step = parseVerificationStep(data)
  step.pending = true
  step.mailFailed = jsonText(data, "mail_delivery") == "failed"
  return step


proc verificationStatus*(): Future[VerificationStep] {.async.} =
  ## The verification step this browser's cookie belongs to, if any.
  let options = newFetchOptions(
    metod = HttpGet,
    mode = fmCors,
    credentials = fcInclude
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/auth/verification",
    options
  )

  if response.status == 404:
    return VerificationStep(pending: false)

  if not response.ok:
    raise apiError($response.status, response.body)

  let data = decodeJson(response.body)
  if jsonText(data, "status") == "verified":
    return VerificationStep(pending: false, verified: true)
  if jsonText(data, "status") != "pending":
    raise newException(ValueError, "The verification step could not be confirmed. Try signing in again.")
  var step = parseVerificationStep(data)
  step.pending = true
  return step


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
  return parseChatList(data)


proc searchChats*(query: string): Future[seq[ChatSearchResult]] {.async.} =
  ## The backend searches every saved chat this account owns.
  let options = newFetchOptions(
    metod = HttpGet,
    mode = fmCors,
    credentials = fcInclude
  )

  let response = await sendRequest(
    frontendConfig.backendBaseUrl & "/api/v1/chats/search?q=" & encodeUrl(query, usePlus = false),
    options
  )

  if not response.ok:
    raise apiError($response.status, response.body)

  let data = decodeJson(response.body)
  if data.kind != JObject or not data.hasKey("results") or data["results"].kind != JArray:
    raise newException(ValueError, "Backend chat search response is invalid.")

  var items = newSeq[ChatSearchResult]()
  for node in data["results"].items:
    items.add(
      ChatSearchResult(
        chatId: jsonText(node, "chat_id"),
        title: jsonText(node, "title"),
        matched: jsonText(node, "matched"),
        excerpt: jsonText(node, "excerpt")
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

  result = parseChat(data["chat"])


proc updateChat*(chatId: string, patch: JsonNode, csrfToken: string): Future[ChatSummary] {.async.} =
  if chatId.len == 0 or patch.kind != JObject or patch.len == 0:
    raise newException(ValueError, "A chat and metadata change are required.")
  let options = newFetchOptions(metod = HttpPatch, body = ($patch).cstring,
    mode = fmCors, credentials = fcInclude, headers = jsonHeaders(csrfToken))
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/chats/" &
    encodeUrl(chatId, usePlus = false), options)
  if not response.ok: raise apiError($response.status, response.body)
  return validateChatUpdate(decodeJson(response.body), chatId, patch)



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
          status: jsonText(node, "status"),
          references: (if node.kind == JObject and node.hasKey("references"): node["references"] else: nil)
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

  if data.kind != JObject or not data.hasKey("sessions") or data["sessions"].kind != JArray:
    raise newException(ValueError, "The session history response was invalid.")
  for node in data["sessions"].items:
    if node.kind != JObject or not node.hasKey("session_id") or
        node["session_id"].kind != JString or node["session_id"].getStr().len == 0 or
        not node.hasKey("current") or node["current"].kind != JBool:
      raise newException(ValueError, "The session history response was invalid.")
    for key in ["created_at", "last_seen_at", "expires_at", "revoked_at", "user_agent"]:
      if not node.hasKey(key) or node[key].kind notin {JString, JNull}:
        raise newException(ValueError, "The session history response was invalid.")
    items.add(SessionSummary(sessionId: jsonText(node, "session_id"),
      createdAt: jsonText(node, "created_at"), lastSeenAt: jsonText(node, "last_seen_at"),
      expiresAt: jsonText(node, "expires_at"), revokedAt: jsonText(node, "revoked_at"),
      userAgent: jsonText(node, "user_agent"), current: jsonBool(node, "current")))

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

  validateSessionRevocation(decodeJson(response.body), sessionId)
