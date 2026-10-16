import std/strutils

type
  MessageBlockKind* = enum
    mbParagraph, mbHeading, mbList, mbOrderedList, mbCode
  MessageBlock* = object
    kind*: MessageBlockKind
    content*: string
    items*: seq[string]
  MessageSpanKind* = enum
    msText, msStrong, msCode
  MessageSpan* = object
    kind*: MessageSpanKind
    content*: string

proc listPrefix(line: string): int =
  if line.startsWith("- ") or line.startsWith("* "): return 2
  var index = 0
  while index < line.len and line[index] in {'0'..'9'}: inc index
  if index > 0 and index + 1 < line.len and line[index..index + 1] == ". ":
    return index + 2

proc headingPrefix(line: string): int =
  var index = 0
  while index < min(6, line.len) and line[index] == '#': inc index
  if index > 0 and index < line.len and line[index] == ' ': return index + 1

proc messageBlocks*(source: string): seq[MessageBlock] =
  ## This is a display subset, not an HTML/Markdown interpreter. Every returned
  ## value is rendered through Karax text nodes, including raw HTML and URLs.
  var pending = MessageBlock(kind: mbParagraph)
  var hasPending = false
  var fenced = false

  template flush() =
    if hasPending:
      result.add(pending)
      hasPending = false
      pending = MessageBlock(kind: mbParagraph)

  for original in source.splitLines():
    let line = original.strip()
    if line.startsWith("```"):
      if fenced:
        flush()
        fenced = false
      else:
        flush()
        pending.kind = mbCode
        hasPending = true
        fenced = true
    elif fenced:
      if pending.content.len > 0: pending.content.add('\n')
      pending.content.add(original)
    elif line.len == 0:
      flush()
    else:
      let heading = headingPrefix(line)
      let list = listPrefix(line)
      if heading > 0:
        flush()
        result.add(MessageBlock(kind: mbHeading, content: line[heading..^1]))
      elif list > 0:
        let kind = if line[0] in {'0'..'9'}: mbOrderedList else: mbList
        if hasPending and pending.kind != kind: flush()
        pending.kind = kind
        pending.items.add(line[list..^1])
        hasPending = true
      else:
        if hasPending and pending.kind != mbParagraph: flush()
        if pending.content.len > 0: pending.content.add('\n')
        pending.content.add(original)
        hasPending = true
  flush()

proc messageSpans*(source: string): seq[MessageSpan] =
  var plain = ""
  var index = 0
  while index < source.len:
    let delimiter =
      if source[index] == '`': "`"
      elif index + 1 < source.len and source[index..index + 1] == "**": "**"
      else: ""
    let finish = if delimiter.len > 0: source.find(delimiter, index + delimiter.len) else: -1
    if finish > index + delimiter.len:
      if plain.len > 0:
        result.add(MessageSpan(kind: msText, content: plain))
        plain = ""
      result.add(MessageSpan(kind: (if delimiter == "`": msCode else: msStrong),
        content: source[index + delimiter.len..<finish]))
      index = finish + delimiter.len
    else:
      plain.add(source[index])
      inc index
  if plain.len > 0: result.add(MessageSpan(kind: msText, content: plain))
