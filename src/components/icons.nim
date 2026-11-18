## Lucide line icons (owner decision of 18 November: real icons, not text glyphs).
##
## Lucide is ISC-licensed (https://lucide.dev, licence in public/fonts/../licenses/lucide.txt);
## these are its paths, unchanged, drawn as inline SVG so they inherit the text colour and
## need no extra request. Generated from lucide-static 0.468.0 by tmp/hermes (do not edit by hand).

include karax/prelude
import karax/vdom

type IconShape = tuple[tag: string, attrs: seq[(string, string)]]

const iconShapes: seq[(string, seq[IconShape])] = @[
  ("attach", @[("path", @[("d", "M13.234 20.252 21 12.3")]), ("path", @[("d", "m16 6-8.414 8.586a2 2 0 0 0 0 2.828 2 2 0 0 0 2.828 0l8.414-8.586a4 4 0 0 0 0-5.656 4 4 0 0 0-5.656 0l-8.415 8.585a6 6 0 1 0 8.486 8.486")])]),  # lucide paperclip
  ("automation", @[("rect", @[("width", "8"), ("height", "8"), ("x", "3"), ("y", "3"), ("rx", "2")]), ("path", @[("d", "M7 11v4a2 2 0 0 0 2 2h4")]), ("rect", @[("width", "8"), ("height", "8"), ("x", "13"), ("y", "13"), ("rx", "2")])]),  # lucide workflow
  ("back", @[("path", @[("d", "m12 19-7-7 7-7")]), ("path", @[("d", "M19 12H5")])]),  # lucide arrow-left
  ("chat", @[("path", @[("d", "M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z")])]),  # lucide message-square
  ("check", @[("path", @[("d", "M20 6 9 17l-5-5")])]),  # lucide check
  ("chevron-down", @[("path", @[("d", "m6 9 6 6 6-6")])]),  # lucide chevron-down
  ("chevron-right", @[("path", @[("d", "m9 18 6-6-6-6")])]),  # lucide chevron-right
  ("close", @[("path", @[("d", "M18 6 6 18")]), ("path", @[("d", "m6 6 12 12")])]),  # lucide x
  ("command", @[("path", @[("d", "M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3")])]),  # lucide command
  ("copy", @[("rect", @[("width", "14"), ("height", "14"), ("x", "8"), ("y", "8"), ("rx", "2"), ("ry", "2")]), ("path", @[("d", "M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2")])]),  # lucide copy
  ("database", @[("ellipse", @[("cx", "12"), ("cy", "5"), ("rx", "9"), ("ry", "3")]), ("path", @[("d", "M3 5V19A9 3 0 0 0 21 19V5")]), ("path", @[("d", "M3 12A9 3 0 0 0 21 12")])]),  # lucide database
  ("delete", @[("path", @[("d", "M3 6h18")]), ("path", @[("d", "M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6")]), ("path", @[("d", "M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2")]), ("line", @[]), ("line", @[])]),  # lucide trash-2
  ("download", @[("path", @[("d", "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4")]), ("polyline", @[("points", "7 10 12 15 17 10")]), ("line", @[])]),  # lucide download
  ("empty", @[("polyline", @[("points", "22 12 16 12 14 15 10 15 8 12 2 12")]), ("path", @[("d", "M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z")])]),  # lucide inbox
  ("enter", @[("polyline", @[("points", "9 10 4 15 9 20")]), ("path", @[("d", "M20 4v7a4 4 0 0 1-4 4H4")])]),  # lucide corner-down-left
  ("error", @[("circle", @[("cx", "12"), ("cy", "12"), ("r", "10")]), ("line", @[]), ("line", @[])]),  # lucide circle-alert
  ("history", @[("path", @[("d", "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8")]), ("path", @[("d", "M3 3v5h5")]), ("path", @[("d", "M12 7v5l4 2")])]),  # lucide history
  ("info", @[("circle", @[("cx", "12"), ("cy", "12"), ("r", "10")]), ("path", @[("d", "M12 16v-4")]), ("path", @[("d", "M12 8h.01")])]),  # lucide info
  ("knowledge", @[("path", @[("d", "M12 7v14")]), ("path", @[("d", "M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z")])]),  # lucide book-open
  ("learning", @[("path", @[("d", "M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z")]), ("path", @[("d", "M22 10v6")]), ("path", @[("d", "M6 12.5V16a6 3 0 0 0 12 0v-3.5")])]),  # lucide graduation-cap
  ("list", @[("path", @[("d", "M3 12h.01")]), ("path", @[("d", "M3 18h.01")]), ("path", @[("d", "M3 6h.01")]), ("path", @[("d", "M8 12h13")]), ("path", @[("d", "M8 18h13")]), ("path", @[("d", "M8 6h13")])]),  # lucide list
  ("loading", @[("path", @[("d", "M21 12a9 9 0 1 1-6.219-8.56")])]),  # lucide loader-circle
  ("model-store", @[("path", @[("d", "M2.97 12.92A2 2 0 0 0 2 14.63v3.24a2 2 0 0 0 .97 1.71l3 1.8a2 2 0 0 0 2.06 0L12 19v-5.5l-5-3-4.03 2.42Z")]), ("path", @[("d", "m7 16.5-4.74-2.85")]), ("path", @[("d", "m7 16.5 5-3")]), ("path", @[("d", "M7 16.5v5.17")]), ("path", @[("d", "M12 13.5V19l3.97 2.38a2 2 0 0 0 2.06 0l3-1.8a2 2 0 0 0 .97-1.71v-3.24a2 2 0 0 0-.97-1.71L17 10.5l-5 3Z")]), ("path", @[("d", "m17 16.5-5-3")]), ("path", @[("d", "m17 16.5 4.74-2.85")]), ("path", @[("d", "M17 16.5v5.17")]), ("path", @[("d", "M7.97 4.42A2 2 0 0 0 7 6.13v4.37l5 3 5-3V6.13a2 2 0 0 0-.97-1.71l-3-1.8a2 2 0 0 0-2.06 0l-3 1.8Z")]), ("path", @[("d", "M12 8 7.26 5.15")]), ("path", @[("d", "m12 8 4.74-2.85")]), ("path", @[("d", "M12 13.5V8")])]),  # lucide boxes
  ("more", @[("circle", @[("cx", "12"), ("cy", "12"), ("r", "1")]), ("circle", @[("cx", "19"), ("cy", "12"), ("r", "1")]), ("circle", @[("cx", "5"), ("cy", "12"), ("r", "1")])]),  # lucide ellipsis
  ("new-chat", @[("path", @[("d", "M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7")]), ("path", @[("d", "M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z")])]),  # lucide square-pen
  ("operations", @[("path", @[("d", "M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2")])]),  # lucide activity
  ("panel", @[("rect", @[("width", "18"), ("height", "18"), ("x", "3"), ("y", "3"), ("rx", "2")]), ("path", @[("d", "M15 3v18")])]),  # lucide panel-right
  ("panel-left", @[("rect", @[("width", "18"), ("height", "18"), ("x", "3"), ("y", "3"), ("rx", "2")]), ("path", @[("d", "M9 3v18")])]),  # lucide panel-left
  ("pin", @[("path", @[("d", "M12 17v5")]), ("path", @[("d", "M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z")])]),  # lucide pin
  ("plugins", @[("path", @[("d", "M15.39 4.39a1 1 0 0 0 1.68-.474 2.5 2.5 0 1 1 3.014 3.015 1 1 0 0 0-.474 1.68l1.683 1.682a2.414 2.414 0 0 1 0 3.414L19.61 15.39a1 1 0 0 1-1.68-.474 2.5 2.5 0 1 0-3.014 3.015 1 1 0 0 1 .474 1.68l-1.683 1.682a2.414 2.414 0 0 1-3.414 0L8.61 19.61a1 1 0 0 0-1.68.474 2.5 2.5 0 1 1-3.014-3.015 1 1 0 0 0 .474-1.68l-1.683-1.682a2.414 2.414 0 0 1 0-3.414L4.39 8.61a1 1 0 0 1 1.68.474 2.5 2.5 0 1 0 3.014-3.015 1 1 0 0 1-.474-1.68l1.683-1.682a2.414 2.414 0 0 1 3.414 0z")])]),  # lucide puzzle
  ("plus", @[("path", @[("d", "M5 12h14")]), ("path", @[("d", "M12 5v14")])]),  # lucide plus
  ("refresh", @[("path", @[("d", "M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8")]), ("path", @[("d", "M21 3v5h-5")]), ("path", @[("d", "M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16")]), ("path", @[("d", "M8 16H3v5")])]),  # lucide refresh-cw
  ("rename", @[("path", @[("d", "M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z")]), ("path", @[("d", "m15 5 4 4")])]),  # lucide pencil
  ("review", @[("path", @[("d", "M21.801 10A10 10 0 1 1 17 3.335")]), ("path", @[("d", "m9 11 3 3L22 4")])]),  # lucide circle-check-big
  ("search", @[("circle", @[("cx", "11"), ("cy", "11"), ("r", "8")]), ("path", @[("d", "m21 21-4.3-4.3")])]),  # lucide search
  ("send", @[("path", @[("d", "m5 12 7-7 7 7")]), ("path", @[("d", "M12 19V5")])]),  # lucide arrow-up
  ("server", @[("rect", @[("width", "20"), ("height", "8"), ("x", "2"), ("y", "2"), ("rx", "2"), ("ry", "2")]), ("rect", @[("width", "20"), ("height", "8"), ("x", "2"), ("y", "14"), ("rx", "2"), ("ry", "2")]), ("line", @[]), ("line", @[])]),  # lucide server
  ("settings", @[("path", @[("d", "M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z")]), ("circle", @[("cx", "12"), ("cy", "12"), ("r", "3")])]),  # lucide settings
  ("sign-out", @[("path", @[("d", "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4")]), ("polyline", @[("points", "16 17 21 12 16 7")]), ("line", @[])]),  # lucide log-out
  ("skills", @[("path", @[("d", "M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z")]), ("path", @[("d", "M20 3v4")]), ("path", @[("d", "M22 5h-4")]), ("path", @[("d", "M4 17v2")]), ("path", @[("d", "M5 18H3")])]),  # lucide sparkles
  ("store", @[("path", @[("d", "m2 7 4.41-4.41A2 2 0 0 1 7.83 2h8.34a2 2 0 0 1 1.42.59L22 7")]), ("path", @[("d", "M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8")]), ("path", @[("d", "M15 22v-4a2 2 0 0 0-2-2h-2a2 2 0 0 0-2 2v4")]), ("path", @[("d", "M2 7h20")]), ("path", @[("d", "M22 7v3a2 2 0 0 1-2 2a2.7 2.7 0 0 1-1.59-.63.7.7 0 0 0-.82 0A2.7 2.7 0 0 1 16 12a2.7 2.7 0 0 1-1.59-.63.7.7 0 0 0-.82 0A2.7 2.7 0 0 1 12 12a2.7 2.7 0 0 1-1.59-.63.7.7 0 0 0-.82 0A2.7 2.7 0 0 1 8 12a2.7 2.7 0 0 1-1.59-.63.7.7 0 0 0-.82 0A2.7 2.7 0 0 1 4 12a2 2 0 0 1-2-2V7")])]),  # lucide store
  ("success", @[("circle", @[("cx", "12"), ("cy", "12"), ("r", "10")]), ("path", @[("d", "m9 12 2 2 4-4")])]),  # lucide circle-check
  ("tools", @[("path", @[("d", "M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z")])]),  # lucide wrench
  ("topology", @[("rect", @[("x", "16"), ("y", "16"), ("width", "6"), ("height", "6"), ("rx", "1")]), ("rect", @[("x", "2"), ("y", "16"), ("width", "6"), ("height", "6"), ("rx", "1")]), ("rect", @[("x", "9"), ("y", "2"), ("width", "6"), ("height", "6"), ("rx", "1")]), ("path", @[("d", "M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3")]), ("path", @[("d", "M12 12V8")])]),  # lucide network
  ("unpin", @[("path", @[("d", "M12 17v5")]), ("path", @[("d", "M15 9.34V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H7.89")]), ("path", @[("d", "m2 2 20 20")]), ("path", @[("d", "M9 9v1.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h11")])]),  # lucide pin-off
  ("warning", @[("path", @[("d", "m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3")]), ("path", @[("d", "M12 9v4")]), ("path", @[("d", "M12 17h.01")])]),  # lucide triangle-alert
]

proc iconTag(tag: string): VNodeKind =
  case tag
  of "circle": VNodeKind.circle
  of "ellipse": VNodeKind.ellipse
  of "line": VNodeKind.line
  of "path": VNodeKind.path
  of "polyline": VNodeKind.polyline
  of "rect": VNodeKind.rect
  else: VNodeKind.path

proc icon*(name: string, size = 16, class = ""): VNode =
  ## One Lucide icon as inline SVG: decorative (the control it sits in carries the name),
  ## 2px strokes in the current text colour. An unknown name draws nothing visible.
  result = buildHtml(svg(class = cstring("icon icon-" & name & (if class.len > 0: " " & class else: "")),
                         xmlns = "http://www.w3.org/2000/svg", width = cstring($size), height = cstring($size),
                         viewBox = "0 0 24 24", fill = "none", stroke = "currentColor",
                         `stroke-width` = "2", `stroke-linecap` = "round", `stroke-linejoin` = "round",
                         `aria-hidden` = "true", focusable = "false"))
  for (key, shapes) in iconShapes:
    if key == name:
      for shape in shapes:
        let child = newVNode(iconTag(shape.tag))
        for (attribute, value) in shape.attrs:
          child.setAttr(cstring(attribute), cstring(value))
        result.add child
      return

proc iconNames*(): seq[string] =
  for (key, _) in iconShapes: result.add key
