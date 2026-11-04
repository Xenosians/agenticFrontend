# Package

version       = "0.1.0"
author        = "Xenosians"
description   = "Janus ITSM workspace frontend"
license       = "MIT"

srcDir        = "src"

# Browser application, and the capabilities documentation page beside it
bin           = @["agenticFrontend", "docs"]
backend       = "js"
binDir        = "public/js"

# Keep the generated browser bundle named app.js
namedBin["agenticFrontend"] = "app"


# Dependencies

requires "nim >= 2.2.10"
# Karax 1.5.0 plus upstream fa5fdef (karaxnim/karax#303, merged): without it every redraw
# leaks each button's old event handlers and, through them, a whole render tree.
requires "https://github.com/karaxnim/karax#fa5fdef42b3dd290880b3e4892e52385b892cfcb"

after build:
  exec "nim e --hints:off scripts/stamp_assets.nims"
