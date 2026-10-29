## Browser recovery storage for an exact owner/server request. Storage is
## untrusted data; domain callers validate its schema before using it.
import std/json

proc browserRecovery(namespace, backend, owner, action, payload, errorMessage: cstring): cstring {.importjs: """
((namespace,backend,owner,action,payload,errorMessage)=>{
  try {
    const key=namespace+':'+JSON.stringify([backend,owner]);
    const storage=globalThis.sessionStorage;
    const existing=storage.getItem(key);
    if(action==='load') return JSON.stringify({value:existing});
    if(action==='save') {
      if(existing!==null&&existing!==payload) throw new Error('conflict');
      storage.setItem(key,payload);
      if(storage.getItem(key)!==payload) throw new Error('unconfirmed');
    } else if(action==='clear') {
      if(existing!==null&&existing!==payload) throw new Error('conflict');
      storage.removeItem(key);
      if(storage.getItem(key)!==null) throw new Error('unconfirmed');
    } else throw new Error('action');
    return '{"value":null}';
  } catch(error) {
    return JSON.stringify({error:errorMessage});
  }
})(#,#,#,#,#,#)
""".}

proc recoveryStorage*(namespace, owner, backend, action: string,
                      payload = "", errorMessage = "Request recovery storage could not be confirmed."): JsonNode =
  if owner.len == 0 or namespace.len == 0:
    raise newException(ValueError, "A signed-in owner and recovery namespace are required.")
  let reply = parseJson($browserRecovery(cstring(namespace), cstring(backend), cstring(owner),
                                        cstring(action), cstring(payload), cstring(errorMessage)))
  if reply.hasKey("error"): raise newException(ValueError, reply["error"].getStr)
  reply["value"]
