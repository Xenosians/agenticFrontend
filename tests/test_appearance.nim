import std/[json, unittest]
import ../src/app/[appearance, account_settings]

suite "workspace appearance":
  test "only the offered themes and accents are recognised":
    check parseThemeMode("dark") == some(themeDark)
    check parseThemeMode("light") == some(themeLight)
    check parseThemeMode("system") == some(themeSystem)
    check parseAccent("teal") == some(accentTeal)
    for value in ["", "Light", "blue-ish", "#ff0000", "url(x)"]:
      check parseThemeMode(value).isNone
    for value in ["", "Teal", "#00ffff", "red"]:
      check parseAccent(value).isNone

  test "every offered choice has a label and round-trips through its server value":
    for mode in ThemeMode:
      check themeLabel(mode).len > 0
      check parseThemeMode(themeValue(mode)) == some(mode)
    for accent in Accent:
      check accentLabel(accent).len > 0
      check parseAccent(accentValue(accent)) == some(accent)

  test "system mode follows the operating system preference":
    check resolvedTheme(themeSystem, systemPrefersLight = true) == "light"
    check resolvedTheme(themeSystem, systemPrefersLight = false) == "dark"
    check resolvedTheme(themeDark, systemPrefersLight = true) == "dark"
    check resolvedTheme(themeLight, systemPrefersLight = false) == "light"

suite "saved settings receipts":
  test "a receipt carries every setting the server owns":
    let saved = parseNotificationPreferences(%*{"preferences":
      {"task_completed": false, "theme": "light", "accent": "violet"}})
    check not saved.taskCompleted
    check saved.theme == themeLight
    check saved.accent == accentViolet

  test "an unknown appearance is refused, never replaced by a default":
    for preferences in [%*{"task_completed": true, "theme": "neon", "accent": "mono"},
                        %*{"task_completed": true, "theme": "dark", "accent": "#ff0000"},
                        %*{"task_completed": true, "accent": "mono"},
                        %*{"task_completed": true, "theme": "dark"}]:
      expect ValueError: discard parseNotificationPreferences(%*{"preferences": preferences})

suite "workspace dashboards":
  test "every dashboard has a label and round-trips through its saved value":
    for dashboard in Dashboard:
      check dashboardLabel(dashboard).len > 0
      check parseDashboard(dashboardValue(dashboard)) == some(dashboard)
    for value in ["", "Knowledge", "settings", "chat", "store"]:
      check parseDashboard(value).isNone
  test "pinning adds at the end and unpinning removes, once each":
    check togglePin(@[dashKnowledge, dashOperations], dashTopology) == @[dashKnowledge, dashOperations, dashTopology]
    check togglePin(@[dashKnowledge, dashOperations], dashKnowledge) == @[dashOperations]
    check togglePin(@[], dashLearning) == @[dashLearning]
