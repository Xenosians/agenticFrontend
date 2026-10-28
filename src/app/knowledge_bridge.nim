## Loads knowledge sources and runs cited searches (FR-083).
include karax/prelude
import std/[asyncjs, json]
import ../api/extensions
import knowledge
import answer_references
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

proc reopenedPassage*(state: AppState, locator: string): string =
  for (key, content) in state.referencePassages:
    if key == locator: return content

proc reopenAnswerReference*(state: AppState, row: AnswerReference) {.async.} =
  ## Shows the exact cited passage; a reply after sign-out or another reopen is dropped.
  if not state.auth.authenticated or state.referenceOpening.len > 0 or
      reopenedPassage(state, row.locator).len > 0:
    return
  let request = beginReferenceRequest(state)
  state.referenceOpening = row.locator
  state.referenceError = ""
  state.referenceErrorLocator = ""
  redraw(kxi)
  try:
    let response = await extensionRequest("resolve", referenceResolvePayload(row), state.auth.csrfToken)
    if not matchesReferenceRequest(state, request): return
    state.referencePassages.add (row.locator, parseReopenedPassage(response, row))
  except CatchableError as exc:
    if matchesReferenceRequest(state, request):
      state.referenceError = exc.msg
      state.referenceErrorLocator = row.locator
  finally:
    if matchesReferenceRequest(state, request): state.referenceOpening = ""
    redraw(kxi)
