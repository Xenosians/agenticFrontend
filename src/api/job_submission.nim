import std/json
import ../config/runtime_config

type PendingSubmission* = object
  identity*, message*: string
  workflowContract*: JsonNode

proc browserCall(base, owner, chat, action, payload: cstring): cstring {.importjs: """
((base,owner,chat,action,payload)=>{
  try {
    if(action==='clear') {
      globalThis.AgenticJobSubmission.clearOwner(globalThis.sessionStorage,base,owner);
      return '{"value":null}';
    }
    const store=globalThis.AgenticJobSubmission.create(globalThis.sessionStorage,globalThis.crypto,base,owner,chat);
    const request=action==='prepare'?JSON.parse(payload):null;
    const value=action==='pending'?store.pending():action==='prepare'?store.prepare(request.message,request.workflow_contract):
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
  PendingSubmission(identity: node["submission_id"].getStr, message: node["message"].getStr,
    workflowContract: (if node.hasKey("workflow_contract"): node["workflow_contract"] else: nil))

proc prepareSubmission*(owner, chat, message: string, workflowContract: JsonNode = nil): PendingSubmission =
  let payload = %*{"message": message}
  if workflowContract != nil: payload["workflow_contract"] = workflowContract
  parsePending(call(owner, chat, "prepare", $payload))

proc pendingSubmission*(owner, chat: string): PendingSubmission =
  parsePending(call(owner, chat, "pending"))

proc acknowledgeSubmission*(owner, chat, jobId, status, identity: string,
    workflowContract: JsonNode = nil, workflowContractHash = "") =
  let payload = %*{"job_id": jobId, "status": status, "submission_id": identity}
  if workflowContract != nil and workflowContract.kind != JNull:
    payload["workflow_contract"] = workflowContract
    payload["workflow_contract_hash"] = %workflowContractHash
  discard call(owner, chat, "acknowledge", $payload)

proc rejectSubmission*(owner, chat, identity: string) =
  discard call(owner, chat, "reject", identity)

proc clearOwnerSubmissions*(owner: string) =
  if owner.len > 0: discard call(owner, "", "clear")
