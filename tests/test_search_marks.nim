import std/[strutils, unittest]
import ../src/components/search_marks

proc marked(text, query: string): seq[string] =
  ## The marked slices, in order, as a reader would see them.
  for span in matchSpans(text, query):
    if span.matched:
      result.add text[span.first ..< span.first + span.len]

suite "search match marks":
  test "every occurrence is marked, ignoring case, and the text is kept whole":
    let text = "Reset the VPN token; vpn users first"
    check marked(text, "VPN") == @["VPN", "vpn"]
    var rebuilt = ""
    for span in matchSpans(text, "vpn"):
      rebuilt.add text[span.first ..< span.first + span.len]
    check rebuilt == text

  test "surrounding spaces in the query do not change the match":
    check marked("Printer offline again", "  printer offline ") == @["Printer offline"]

  test "a blank query or no match marks nothing":
    check marked("Printer offline", "   ").len == 0
    check marked("Printer offline", "scanner").len == 0
    check matchSpans("", "vpn").len == 0

suite "search excerpts":
  test "a match late in a long message is brought to the start of the line":
    let text = "The nightly job ran for an hour and then failed, so the team started a rollback"
    let excerpt = excerptAround(text, "ROLLBACK", lead = 12)
    check excerpt.startsWith("…")
    check excerpt.endsWith("started a rollback")
    check excerpt.find("rollback") <= 12 + "…".len

  test "an early match, a blank query or no match keeps the text as it is":
    check excerptAround("Reset the VPN token", "vpn") == "Reset the VPN token"
    check excerptAround("Reset the VPN token", "  ") == "Reset the VPN token"
    check excerptAround("Reset the VPN token", "printer") == "Reset the VPN token"

  test "the cut falls between words, never inside one":
    let excerpt = excerptAround("alpha beta gamma delta epsilon zeta eta theta rollback", "rollback", lead = 10)
    check excerpt == "…eta theta rollback"
