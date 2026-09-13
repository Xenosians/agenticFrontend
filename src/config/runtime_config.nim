import std/strutils


type
  FrontendRuntimeConfig* = object
    backendBaseUrl*: string
    userId*: string
    pollIntervalMs*: int


# ============================================================
# JavaScript runtime configuration access
#
# importjs routines require a substitution pattern (#).
# Using the property name as the argument keeps the bridge
# explicit and avoids zero-argument importjs expressions.
# ============================================================


proc hasConfigKey(
  key: string
): bool {.
  importjs:
    "(typeof globalThis.AGENTIC_CONFIG === 'object' && globalThis.AGENTIC_CONFIG !== null && # in globalThis.AGENTIC_CONFIG)"
.}


proc configString(
  key: string
): string {.
  importjs:
    "String(globalThis.AGENTIC_CONFIG[#])"
.}


proc configInteger(
  key: string
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
    "backendBaseUrl"
  ):

    raise newException(
      ValueError,
      "Frontend runtime configuration is missing. " &
      "Load public/config.js before app.js."
    )


  if not hasConfigKey(
    "userId"
  ):

    raise newException(
      ValueError,
      "AGENTIC_CONFIG.userId is missing."
    )


  if not hasConfigKey(
    "pollIntervalMs"
  ):

    raise newException(
      ValueError,
      "AGENTIC_CONFIG.pollIntervalMs is missing."
    )


  let
    backendBaseUrl =
      normalizeBaseUrl(
        configString(
          "backendBaseUrl"
        )
      )

    userId =
      configString(
        "userId"
      ).strip()

    pollIntervalMs =
      configInteger(
        "pollIntervalMs"
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