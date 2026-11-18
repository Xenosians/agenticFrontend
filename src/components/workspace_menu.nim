include karax/prelude
import std/strutils
import ../app/commands
import icons
import brand

type MenuAction = object
  action, label: string
  keys: seq[string]

proc menuActions(menu: string): seq[MenuAction] =
  case menu
  of "File":
    @[MenuAction(action: "new_chat", label: "New chat", keys: @["Mod", "Alt", "N"]),
      MenuAction(action: "chats", label: "Recent chats"),
      MenuAction(action: "connections", label: "Model Store: models and datasets")]
  of "Edit":
    @[MenuAction(action: "compose", label: "Focus message"),
      MenuAction(action: "search", label: "Search chats", keys: @["Mod", "Shift", "F"])]
  of "View":
    @[MenuAction(action: "compose", label: "Chat"),
      MenuAction(action: "palette", label: "Commands", keys: @paletteKeys),
      MenuAction(action: "tools", label: "Store: Tools"),
      MenuAction(action: "skills", label: "Store: Skill Library"),
      MenuAction(action: "plugins", label: "Store: Plugin Store"),
      MenuAction(action: "automation", label: "Automation"),
      MenuAction(action: "engineering", label: "Topology & PCB"),
      MenuAction(action: "knowledge", label: "Knowledge"),
      MenuAction(action: "operations", label: "Operations"),
      MenuAction(action: "learning", label: "Learning"),
      MenuAction(action: "inspector", label: "Run inspector", keys: @["Mod", "Alt", "I"]),
      MenuAction(action: "settings", label: "Settings")]
  of "Help":
    @[MenuAction(action: "help", label: "Keyboard shortcuts and help"),
      MenuAction(action: "docs", label: "Capabilities documentation")]
  else: @[]

proc renderMenuAction(item: MenuAction, onAction: proc(action: string)): VNode =
  result = buildHtml(button(class = "workspace-menu-item", role = "menuitem", tabindex = "-1", `aria-label` = cstring(item.label))):
    span: text item.label
    if item.keys.len > 0:
      kbd: text shortcutText(item.keys)
    proc onclick(event: Event, node: VNode) = onAction(item.action)

proc renderMenu(menu, openMenu: string, onToggle: proc(menu: string),
                onAction: proc(action: string)): VNode =
  let opened = menu == openMenu
  result = buildHtml(tdiv(class = "workspace-menu")):
    button(id = cstring("menu" & menu), class = "workspace-menu-trigger", role = "menuitem",
           `aria-haspopup` = "menu", `aria-expanded` = cstring($opened),
           `aria-controls` = cstring("menuPopup" & menu)):
      text menu
      proc onclick(event: Event, node: VNode) = onToggle(menu)
    if opened:
      tdiv(id = cstring("menuPopup" & menu), class = "workspace-menu-popup", role = "menu",
           `aria-label` = cstring(menu)):
        for item in menuActions(menu):
          renderMenuAction(item, onAction)

proc renderWorkspaceMenubar*(openMenu: string, onToggle: proc(menu: string),
                             onAction: proc(action: string)): VNode =
  result = buildHtml(nav(class = "workspace-menubar", role = "menubar", `aria-label` = "Application menu")):
    for menu in ["File", "Edit", "View", "Help"]:
      renderMenu(menu, openMenu, onToggle, onAction)

proc renderTitlebar*(openMenu: string, sidebarCollapsed, inspectorOpen: bool,
                     onToggle: proc(menu: string), onAction: proc(action: string)): VNode =
  ## The slim title bar (owner decision of 19 November, after the Hermes desktop): the sidebar
  ## toggle and the application menus on the left, one centred search pill that opens the command
  ## palette, and the panel toggle on the right.
  let paletteLabel = shortcutText(paletteKeys)
  result = buildHtml(header(class = "titlebar")):
    tdiv(class = "titlebar-start"):
      button(class = "titlebar-button", id = "sidebarToggle",
             `aria-label` = (if sidebarCollapsed: cstring"Show sidebar" else: cstring"Hide sidebar"),
             title = (if sidebarCollapsed: cstring"Show sidebar" else: cstring"Hide sidebar"),
             `aria-expanded` = cstring($(not sidebarCollapsed))):
        icon("panel-left", 16)
        proc onclick(event: Event, node: VNode) = onAction("sidebar")
      tdiv(class = "titlebar-brand"):
        img(class = "brand-logo", src = productMark, alt = "")
        strong(class = "titlebar-product"): text productName
      renderWorkspaceMenubar(openMenu, onToggle, onAction)
    button(class = "titlebar-search", id = "commandPaletteButton", `aria-label` = "Search and commands",
           title = cstring("Search chats and commands (" & paletteLabel & ")"),
           `aria-keyshortcuts` = cstring(paletteLabel.replace("Ctrl", "Control"))):
      icon("search", 14)
      span(class = "titlebar-search-label"): text "Search"
      kbd(`aria-hidden` = "true"): text paletteLabel
      proc onclick(event: Event, node: VNode) = onAction("palette")
    tdiv(class = "titlebar-end"):
      button(class = "titlebar-button titlebar-inspector", `aria-label` = "Run inspector",
             `aria-pressed` = cstring($inspectorOpen),
             title = cstring("Run inspector (" & shortcutText(["Mod", "Alt", "I"]) & ")")):
        icon("panel", 16)
        proc onclick(event: Event, node: VNode) = onAction("inspector")

proc installMenuInteractions*(onClose: proc(focusId: cstring)) {.
  importjs: """((close) => {
    document.addEventListener('pointerdown', e => {
      if (!e.target.closest('.workspace-menubar')) close('');
    });
    document.addEventListener('keydown', e => {
      if (e.isComposing || e.repeat) return;
      const trigger = e.target.closest('.workspace-menu-trigger');
      const popup = e.target.closest('.workspace-menu-popup');
      if (!trigger && !popup) return;
      const menu = e.target.closest('.workspace-menu');
      const opener = menu.querySelector('.workspace-menu-trigger');
      if (trigger && (e.key === 'Enter' || e.key === ' ')) {
        requestAnimationFrame(() => menu.querySelector('.workspace-menu-item')?.focus());
        return;
      }
      if (e.key === 'Tab') { close(''); return; }
      if (e.key === 'Escape') { e.preventDefault(); close(opener.id); return; }
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        e.preventDefault();
        const buttons = [...document.querySelectorAll('.workspace-menu-trigger')];
        const next = buttons[(buttons.indexOf(opener) + (e.key === 'ArrowRight' ? 1 : buttons.length - 1)) % buttons.length];
        const wasOpen = opener.getAttribute('aria-expanded') === 'true';
        if (wasOpen) next.click();
        next.focus();
        return;
      }
      if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return;
      e.preventDefault();
      if (trigger && trigger.getAttribute('aria-expanded') !== 'true') trigger.click();
      requestAnimationFrame(() => {
        const items = [...menu.querySelectorAll('.workspace-menu-item:not(:disabled)')];
        if (!items.length) return;
        const i = items.indexOf(document.activeElement);
        const next = e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 :
          i < 0 ? (e.key === 'ArrowUp' ? items.length - 1 : 0) :
          (i + (e.key === 'ArrowUp' ? items.length - 1 : 1)) % items.length;
        items[next].focus();
      });
    });
  })(#)"""
.}
