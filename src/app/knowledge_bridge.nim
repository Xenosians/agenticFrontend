## Loads knowledge sources and runs cited searches (FR-083).
include karax/prelude
import std/[asyncjs, json]
import ../api/extensions
import knowledge
import types
import state
import request_context
import extension_bridge

proc knowledgeSourceList*(state: AppState): seq[KnowledgeSource] =
  knowledgeSources(state.extensionCatalog)

proc chosenKnowledgeSource*(state: AppState): string =
  defaultKnowledgeSource(knowledgeSourceList(state), state.knowledgeSource)

proc changeKnowledgeSource*(state: AppState, source: string) =
  ## A reply for a previous source must not populate the newly selected one.
  ## This releases only the old read's UI state; it does not replay a request.
  inc state.knowledgeEpoch
  state.knowledgeSource = source
  state.knowledgeBusy = false
  state.knowledgeHits = @[]
  state.knowledgeSearched = false
  state.knowledgeError = ""

proc searchKnowledge*(state: AppState) {.async.} =
  ## One search at a time; a stale reply (sign-out, new search) is dropped.
  if not state.auth.authenticated or state.knowledgeBusy: return
  let source = chosenKnowledgeSource(state)
  var payload: JsonNode
  try:
    payload = knowledgeSearchPayload(source, state.knowledgeQuery)
  except ValueError as exc:
    state.knowledgeError = exc.msg
    redraw(kxi)
    return
  let request = beginKnowledgeRequest(state)
  state.knowledgeBusy = true
  state.knowledgeError = ""
  state.knowledgeHits = @[]
  state.knowledgeSearched = false
  redraw(kxi)
  try:
    let response = await extensionRequest("search", payload, state.auth.csrfToken)
    if not matchesKnowledgeRequest(state, request): return
    var title = ""
    for item in knowledgeSourceList(state):
      if item.id == source: title = item.title
    state.knowledgeHits = parseKnowledgeHits(response, source, title)
    state.knowledgeSearched = true
  except CatchableError as exc:
    if matchesKnowledgeRequest(state, request): state.knowledgeError = exc.msg
  finally:
    if matchesKnowledgeRequest(state, request): state.knowledgeBusy = false
    redraw(kxi)

proc openKnowledge*(state: AppState) =
  setActiveView(state, viewKnowledge)
  discard refreshExtensions(state)
