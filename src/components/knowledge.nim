## The Knowledge surface (FR-083): reference sources and cited search.
include karax/prelude
import karax/kdom
import ../app/types
import ../app/knowledge
import ../app/knowledge_bridge

proc renderSource(source: KnowledgeSource): VNode =
  result = buildHtml(article(class = "knowledge-source", `data-source-id` = cstring(source.id))):
    tdiv(class = "operation-job-heading"):
      strong: text source.title
      if source.selected:
        span(class = "review-status"): text "Used for your requests"
    p(class = "knowledge-meta"): text source.version
    p(class = "knowledge-meta"): text source.source & " · " & source.license
    if source.crawl.len > 0:
      p(class = "knowledge-meta knowledge-crawl"): text source.crawl

proc renderHit(hit: KnowledgeHit): VNode =
  result = buildHtml(article(class = "knowledge-hit")):
    tdiv(class = "operation-job-heading"):
      span(class = "knowledge-meta"):
        text (if hit.title.len > 0: hit.title & " · " else: "") & "Chunk " & $hit.chunk & " · " & hit.digest
      span(class = "knowledge-trust"): text "Untrusted reference"
    # Quoted as material from a document, never as an instruction to follow.
    blockquote(class = "knowledge-content"): text hit.content
    p(class = "knowledge-meta"): text hit.source & " · " & hit.license
    p(class = "knowledge-meta knowledge-citation-line"):
      span: text "Citation "
      code(class = "knowledge-citation"): text hit.locator

proc renderSearch(state: AppState, sources: seq[KnowledgeSource]): VNode =
  let chosen = chosenKnowledgeSource(state)
  result = buildHtml(form(class = "knowledge-search", role = "search")):
    proc onsubmit(event: Event, node: VNode) =
      event.preventDefault()
      discard searchKnowledge(state)
    label(class = "review-label", `for` = "knowledgeSource"): text "Source"
    select(id = "knowledgeSource", class = "knowledge-select"):
      for source in sources:
        option(value = cstring(source.id), selected = source.id == chosen):
          text source.title
      proc onchange(event: Event, node: VNode) =
        changeKnowledgeSource(state, $node.value)
        redraw(kxi)
    tdiv(class = "knowledge-query"):
      input(`type` = "search", class = "knowledge-input", `aria-label` = "Search knowledge",
          maxlength = $knowledgeQueryLimit, placeholder = "Search this source",
          value = cstring(state.knowledgeQuery)):
        proc oninput(event: Event, node: VNode) =
          state.knowledgeQuery = $node.value
      button(`type` = "submit", class = "secondary-action", disabled = state.knowledgeBusy):
        text (if state.knowledgeBusy: "Searching…" else: "Search")

proc renderKnowledgePanel*(state: AppState): VNode =
  let sources = knowledgeSourceList(state)
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view knowledge-panel"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2: text "Knowledge"
          p: text "Your reference datasets and what a search finds in them."
      p(class = "operation-note"):
        text "Results are untrusted reference text with a citation. They can inform an answer but never grant permission, approve an action or change routing."
      if state.extensionError.len > 0:
        p(class = "operation-error", role = "alert"): text state.extensionError
      if state.extensionCatalog == nil:
        p(class = "operation-note", role = "status"): text "Loading your sources…"
      elif sources.len == 0:
        tdiv(class = "empty-card"):
          text "No reference datasets yet. Add one under Connections → Data & automation with the purpose " &
            "Reference, or crawl a site this machine allows."
      else:
        tdiv(class = "section-heading-row"):
          h3: text "Sources"
        for source in sources:
          renderSource(source)
        tdiv(class = "section-heading-row"):
          h3: text "Search"
        renderSearch(state, sources)
        if state.knowledgeError.len > 0:
          p(class = "operation-error", role = "alert"): text state.knowledgeError
        if state.knowledgeSearched:
          p(class = "operation-note", role = "status"):
            text (if state.knowledgeHits.len == 0: "No passages matched." else: $state.knowledgeHits.len & " passages found.")
          for hit in state.knowledgeHits:
            renderHit(hit)
