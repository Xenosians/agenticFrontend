import std/json
import ../config/runtime_config

type PendingSubmission* = object
  identity*, message*: string

proc browserCall(base, owner, chat, action, payload: cstring): cstring {.importjs: """
((base,owner,chat,action,payload)=>{
  try {
    if(action==='clear') {
      globalThis.AgenticJobSubmission.clearOwner(globalThis.sessionStorage,base,owner);
      return '{"value":null}';
    }
    const store=globalThis.AgenticJobSubmission.create(globalThis.sessionStorage,globalThis.crypto,base,owner,chat);
    const value=action==='pending'?store.pending():action==='prepare'?store.prepare(payload):
      action==='acknowledge'?store.acknowledge(JSON.parse(payload)):store.reject(payload);
    return JSON.stringify({value:value===undefined?null:value});
  } catch(error) {
    return JSON.stringify({error:error&&typeof error.message==='string'?error.message:'Browser storage is unavailable.'});
  }
})(#,#,#,#,#)
""".}

proc call(owner, chat, action: string, payload = ""): JsonNode =
  # Browser exceptions cross as data and become a normal Nim exception.
  # Otherwise native storage Errors would escape CatchableError handlers.
  let response = parseJson($browserCall(cstring(frontendConfig.backendBaseUrl),
    cstring(owner), cstring(chat), cstring(action), cstring(payload)))
  if response.hasKey("error"):
    raise newException(ValueError, response["error"].getStr)
  response["value"]

proc parsePending(node: JsonNode): PendingSubmission =
  if node.kind == JNull: return
  PendingSubmission(identity: node["submission_id"].getStr, message: node["message"].getStr)

proc prepareSubmission*(owner, chat, message: string): PendingSubmission =
  parsePending(call(owner, chat, "prepare", message))

proc pendingSubmission*(owner, chat: string): PendingSubmission =
  parsePending(call(owner, chat, "pending"))

proc acknowledgeSubmission*(owner, chat, jobId, status, identity: string) =
  discard call(owner, chat, "acknowledge", $(%*{"job_id": jobId, "status": status, "submission_id": identity}))

proc rejectSubmission*(owner, chat, identity: string) =
  discard call(owner, chat, "reject", identity)

proc clearOwnerSubmissions*(owner: string) =
  if owner.len > 0: discard call(owner, "", "clear")
