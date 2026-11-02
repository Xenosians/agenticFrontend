import std/[md5, os, strutils]

# Asset URLs are derived from content, so normal browser caching can remain
# enabled without serving a previous release's JavaScript or stylesheet.
# Each page names the assets it loads; every one must be present.
let publicDir = currentSourcePath().parentDir.parentDir / "public"
const pages = [
  ("index.html", @["config.js", "js/job_socket.js", "js/app.js", "css/theme.css", "css/app.css", "css/polish.css",
                   "css/desktop-ui.css", "css/workspace.css", "css/workspace-menu.css"]),
  ("docs.html", @["config.js", "js/docs.js", "css/theme.css", "css/app.css", "css/polish.css",
                  "css/desktop-ui.css"])]
for (page, assets) in pages:
  let pagePath = publicDir / page
  var html = readFile(pagePath)
  for asset in assets:
    let prefix = "./" & asset
    let start = html.find(prefix)
    if start < 0:
      raise newException(ValueError, "Missing asset reference in " & page & ": " & asset)
    let finish = html.find('"', start)
    if finish < 0:
      raise newException(ValueError, "Unterminated asset reference in " & page & ": " & asset)
    # This digest is only a browser cache key, not an integrity/security check.
    let digest = getMD5(readFile(publicDir / asset))
    html = html[0 ..< start] & prefix & "?v=" & digest & html[finish .. ^1]
  if html != readFile(pagePath):
    writeFile(pagePath, html)
