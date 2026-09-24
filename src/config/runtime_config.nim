import std/strutils


type
  FrontendRuntimeConfig* = object
    backendBaseUrl*: string
    pollIntervalMs*: int


proc hasConfigKey(
  key: cstring
): bool {.
  importjs:
    "(typeof globalThis.AGENTIC_CONFIG === 'object' && globalThis.AGENTIC_CONFIG !== null && # in globalThis.AGENTIC_CONFIG)"
.}


proc configString(
  key: cstring
): cstring {.
  importjs:
    "String(globalThis.AGENTIC_CONFIG[#])"
.}


proc configInteger(
  key: cstring
): int {.
  importjs:
    "Number(globalThis.AGENTIC_CONFIG[#])"
.}


proc normalizeBaseUrl(
  value: string
): string =
  result = value.strip()

  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)


proc loadFrontendRuntimeConfig*(): FrontendRuntimeConfig =
  if not hasConfigKey(cstring"backendBaseUrl"):
    raise newException(
      ValueError,
      "Frontend runtime configuration is missing. Load public/config.js before app.js."
    )

  if not hasConfigKey(cstring"pollIntervalMs"):
    raise newException(
      ValueError,
      "AGENTIC_CONFIG.pollIntervalMs is missing."
    )

  let backendBaseUrl = normalizeBaseUrl(
    $configString(cstring"backendBaseUrl")
  )

  let pollIntervalMs = configInteger(cstring"pollIntervalMs")

  if backendBaseUrl.len == 0:
    raise newException(ValueError, "AGENTIC_CONFIG.backendBaseUrl must not be empty.")

  if not (
    backendBaseUrl.startsWith("http://") or
    backendBaseUrl.startsWith("https://")
  ):
    raise newException(
      ValueError,
      "AGENTIC_CONFIG.backendBaseUrl must use http:// or https://."
    )

  if pollIntervalMs <= 0:
    raise newException(
      ValueError,
      "AGENTIC_CONFIG.pollIntervalMs must be greater than zero."
    )

  result = FrontendRuntimeConfig(
    backendBaseUrl: backendBaseUrl,
    pollIntervalMs: pollIntervalMs
  )


let frontendConfig* = loadFrontendRuntimeConfig()
