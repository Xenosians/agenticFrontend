## Workspace appearance: the owner's theme, accent and pinned dashboards.
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

  Dashboard* = enum
    ## A view the owner may pin to the rail; the core views are always there.
    dashAutomation, dashTopology, dashKnowledge, dashOperations, dashLearning

const
  themeValues: array[ThemeMode, string] = ["dark", "light", "system"]
  themeLabels: array[ThemeMode, string] = ["Dark", "Light", "Match system"]
  accentValues: array[Accent, string] = ["mono", "blue", "teal", "green", "amber", "rose", "violet"]
  accentLabels: array[Accent, string] = ["Monochrome", "Blue", "Teal", "Green", "Amber", "Rose", "Violet"]
  dashboardValues: array[Dashboard, string] = ["automation", "topology", "knowledge", "operations", "learning"]
  dashboardLabels: array[Dashboard, string] = ["Automation", "Topology & PCB", "Knowledge", "Operations", "Learning"]
  dashboardIcons: array[Dashboard, string] = ["⌘", "▦", "❏", "◌", "◎"]
  ## Dashboards pinned until the owner chooses: the rail as it was before pinning.
  defaultPins* = @[dashKnowledge, dashOperations]

proc themeValue*(mode: ThemeMode): string = themeValues[mode]
proc themeLabel*(mode: ThemeMode): string = themeLabels[mode]
proc accentValue*(accent: Accent): string = accentValues[accent]
proc accentLabel*(accent: Accent): string = accentLabels[accent]
proc dashboardValue*(dashboard: Dashboard): string = dashboardValues[dashboard]
proc dashboardLabel*(dashboard: Dashboard): string = dashboardLabels[dashboard]
proc dashboardIcon*(dashboard: Dashboard): string = dashboardIcons[dashboard]

proc parseThemeMode*(value: string): Option[ThemeMode] =
  for mode in ThemeMode:
    if themeValues[mode] == value: return some(mode)
  none(ThemeMode)

proc parseAccent*(value: string): Option[Accent] =
  for accent in Accent:
    if accentValues[accent] == value: return some(accent)
  none(Accent)

proc parseDashboard*(value: string): Option[Dashboard] =
  for dashboard in Dashboard:
    if dashboardValues[dashboard] == value: return some(dashboard)
  none(Dashboard)

proc togglePin*(pins: seq[Dashboard], dashboard: Dashboard): seq[Dashboard] =
  ## Pinning adds the dashboard at the end of the rail; unpinning removes it.
  if dashboard in pins:
    for pin in pins:
      if pin != dashboard: result.add pin
  else:
    result = pins & dashboard

proc resolvedTheme*(mode: ThemeMode, systemPrefersLight: bool): string =
  ## The theme the stylesheet renders: "Match system" follows the OS setting.
  case mode
  of themeDark: "dark"
  of themeLight: "light"
  of themeSystem: (if systemPrefersLight: "light" else: "dark")
