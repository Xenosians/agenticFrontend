import std/[asyncjs, jsfetch, jsheaders, json]
from std/httpcore import HttpPost

const
  BackendBaseUrl* = "http://127.0.0.1:4000"


type
  JobCreateResponse* = object
    jobId*: string
    status*: string


proc createJob*(
  userId: string,
  conversationId: string,
  message: string
): Future[JobCreateResponse] {.async.} =

  let headers = newHeaders()

  headers["Content-Type"] = "application/json"

  let payload = %*{
    "user_id": userId,
    "conversation_id": conversationId,
    "message": message
  }

  let options = newFetchOptions(
    metod = HttpPost,
    body = ($payload).cstring,
    mode = fmCors,
    credentials = fcOmit,
    headers = headers
  )

  let response = await fetch(
    (BackendBaseUrl & "/api/v1/jobs").cstring,
    options
  )

  let responseBody = $(await response.text())

  if not response.ok:
    raise newException(
      ValueError,
      "Backend returned HTTP " &
      $response.status &
      ": " &
      responseBody
    )

  let data = parseJson(responseBody)

  result = JobCreateResponse(
    jobId: data["job_id"].getStr(),
    status: data["status"].getStr()
  )