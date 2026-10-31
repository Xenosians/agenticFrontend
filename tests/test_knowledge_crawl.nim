import std/[json, unittest]
import ../src/app/knowledge_crawl

suite "knowledge crawl":
  test "the catalog's declared sites are offered in order":
    check crawlSources(%*{"crawl_sources": ["https://docs.example.org", "http://wiki.lan:8090"]}) ==
      @["https://docs.example.org", "http://wiki.lan:8090"]

  test "a machine that declares no sites offers no crawling":
    for catalog in [newJNull(), %*{}, %*{"crawl_sources": []}, %*{"crawl_sources": "https://x.example"},
                    %*{"crawl_sources": [7, ""]}]:
      check crawlSources(catalog).len == 0

  test "a start page must belong to a declared site":
    let sites = @["https://docs.example.org", "http://wiki.lan:8090"]
    check crawlSiteOf("https://docs.example.org/vpn/", sites) == "https://docs.example.org"
    check crawlSiteOf("  http://wiki.lan:8090/  ", sites) == "http://wiki.lan:8090"
    check crawlSiteOf("https://docs.example.org", sites) == "https://docs.example.org"
    for outside in ["https://docs.example.org.evil.test/", "https://docs.example.orgx/", "http://docs.example.org/",
                    "https://elsewhere.example/", "", "docs.example.org/vpn"]:
      check crawlSiteOf(outside, sites) == ""

  test "a crawl request carries the start page and the dataset fields, as reference only":
    check crawlPayload(" https://docs.example.org/vpn/ ", "VPN docs", "Internal", true, "") ==
      %*{"url": "https://docs.example.org/vpn/", "name": "VPN docs", "license": "Internal",
         "purpose": "rag", "reviewed": true}
    let replacing = crawlPayload("https://docs.example.org/", "Docs", "Internal", true, "a1b2c3d4e5f60718293a4b5c6d7e8f90")
    check replacing["replaces"].getStr == "a1b2c3d4e5f60718293a4b5c6d7e8f90"

  test "a saved crawl reports how many pages it read":
    let row = %*{"kind": "dataset", "crawl": {"schema": "knowledge-crawl.v1",
      "pages": [{"url": "https://docs.example.org/", "title": "Docs", "sha256": "a"},
                {"url": "https://docs.example.org/vpn", "title": "VPN", "sha256": "b"}],
      "skipped": {"robots": 1}, "truncated": true}}
    check crawlSummary(row) == "Read 2 pages from https://docs.example.org/ · stopped at the crawl limit"
    check crawlSummary(%*{"kind": "dataset"}) == ""

  test "pages withheld for possible credentials or personal data are counted":
    let row = %*{"kind": "dataset", "crawl": {"schema": "knowledge-crawl.v1", "truncated": false,
      "pages": [{"url": "https://docs.example.org/", "title": "Docs", "sha256": "a"}],
      "skipped": {"sensitive": 2, "robots": 1}}}
    check crawlSummary(row) ==
      "Read 1 page from https://docs.example.org/ · 2 pages withheld for possible credentials or personal data"
