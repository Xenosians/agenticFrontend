import std/strutils


type
  FrontendRuntimeConfig* = object
    backendBaseUrl*: string
    userId*: string
    pollIntervalMs*: int


# ============================================================
# JavaScript runtime configuration access
#
# IMPORTANT:
#
# Values crossing the importjs boundary use cstring rather than
# Nim string.
#
# Nim strings on the JavaScript backend are represented using
# Nim's own runtime structure. Injecting a Nim string directly
# into importjs can therefore produce an array of character
# codes instead of a native JavaScript string.
#
# cstring maps to a native JavaScript string and is appropriate
# for property lookup against AGENTIC_CONFIG.
# ============================================================


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


# ============================================================
# Normalization
# ============================================================


proc normalizeBaseUrl(
  value: string
): string =

  result =
    value.strip()


  while result.len > 0 and
        result[^1] == '/':

    result.setLen(
      result.len - 1
    )


# ============================================================
# Runtime configuration loading
# ============================================================


proc loadFrontendRuntimeConfig*():
  FrontendRuntimeConfig =

  if not hasConfigKey(
    cstring"backendBaseUrl"
  ):

    raise newException(
      ValueError,
      "Frontend runtime configuration is missing. " &
      "Load public/config.js before app.js."
    )


  if not hasConfigKey(
    cstring"userId"
  ):

    raise newException(
      ValueError,
      "AGENTIC_CONFIG.userId is missing."
    )


  if not hasConfigKey(
    cstring"pollIntervalMs"
  ):

    raise newException(
      ValueError,
      "AGENTIC_CONFIG.pollIntervalMs is missing."
    )


  let
    backendBaseUrl =
      normalizeBaseUrl(
        $configString(
          cstring"backendBaseUrl"
        )
      )

    userId =
      (
        $configString(
          cstring"userId"
        )
      ).strip()

    pollIntervalMs =
      configInteger(
        cstring"pollIntervalMs"
      )


  # ----------------------------------------------------------
  # Backend URL
  # ----------------------------------------------------------

  if backendBaseUrl.len == 0:

    raise newException(
      ValueError,
      "AGENTIC_CONFIG.backendBaseUrl must not be empty."
    )


  if not (
    backendBaseUrl.startsWith(
      "http://"
    ) or
    backendBaseUrl.startsWith(
      "https://"
    )
  ):

    raise newException(
      ValueError,
      "AGENTIC_CONFIG.backendBaseUrl must use http:// or https://."
    )


  # ----------------------------------------------------------
  # User identity
  # ----------------------------------------------------------

  if userId.len == 0:

    raise newException(
      ValueError,
      "AGENTIC_CONFIG.userId must not be empty."
    )


  # ----------------------------------------------------------
  # Poll interval
  # ----------------------------------------------------------

  if pollIntervalMs <= 0:

    raise newException(
      ValueError,
      "AGENTIC_CONFIG.pollIntervalMs must be greater than zero."
    )


  result =
    FrontendRuntimeConfig(
      backendBaseUrl:
        backendBaseUrl,

      userId:
        userId,

      pollIntervalMs:
        pollIntervalMs
    )


# ============================================================
# Application runtime configuration
#
# Loaded once when the compiled browser application starts.
# ============================================================


let
  frontendConfig* =
    loadFrontendRuntimeConfig()