## Page-memory recovery for an exact owner/server request. Nothing is written
## to browser storage: a record survives a lost reply within this page, and a
## reload drops it, leaving the server's saved runs as the authority.
## Records are still untrusted data; domain callers validate their schema.
import std/[json, tables]

var records = initTable[string, string]()

proc recordKey(namespace, backend, owner: string): string =
  $(%*[namespace, backend, owner])

proc recoveryStorage*(namespace, owner, backend, action: string,
                      payload = "", errorMessage = "The pending request could not be confirmed."): JsonNode =
  if owner.len == 0 or namespace.len == 0:
    raise newException(ValueError, "A signed-in owner and recovery namespace are required.")
  let key = recordKey(namespace, backend, owner)
  let existing = records.getOrDefault(key, "")
  case action
  of "load":
    result = if records.hasKey(key): %existing else: newJNull()
  of "save":
    if records.hasKey(key) and existing != payload: raise newException(ValueError, errorMessage)
    records[key] = payload
    result = newJNull()
  of "clear":
    if records.hasKey(key) and existing != payload: raise newException(ValueError, errorMessage)
    records.del(key)
    result = newJNull()
  else:
    raise newException(ValueError, errorMessage)

proc clearOwnerRecovery*(owner: string) =
  ## Explicit sign-out drops this owner's pending request text from the page.
  var keys: seq[string]
  for key in records.keys:
    let scope = parseJson(key)
    if scope.len == 3 and scope[2].getStr == owner: keys.add key
  for key in keys: records.del(key)
