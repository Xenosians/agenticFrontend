## Crawling a site into reference knowledge (SRS 1.9 FR-083/FR-085). The catalog lists
## the sites this user may crawl: the machine's own and, when the machine's Lua profile
## allows it, the ones the user added. The AI service fetches the pages and admits the
## text like any upload; the browser only picks a site, a start page and the dataset fields.

import std/[json, strutils]

type
  CrawlSite* = object
    origin*: string
    managed*: bool  ## Declared by the machine, so the user cannot remove it.

proc crawlSites*(catalog: JsonNode): seq[CrawlSite] =
  ## The sites this user may crawl, as the catalog lists them.
  if catalog == nil or catalog.kind != JObject or not catalog.hasKey("crawl_sites") or
      catalog["crawl_sites"].kind != JArray:
    return
  for site in catalog["crawl_sites"]:
    if site.kind == JObject and site.hasKey("origin") and site["origin"].kind == JString and
        site["origin"].getStr.len > 0:
      let managed = site.hasKey("managed") and site["managed"].kind == JBool and site["managed"].getBool
      result.add CrawlSite(origin: site["origin"].getStr, managed: managed)

proc siteOrigins*(sites: seq[CrawlSite]): seq[string] =
  for site in sites: result.add site.origin

proc siteRegistrationOpen*(catalog: JsonNode): bool =
  ## Whether this machine lets the user add their own sites.
  catalog != nil and catalog.kind == JObject and catalog.hasKey("crawl_site_registration") and
    catalog["crawl_site_registration"].kind == JBool and catalog["crawl_site_registration"].getBool

proc siteToAdd*(value: string): string =
  ## The site address a user typed, trimmed; the AI service checks and normalizes it.
  value.strip().strip(leading = false, chars = {'/'})

proc crawlSiteOf*(url: string, sites: seq[string]): string =
  ## The site a start page belongs to, or "" when it is outside every one.
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
  let automatic = crawl.hasKey("automatic") and crawl["automatic"].kind == JBool and crawl["automatic"].getBool
  result = (if automatic: "Read automatically: " & $pages.len else: "Read " & $pages.len) &
    (if pages.len == 1: " page" else: " pages") & " from " & start
  if crawl.hasKey("truncated") and crawl["truncated"].kind == JBool and crawl["truncated"].getBool:
    result.add " · stopped at the crawl limit"
  if crawl.hasKey("skipped") and crawl["skipped"].kind == JObject and crawl["skipped"].hasKey("sensitive") and
      crawl["skipped"]["sensitive"].kind == JInt and crawl["skipped"]["sensitive"].getInt > 0:
    let withheld = crawl["skipped"]["sensitive"].getInt
    result.add " · " & $withheld & (if withheld == 1: " page" else: " pages") &
      " withheld for possible credentials or personal data"
