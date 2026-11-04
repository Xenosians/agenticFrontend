import std/[json, unittest]
import ../src/app/knowledge_crawl

suite "knowledge crawl":
  test "the catalog's sites are offered in order, the machine's marked as managed":
    let sites = crawlSites(%*{"crawl_sites": [{"origin": "https://docs.example.org", "managed": true},
                                              {"origin": "http://wiki.lan:8090", "managed": false}]})
    check sites == @[CrawlSite(origin: "https://docs.example.org", managed: true),
                     CrawlSite(origin: "http://wiki.lan:8090", managed: false)]
    check siteOrigins(sites) == @["https://docs.example.org", "http://wiki.lan:8090"]

  test "a catalog without sites offers none, and malformed entries are ignored":
    for catalog in [newJNull(), %*{}, %*{"crawl_sites": []}, %*{"crawl_sites": "https://x.example"},
                    %*{"crawl_sites": [7, "", {"origin": ""}, {"managed": true}, {"origin": 3}]}]:
      check crawlSites(catalog).len == 0

  test "registration is offered only when the catalog says it is open":
    check siteRegistrationOpen(%*{"crawl_site_registration": true})
    for catalog in [newJNull(), %*{}, %*{"crawl_site_registration": false}, %*{"crawl_site_registration": "yes"}]:
      check not siteRegistrationOpen(catalog)

  test "a start page must belong to one of the sites":
    let sites = @["https://docs.example.org", "http://wiki.lan:8090"]
    check crawlSiteOf("https://docs.example.org/vpn/", sites) == "https://docs.example.org"
    check crawlSiteOf("  http://wiki.lan:8090/  ", sites) == "http://wiki.lan:8090"
    check crawlSiteOf("https://docs.example.org", sites) == "https://docs.example.org"
    for outside in ["https://docs.example.org.evil.test/", "https://docs.example.orgx/", "http://docs.example.org/",
                    "https://elsewhere.example/", "", "docs.example.org/vpn"]:
      check crawlSiteOf(outside, sites) == ""

  test "a site to add is trimmed and keeps no trailing slash":
    check siteToAdd("  https://wiki.example.net/ ") == "https://wiki.example.net"
    check siteToAdd("https://wiki.example.net") == "https://wiki.example.net"
    check siteToAdd("   ") == ""

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

  test "a site Janus read on its own says so":
    let row = %*{"kind": "dataset", "crawl": {"schema": "knowledge-crawl.v1", "truncated": false,
      "automatic": true, "site": "https://docs.example.org",
      "pages": [{"url": "https://docs.example.org/", "title": "Docs", "sha256": "a"},
                {"url": "https://docs.example.org/vpn", "title": "VPN", "sha256": "b"}],
      "skipped": {}}}
    check crawlSummary(row) == "Read automatically: 2 pages from https://docs.example.org/"
