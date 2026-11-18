import std/[sets, unittest]
import karax/vdom
import ../src/components/icons

suite "Lucide icons (owner decision of 18 November: real icons instead of text glyphs)":
  test "every icon the app names exists and draws at least one shape":
    let names = toHashSet(iconNames())
    for name in ["chat", "search", "model-store", "store", "settings", "review", "plus", "automation",
                 "topology", "knowledge", "operations", "learning", "pin", "unpin", "rename", "close",
                 "more", "refresh", "chevron-right", "chevron-down", "send", "back", "check", "enter"]:
      check name in names
      check icon(name).len > 0

  test "an icon is decorative, in the text colour, on the 24-unit grid":
    let node = icon("search")
    check node.kind == VNodeKind.svg
    check node.getAttr("aria-hidden") == "true"
    check node.getAttr("stroke") == "currentColor"
    check node.getAttr("fill") == "none"
    check node.getAttr("viewBox") == "0 0 24 24"
    check node.getAttr("width") == "16"
    # Karax keeps the class on the node itself, not among its attributes.
    check node.class == "icon icon-search"
    check icon("send", 20, "send-icon").class == "icon icon-send send-icon"

  test "an unknown name draws nothing instead of failing":
    check icon("no-such-icon").len == 0
