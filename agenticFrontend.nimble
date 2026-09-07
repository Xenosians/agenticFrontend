# Package

version       = "0.1.0"
author        = "Xenosians"
description   = "Agentic AI / ITSM developer hub frontend"
license       = "MIT"

srcDir        = "src"

# Browser application
bin           = @["agenticFrontend"]
backend       = "js"
binDir        = "public/js"

# Keep the generated browser bundle named app.js
namedBin["agenticFrontend"] = "app"


# Dependencies

requires "nim >= 2.2.10"
requires "karax == 1.5.0"