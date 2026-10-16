import std/[md5, os, strutils]

# Asset URLs are derived from content, so normal browser caching can remain
# enabled without serving a previous release's JavaScript or stylesheet.
let publicDir = currentSourcePath().parentDir.parentDir / "public"
let indexPath = publicDir / "index.html"
var html = readFile(indexPath)
for asset in ["config.js", "js/job_socket.js", "js/app.js", "css/app.css", "css/polish.css", "css/desktop-ui.css"]:
  let prefix = "./" & asset
  let start = html.find(prefix)
  if start < 0:
    raise newException(ValueError, "Missing asset reference: " & asset)
  let finish = html.find('"', start)
  if finish < 0:
    raise newException(ValueError, "Unterminated asset reference: " & asset)
  # This digest is only a browser cache key, not an integrity/security check.
  let digest = getMD5(readFile(publicDir / asset))
  html = html[0 ..< start] & prefix & "?v=" & digest & html[finish .. ^1]
if html != readFile(indexPath):
  writeFile(indexPath, html)
