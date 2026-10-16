import std/unittest
import ../src/api/message_format

suite "safe assistant message formatting":
  test "structures paragraphs headings and consecutive lists without altering content":
    let parts = messageBlocks("## Account created\n\nA **real** result.\n\n- Directory saved\n- Mailbox verified\n\n1. Review\n2. Continue")
    check parts.len == 4
    check parts[0].kind == mbHeading
    check parts[0].content == "Account created"
    check parts[1].content == "A **real** result."
    check parts[2].kind == mbList
    check parts[2].items == @["Directory saved", "Mailbox verified"]
    check parts[3].kind == mbOrderedList
    check parts[3].items == @["Review", "Continue"]
  test "HTML URLs and unmatched markup remain literal text":
    let source = "<img src=x onerror=alert(1)> [unsafe](javascript:alert(1)) **unfinished"
    let blocks = messageBlocks(source)
    check blocks.len == 1
    check blocks[0].content == source
    let spans = messageSpans(source)
    check spans.len == 1
    check spans[0].kind == msText
    check spans[0].content == source
  test "fenced code preserves indentation and avoids interpreting nested markdown":
    let parts = messageBlocks("```python\n  **literal**\n<script>alert(1)</script>\n```\nAfter")
    check parts.len == 2
    check parts[0].kind == mbCode
    check parts[0].content == "  **literal**\n<script>alert(1)</script>"
    check parts[1].kind == mbParagraph
  test "inline code and emphasis have bounded text-only tokens":
    let spans = messageSpans("Review **account** and `ticket_create`.")
    check spans.len == 5
    check spans[1].kind == msStrong
    check spans[1].content == "account"
    check spans[3].kind == msCode
    check spans[3].content == "ticket_create"
