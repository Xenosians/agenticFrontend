## Crawling a site into reference knowledge (SRS 1.9 FR-083/FR-085). The machine's
## Lua profile decides which sites may be crawled; the AI service fetches them and
## admits the text like any upload. The browser only picks a declared site, a start
## page and the dataset fields.

import std/[json, strutils]

proc crawlSources*(catalog: JsonNode): seq[string] =
  ## The sites this machine's profile lets a user crawl, as the catalog lists them.
  if catalog == nil or catalog.kind != JObject or not catalog.hasKey("crawl_sources") or
      catalog["crawl_sources"].kind != JArray:
    return
  for site in catalog["crawl_sources"]:
    if site.kind == JString and site.getStr.len > 0:
      result.add site.getStr

proc crawlSiteOf*(url: string, sites: seq[string]): string =
  ## The declared site a start page belongs to, or "" when it is outside every one.
  let address = url.strip()
  for site in sites:
    if address == site or address.startsWith(site & "/"):
      return site

proc crawlPayload*(url, name, license: string, reviewed: bool, replaces: string): JsonNode =
  ## Crawled pages are third-party text: always reference knowledge, never training data.
  result = %*{"url": url.strip(), "name": name, "license": license, "purpose": "rag", "reviewed": reviewed}
  if replaces.len > 0:
    result["replaces"] = %replaces

proc crawlSummary*(row: JsonNode): string =
  ## "Read N pages from <start>" for a dataset that came from a crawl, otherwise "".
  if row == nil or row.kind != JObject or not row.hasKey("crawl") or row["crawl"].kind != JObject:
    return
  let crawl = row["crawl"]
  if not crawl.hasKey("pages") or crawl["pages"].kind != JArray or crawl["pages"].len == 0:
    return
  let pages = crawl["pages"]
  let start = if pages[0].kind == JObject and pages[0].hasKey("url"): pages[0]["url"].getStr else: ""
  result = "Read " & $pages.len & (if pages.len == 1: " page" else: " pages") & " from " & start
  if crawl.hasKey("truncated") and crawl["truncated"].kind == JBool and crawl["truncated"].getBool:
    result.add " · stopped at the crawl limit"
  if crawl.hasKey("skipped") and crawl["skipped"].kind == JObject and crawl["skipped"].hasKey("sensitive") and
      crawl["skipped"]["sensitive"].kind == JInt and crawl["skipped"]["sensitive"].getInt > 0:
    let withheld = crawl["skipped"]["sensitive"].getInt
    result.add " · " & $withheld & (if withheld == 1: " page" else: " pages") &
      " withheld for possible credentials or personal data"
