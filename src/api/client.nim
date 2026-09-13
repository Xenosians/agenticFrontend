import std/[
  asyncjs,
  jsfetch,
  jsheaders,
  json
]

from std/httpcore import
  HttpGet,
  HttpPost

import ../config/runtime_config


type
  JobCreateResponse* = object
    jobId*: string
    status*: string


  JobResponse* = object
    jobId*: string
    status*: string

    selectedAgent*: string
    proposedTool*: string

    answer*: string
    error*: string


  SystemHealthResponse* = object
    backendConnected*: bool

    aiReachable*: bool
    aiHealthy*: bool
    aiReady*: bool


proc jsonValueText(
  node: JsonNode,
  key: string
): string =

  if node.kind != JObject:
    return ""

  if not node.hasKey(
    key
  ):
    return ""


  let value =
    node[
      key
    ]


  case value.kind

  of JString:
    return value.getStr()

  of JNull:
    return ""

  else:
    return $value


proc jsonValueBool(
  node: JsonNode,
  key: string
): bool =

  if node.kind != JObject:
    return false

  if not node.hasKey(
    key
  ):
    return false


  let value =
    node[
      key
    ]


  if value.kind ==
     JBool:

    return value.getBool()


  return false


proc extractAnswer(
  data: JsonNode
): string =

  if data.kind != JObject:
    return ""

  if not data.hasKey(
    "result"
  ):
    return ""


  let jobResult =
    data[
      "result"
    ]


  if jobResult.kind != JObject:
    return ""


  let answer =
    jsonValueText(
      jobResult,
      "answer"
    )


  if answer.len > 0:
    return answer


  return jsonValueText(
    jobResult,
    "value"
  )


proc extractProposedTool(
  data: JsonNode
): string =

  if data.kind != JObject:
    return ""

  if not data.hasKey(
    "proposed_tool"
  ):
    return ""


  let proposedTool =
    data[
      "proposed_tool"
    ]


  if proposedTool.kind != JObject:
    return ""


  return jsonValueText(
    proposedTool,
    "tool"
  )


proc parseJobResponse(
  data: JsonNode
): JobResponse =

  result =
    JobResponse(
      jobId:
        jsonValueText(
          data,
          "job_id"
        ),

      status:
        jsonValueText(
          data,
          "status"
        ),

      selectedAgent:
        jsonValueText(
          data,
          "selected_agent"
        ),

      proposedTool:
        extractProposedTool(
          data
        ),

      answer:
        extractAnswer(
          data
        ),

      error:
        jsonValueText(
          data,
          "error"
        )
    )


proc getSystemHealth*():
  Future[SystemHealthResponse] {.async.} =

  let options =
    newFetchOptions(
      metod =
        HttpGet,

      mode =
        fmCors,

      credentials =
        fcOmit
    )


  let response =
    await fetch(
      (
        frontendConfig
        .backendBaseUrl &
        "/api/health"
      ).cstring,

      options
    )


  let responseBody =
    $(
      await response.text()
    )


  if not response.ok:

    raise newException(
      ValueError,
      "Backend health returned HTTP " &
      $response.status &
      ": " &
      responseBody
    )


  let data =
    parseJson(
      responseBody
    )


  if data.kind != JObject:

    raise newException(
      ValueError,
      "Backend health response must be a JSON object."
    )


  if jsonValueText(
       data,
       "status"
     ) !=
       "ok":

    raise newException(
      ValueError,
      "Backend health response is not healthy."
    )


  var
    aiReachable =
      false

    aiHealthy =
      false

    aiReady =
      false


  if data.hasKey(
    "ai_service"
  ):

    let aiService =
      data[
        "ai_service"
      ]


    if aiService.kind ==
       JObject:

      aiReachable =
        jsonValueBool(
          aiService,
          "reachable"
        )

      aiHealthy =
        jsonValueBool(
          aiService,
          "healthy"
        )

      aiReady =
        jsonValueBool(
          aiService,
          "ready"
        )


  result =
    SystemHealthResponse(
      backendConnected:
        true,

      aiReachable:
        aiReachable,

      aiHealthy:
        aiHealthy,

      aiReady:
        aiReady
    )


proc createJob*(
  userId: string,
  conversationId: string,
  message: string
): Future[JobCreateResponse] {.async.} =

  let headers =
    newHeaders()


  headers[
    "Content-Type"
  ] =
    "application/json"


  var payload = %*{
    "user_id":
      userId,

    "message":
      message
  }


  if conversationId.len > 0:

    payload[
      "conversation_id"
    ] =
      %conversationId


  let options =
    newFetchOptions(
      metod =
        HttpPost,

      body =
        ($payload).cstring,

      mode =
        fmCors,

      credentials =
        fcOmit,

      headers =
        headers
    )


  let response =
    await fetch(
      (
        frontendConfig
        .backendBaseUrl &
        "/api/v1/jobs"
      ).cstring,

      options
    )


  let responseBody =
    $(
      await response.text()
    )


  if not response.ok:

    raise newException(
      ValueError,
      "Backend returned HTTP " &
      $response.status &
      ": " &
      responseBody
    )


  let data =
    parseJson(
      responseBody
    )


  result =
    JobCreateResponse(
      jobId:
        data[
          "job_id"
        ].getStr(),

      status:
        data[
          "status"
        ].getStr()
    )


proc getJob*(
  jobId: string
): Future[JobResponse] {.async.} =

  let options =
    newFetchOptions(
      metod =
        HttpGet,

      mode =
        fmCors,

      credentials =
        fcOmit
    )


  let response =
    await fetch(
      (
        frontendConfig
        .backendBaseUrl &
        "/api/v1/jobs/" &
        jobId
      ).cstring,

      options
    )


  let responseBody =
    $(
      await response.text()
    )


  if not response.ok:

    raise newException(
      ValueError,
      "Backend returned HTTP " &
      $response.status &
      ": " &
      responseBody
    )


  let data =
    parseJson(
      responseBody
    )


  result =
    parseJobResponse(
      data
    )


proc approveJob*(
  jobId: string
): Future[JobResponse] {.async.} =

  let options =
    newFetchOptions(
      metod =
        HttpPost,

      mode =
        fmCors,

      credentials =
        fcOmit
    )


  let response =
    await fetch(
      (
        frontendConfig
        .backendBaseUrl &
        "/api/v1/jobs/" &
        jobId &
        "/approve"
      ).cstring,

      options
    )


  let responseBody =
    $(
      await response.text()
    )


  if not response.ok:

    raise newException(
      ValueError,
      "Backend returned HTTP " &
      $response.status &
      ": " &
      responseBody
    )


  let data =
    parseJson(
      responseBody
    )


  result =
    parseJobResponse(
      data
    )