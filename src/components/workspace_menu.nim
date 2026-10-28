include karax/prelude

type MenuAction = object
  action, label, shortcut: string

proc menuActions(menu: string): seq[MenuAction] =
  case menu
  of "File":
    @[MenuAction(action: "new_chat", label: "New chat", shortcut: "Ctrl/⌘ Alt N"),
      MenuAction(action: "chats", label: "Recent chats"),
      MenuAction(action: "connections", label: "Models and datasets")]
  of "Edit":
    @[MenuAction(action: "compose", label: "Focus message"),
      MenuAction(action: "search", label: "Search chats", shortcut: "Ctrl/⌘ Shift F")]
  of "View":
    @[MenuAction(action: "compose", label: "Chat"),
      MenuAction(action: "palette", label: "Commands", shortcut: "Ctrl/⌘ K"),
      MenuAction(action: "knowledge", label: "Knowledge"),
      MenuAction(action: "operations", label: "Operations"),
      MenuAction(action: "capabilities", label: "Capabilities"),
      MenuAction(action: "inspector", label: "Run inspector", shortcut: "Ctrl/⌘ Alt I"),
      MenuAction(action: "system", label: "System status")]
  of "Help":
    @[MenuAction(action: "help", label: "Keyboard shortcuts and help")]
  else: @[]

proc renderMenuAction(item: MenuAction, onAction: proc(action: string)): VNode =
  result = buildHtml(button(class = "workspace-menu-item", role = "menuitem", tabindex = "-1", `aria-label` = cstring(item.label))):
    span: text item.label
    if item.shortcut.len > 0:
      kbd: text item.shortcut
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
