## Workspace appearance: the owner's theme and accent.
##
## The choices are a fixed list that the backend validates as well, so a value
## from the server or the page is applied only when it is one of them. The
## stylesheet defines every theme and accent; this module only names them.
import std/options
export options

type
  ThemeMode* = enum
    themeDark, themeLight, themeSystem

  Accent* = enum
    accentMono, accentBlue, accentTeal, accentGreen, accentAmber, accentRose, accentViolet

const
  themeValues: array[ThemeMode, string] = ["dark", "light", "system"]
  themeLabels: array[ThemeMode, string] = ["Dark", "Light", "Match system"]
  accentValues: array[Accent, string] = ["mono", "blue", "teal", "green", "amber", "rose", "violet"]
  accentLabels: array[Accent, string] = ["Monochrome", "Blue", "Teal", "Green", "Amber", "Rose", "Violet"]

proc themeValue*(mode: ThemeMode): string = themeValues[mode]
proc themeLabel*(mode: ThemeMode): string = themeLabels[mode]
proc accentValue*(accent: Accent): string = accentValues[accent]
proc accentLabel*(accent: Accent): string = accentLabels[accent]

proc parseThemeMode*(value: string): Option[ThemeMode] =
  for mode in ThemeMode:
    if themeValues[mode] == value: return some(mode)
  none(ThemeMode)

proc parseAccent*(value: string): Option[Accent] =
  for accent in Accent:
    if accentValues[accent] == value: return some(accent)
  none(Accent)

proc resolvedTheme*(mode: ThemeMode, systemPrefersLight: bool): string =
  ## The theme the stylesheet renders: "Match system" follows the OS setting.
  case mode
  of themeDark: "dark"
  of themeLight: "light"
  of themeSystem: (if systemPrefersLight: "light" else: "dark")
