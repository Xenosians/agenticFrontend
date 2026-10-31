## The Knowledge surface (FR-083): the owner's reference datasets and cited search.
##
## Sources come from the extension catalog; search runs through the AI
## service's owner-scoped retrieval. Every hit is shown as untrusted reference
## text with its citation; it never grants permission or changes routing.

import std/[json, strutils]
import dataset_versions
import knowledge_crawl

const knowledgeQueryLimit* = 200

type
  KnowledgeSource* = object
    id*, title*, version*, source*, license*: string
    crawl*: string  ## "Read N pages from <site>" for a crawled site; "" for an upload.
    selected*: bool

  KnowledgeHit* = object
    content*, source*, license*, locator*, digest*, title*: string
    chunk*: int


proc text(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr
  else: ""


proc selectedDataset(catalog: JsonNode): string =
  if catalog != nil and catalog.kind == JObject and catalog.hasKey("selected"):
    return text(catalog["selected"], "dataset_id")


proc knowledgeSources*(catalog: JsonNode): seq[KnowledgeSource] =
  ## Ready reference (RAG) datasets, in catalog order.
  if catalog == nil or catalog.kind != JObject or not catalog.hasKey("resources") or
      catalog["resources"].kind != JArray:
    return
  let selected = selectedDataset(catalog)
  for row in catalog["resources"]:
    if text(row, "kind") != "dataset" or text(row, "purpose") != "rag" or text(row, "state") != "ready":
      continue
    let identity = text(row, "id")
    if identity.len == 0: continue
    result.add KnowledgeSource(id: identity, title: datasetTitle(row), version: versionLabel(catalog, row),
      source: text(row, "source"), license: text(row, "license"), crawl: crawlSummary(row),
      selected: identity == selected)


proc defaultKnowledgeSource*(sources: seq[KnowledgeSource], chosen: string): string =
  ## The chosen source while it exists, else the one used for requests, else the first.
  for source in sources:
    if source.id == chosen: return source.id
  for source in sources:
    if source.selected: return source.id
  if sources.len > 0: sources[0].id else: ""


proc knowledgeSearchPayload*(sourceId, query: string): JsonNode =
  let query = query.strip()
  if sourceId.len == 0:
    raise newException(ValueError, "Choose a source to search.")
  if query.len == 0:
    raise newException(ValueError, "Enter words to search for.")
  %*{"id": sourceId, "query": query[0 ..< min(query.len, knowledgeQueryLimit)]}


proc parseKnowledgeHits*(data: JsonNode, sourceId: string, title = ""): seq[KnowledgeHit] =
  ## Keeps only owner-private, untrusted hits from the searched source, named by its title.
  if data == nil or data.kind != JObject or not data.hasKey("hits") or data["hits"].kind != JArray:
    raise newException(ValueError, "The search response was invalid. Search again to check this source.")
  for row in data["hits"]:
    if row.kind != JObject or text(row, "schema") != "owner-retrieval.v1":
      raise newException(ValueError, "The search returned an unsupported passage. Search again to check this source.")
    if text(row, "dataset_id") != sourceId or
        text(row, "trust") != "untrusted_retrieval" or text(row, "scope") != "owner_private":
      continue
    if not row.hasKey("chunk") or row["chunk"].kind != JInt or row["chunk"].getInt < 1:
      raise newException(ValueError, "The search returned an invalid citation. Search again to check this source.")
    let digest = text(row, "sha256")
    let contentDigest = text(row, "content_sha256")
    let locator = text(row, "locator")
    if digest.len != 64 or not digest.allCharsInSet({'0'..'9', 'a'..'f'}) or
        contentDigest.len != 64 or not contentDigest.allCharsInSet({'0'..'9', 'a'..'f'}) or
        text(row, "source_type") != "dataset" or text(row, "content").len == 0 or
        text(row, "source").len == 0 or text(row, "license").len == 0 or
        locator != "dataset:" & sourceId & "#chunk:" & $row["chunk"].getInt & "@" & digest:
      raise newException(ValueError, "The search returned an invalid citation. Search again to check this source.")
    result.add KnowledgeHit(content: text(row, "content"), source: text(row, "source"),
      license: text(row, "license"), locator: locator, title: title,
      digest: digest[0 ..< min(8, digest.len)], chunk: row["chunk"].getInt)
