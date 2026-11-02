## Answer actions that stay in the browser: copy an answer, export the open chat.
##
## Neither sends, saves nor stores anything: copying uses the clipboard and
## export builds a Markdown file the browser downloads.
import std/[strutils, tables]

include karax/prelude

import ../app/types
import brand

proc writeClipboard(text: cstring, done: proc(ok: bool)) {.importjs:
  "((t, cb) => navigator.clipboard.writeText(t).then(() => cb(true), () => cb(false)))(#, #)".}
proc downloadText(filename, text: cstring) {.importjs: """((name, body) => {
  const url = URL.createObjectURL(new Blob([body], {type: 'text/markdown;charset=utf-8'}));
  const link = document.createElement('a');
  link.href = url; link.download = name; link.rel = 'noopener';
  document.body.appendChild(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
})(#, #)""".}
proc later(callback: proc(), ms: int) {.importjs: "setTimeout(#, #)".}

var copied = initTable[int, bool]()  # Message id -> "Copied" shown briefly.

proc renderCopyAnswer*(message: ChatMessage): VNode =
  let id = message.id
  let done = copied.getOrDefault(id)
  result = buildHtml(button(class = "message-action", `aria-label` = cstring(if done: "Copied" else: "Copy answer"),
                            title = "Copy this answer")):
    text (if done: "Copied" else: "Copy")
    proc onclick(event: Event, node: VNode) =
      writeClipboard(cstring(message.content), proc(ok: bool) =
        if ok:
          copied[id] = true
          redraw(kxi)
          later(proc() =
            copied.del(id)
            redraw(kxi), 1600))

proc exportFilename*(title: string): string =
  ## A safe file name from the chat title: lowercase words joined by dashes.
  var words: seq[string]
  var word = ""
  for ch in title.toLowerAscii():
    if ch in {'a'..'z', '0'..'9'}: word.add ch
    elif word.len > 0:
      words.add word
      word = ""
  if word.len > 0: words.add word
  (if words.len > 0: words.join("-") else: "chat") & ".md"

proc chatMarkdown*(title: string, messages: openArray[ChatMessage]): string =
  result = "# " & (if title.len > 0: title else: "Chat") & "\n"
  for message in messages:
    if message.content.len == 0: continue
    let author = if message.role == mrUser: "You" else: productName
    result.add "\n**" & author & "**\n\n" & message.content.strip() & "\n"

proc exportChat*(title: string, messages: openArray[ChatMessage]) =
  downloadText(cstring(exportFilename(title)), cstring(chatMarkdown(title, messages)))
