include karax/prelude

import ../app/types
import ../app/state


proc viewNavClass(
  state: AppState,
  target: AppView
): cstring =

  if state.activeView == target:
    cstring"nav-item active"
  else:
    cstring"nav-item"


proc toolNavClass(
  state: AppState,
  tool: ToolItem
): cstring =

  var value =
    "nav-item capability-nav-item"

  if not tool.enabled:
    value.add(
      " unavailable"
    )

  if state.activeView == viewTool and
     state.selectedToolId == tool.id:

    value.add(
      " active"
    )

  result =
    cstring(value)


proc pluginNavClass(
  state: AppState,
  plugin: PluginItem
): cstring =

  var value =
    "nav-item capability-nav-item"

  if not plugin.connected:
    value.add(
      " unavailable"
    )

  if state.activeView == viewPlugin and
     state.selectedPluginId == plugin.id:

    value.add(
      " active"
    )

  result =
    cstring(value)


proc renderViewButton(
  state: AppState,
  icon: string,
  label: string,
  target: AppView
): VNode =

  result = buildHtml(
    button(
      class =
        viewNavClass(
          state,
          target
        )
    )
  ):

    span(class = "nav-icon"):
      text icon

    span:
      text label

    proc onclick(
      event: Event,
      node: VNode
    ) =
      setActiveView(
        state,
        target
      )


proc renderToolButton(
  state: AppState,
  tool: ToolItem
): VNode =

  let
    dotClass =
      if tool.enabled:
        cstring"status-dot online"
      else:
        cstring"status-dot offline"

    displayName =
      if tool.id == "shell":
        ">_ " & tool.name
      else:
        tool.name


  result = buildHtml(
    button(
      class =
        toolNavClass(
          state,
          tool
        )
    )
  ):

    span(class = dotClass)

    span:
      text displayName

    span(class = "nav-tail"):
      text "›"

    proc onclick(
      event: Event,
      node: VNode
    ) =
      openToolView(
        state,
        tool.id
      )


proc renderPluginButton(
  state: AppState,
  plugin: PluginItem
): VNode =

  let dotClass =
    if plugin.connected:
      cstring"status-dot online"
    else:
      cstring"status-dot offline"


  result = buildHtml(
    button(
      class =
        pluginNavClass(
          state,
          plugin
        )
    )
  ):

    span(class = dotClass)

    span:
      text plugin.name

    span(class = "nav-tail"):
      text "›"

    proc onclick(
      event: Event,
      node: VNode
    ) =
      openPluginView(
        state,
        plugin.id
      )


proc renderSidebar*(
  state: AppState
): VNode =

  result = buildHtml(
    aside(class = "sidebar")
  ):

    tdiv(class = "brand"):

      img(
        class = "brand-logo",
        src = "./assets/hydra.svg",
        alt = "Agentic Hydra"
      )

      tdiv(class = "brand-copy"):

        strong:
          text "Agentic"

        span:
          text "Developer Hub"


    button(class = "new-session"):

      span:
        text "+"

      text "New Session"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        resetConversation(
          state
        )


    nav(class = "nav-section"):

      span(class = "section-label"):
        text "Workspace"

      renderViewButton(
        state,
        "◈",
        "Chat",
        viewChat
      )

      renderViewButton(
        state,
        "⌕",
        "Search",
        viewSearch
      )


    nav(class = "nav-section"):

      span(class = "section-label"):
        text "Tools"

      for tool in state.tools:
        renderToolButton(
          state,
          tool
        )


    nav(class = "nav-section"):

      span(class = "section-label"):
        text "Plugins"

      for plugin in state.plugins:
        renderPluginButton(
          state,
          plugin
        )

      button(
        class =
          viewNavClass(
            state,
            viewPlugin
          )
      ):

        span(class = "nav-icon"):
          text "+"

        span:
          text "Add plugin"

        proc onclick(
          event: Event,
          node: VNode
        ) =
          openPluginCatalog(
            state
          )


    nav(class = "nav-section"):

      span(class = "section-label"):
        text "Developer"

      renderViewButton(
        state,
        "▣",
        "Jobs",
        viewJobs
      )

      renderViewButton(
        state,
        "◌",
        "Runs",
        viewRuns
      )

      renderViewButton(
        state,
        "≡",
        "Logs",
        viewLogs
      )

      renderViewButton(
        state,
        "⚙",
        "System",
        viewSystem
      )


    button(class = "sidebar-footer"):

      tdiv(class = "avatar"):
        text "X"

      tdiv(class = "user-info"):

        strong:
          text "xenos"

        span:
          text "Developer · local preview"

      span(class = "nav-tail"):
        text "›"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        setActiveView(
          state,
          viewSystem
        )