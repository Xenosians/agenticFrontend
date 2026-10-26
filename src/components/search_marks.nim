## Where a search query occurs in a piece of text, for marking the matches.
##
## Pure and DOM-free so it can be unit-tested: the views split text into these
## spans and wrap the matched ones in <mark>.

import std/strutils

type
  MatchSpan* = object
    first*, len*: int   # byte range in the original text
    matched*: bool

proc matchSpans*(text, query: string): seq[MatchSpan] =
  ## Covers the whole text in order; matched spans are every occurrence of the
  ## query, ignoring case and the query's surrounding spaces.
  let needle = query.strip().toLowerAscii()
  if text.len == 0:
    return
  if needle.len == 0:
    return @[MatchSpan(first: 0, len: text.len)]
  let haystack = text.toLowerAscii()
  var position = 0
  while position < text.len:
    let found = haystack.find(needle, position)
    if found < 0:
      break
    if found > position:
      result.add MatchSpan(first: position, len: found - position)
    result.add MatchSpan(first: found, len: needle.len, matched: true)
    position = found + needle.len
  if position < text.len:
    result.add MatchSpan(first: position, len: text.len - position)

proc excerptAround*(text, query: string, lead = 40): string =
  ## One line that shows the match: when the first match starts more than
  ## `lead` bytes in, the text is cut at a word boundary shortly before it and
  ## marked "…" so the matched words fit inside a single-line result card.
  let needle = query.strip().toLowerAscii()
  if needle.len == 0:
    return text
  let found = text.toLowerAscii().find(needle)
  if found <= lead:
    return text
  var start = found - lead
  # Never start inside a word: move to the next word's first letter.
  while start < found and text[start - 1] notin Whitespace:
    inc start
  while start < found and text[start] in Whitespace:
    inc start
  "…" & text[start .. ^1]
