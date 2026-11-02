## The Skills page (FR-090): the owner's reusable guidance for the answers Janus writes.
##
## A skill is a SKILL.md file. The page lists the owner's skills with their
## current version and when each applies, writes a new one from a template or
## uploads a file, turns one off or on, restores an older version and deletes one
## after confirmation. The AI service checks every skill before it is saved.

include karax/prelude
import std/[asyncjs, json]

import ../app/types
import ../app/skills
import ../app/extension_bridge
import ../api/extensions

type
  SkillEditor = object
    open: bool
    draft, error: string
    busy: bool
    confirmDelete: string

var editor: SkillEditor


proc skillFileOutcome(): Future[cstring] {.importjs: """
(async () => {
  try {
    const f=document.getElementById('skillFile').files[0];
    if(!f) throw new Error('Choose a SKILL.md file.');
    if(f.size>40000) throw new Error('A skill file may hold at most 20000 characters.');
    let value;
    try { value=new TextDecoder('utf-8',{fatal:true}).decode(await f.arrayBuffer()); }
    catch { throw new Error('A skill file must be UTF-8 text.'); }
    return JSON.stringify({value});
  } catch(error) {
    return JSON.stringify({error: error && typeof error.message==='string' ? error.message : 'The skill file could not be read.'});
  }
})()
""".}


proc readSkillFile() {.async.} =
  try:
    let outcome = parseJson($(await skillFileOutcome()))
    if outcome.hasKey("error"):
      editor.error = outcome["error"].getStr
    else:
      editor.draft = outcome["value"].getStr
      editor.error = ""
  except CatchableError:
    editor.error = "The skill file could not be read."
  redraw(kxi)


proc sendSkill(state: AppState, action: string, payload: JsonNode, closeEditor = false) {.async.} =
  ## One skill change; the catalog is read again afterwards so the list shows the saved state.
  if editor.busy or not state.auth.authenticated: return
  editor.busy = true
  editor.error = ""
  redraw(kxi)
  try:
    discard await extensionRequest(action, payload, state.auth.csrfToken)
    if closeEditor:
      editor.open = false
      editor.draft = ""
    editor.confirmDelete = ""
  except CatchableError as exc:
    editor.error = exc.msg
  finally:
    editor.busy = false
  await refreshExtensions(state)


proc openEditor(text: string) =
  editor = SkillEditor(open: true, draft: text)


proc renderEditor(state: AppState): VNode =
  result = buildHtml(tdiv(class = "skill-editor")):
    label(`for` = "skillDraft", class = "review-label"): text "Skill file"
    textarea(id = "skillDraft", class = "skill-draft", rows = "12", spellcheck = "false",
             `aria-label` = "Skill file", value = cstring(editor.draft), disabled = editor.busy):
      proc oninput(event: Event, node: VNode) = editor.draft = $node.value
    tdiv(class = "skill-editor-actions"):
      label(class = "secondary-action skill-upload"):
        text "Upload SKILL.md"
        input(id = "skillFile", `type` = "file", accept = ".md,text/markdown,text/plain",
              class = "visually-hidden", disabled = editor.busy):
          proc onchange(event: Event, node: VNode) = discard readSkillFile()
      button(class = "secondary-action", disabled = editor.busy):
        text "Cancel"
        proc onclick(event: Event, node: VNode) =
          editor = SkillEditor()
      button(class = "plugin-primary", disabled = editor.busy):
        text (if editor.busy: "Saving…" else: "Save skill")
        proc onclick(event: Event, node: VNode) =
          let problem = skillFileProblem(editor.draft)
          if problem.len > 0:
            editor.error = problem
          else:
            discard sendSkill(state, "skill_save", %*{"text": editor.draft}, closeEditor = true)


proc renderRestore(state: AppState, version: SkillVersion): VNode =
  ## One restore button. Its own proc, so the click keeps this version's identity:
  ## closures made inside a loop would all share the loop's last value.
  result = buildHtml(button(class = "secondary-action", disabled = editor.busy,
                            `aria-label` = cstring("Restore version " & $version.version))):
    text "Restore v" & $version.version
    proc onclick(event: Event, node: VNode) =
      discard sendSkill(state, "skill_restore", %*{"id": version.id})


proc renderSkill(state: AppState, row: SavedSkill): VNode =
  result = buildHtml(article(class = "skill-row")):
    tdiv(class = "skill-heading"):
      strong(class = "skill-name"): text row.name
      span(class = "skill-meta"):
        text "Version " & $row.version & (if row.enabled: "" else: " · Off")
      label(class = "skill-toggle"):
        input(`type` = "checkbox", checked = row.enabled, disabled = editor.busy,
              `aria-label` = cstring("Use " & row.name)):
          proc onchange(event: Event, node: VNode) =
            discard sendSkill(state, "skill_enable", %*{"name": row.name, "enabled": not row.enabled})
        span: text "Use"
    if row.description.len > 0:
      p(class = "skill-meta"): text row.description
    p(class = "skill-meta"): text skillUse(row)
    tdiv(class = "skill-actions"):
      button(class = "secondary-action", disabled = editor.busy):
        text "Edit"
        proc onclick(event: Event, node: VNode) = openEditor(row.text)
      for version in row.versions:
        if version.version != row.version:
          renderRestore(state, version)
      if editor.confirmDelete == row.name:
        button(class = "secondary-action danger", disabled = editor.busy,
               `aria-label` = cstring("Delete " & row.name & " and its versions")):
          text "Delete " & row.name & " and its versions"
          proc onclick(event: Event, node: VNode) =
            discard sendSkill(state, "skill_delete", %*{"name": row.name})
        button(class = "secondary-action", disabled = editor.busy):
          text "Keep"
          proc onclick(event: Event, node: VNode) = editor.confirmDelete = ""
      else:
        button(class = "secondary-action", disabled = editor.busy):
          text "Delete"
          proc onclick(event: Event, node: VNode) = editor.confirmDelete = row.name


proc renderSkillsView*(state: AppState): VNode =
  let rows = catalogSkills(state.extensionCatalog)
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view skills-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2: text "Skills"
          p(class = "skills-note"):
            text "Your written guidance for answers, as SKILL.md files. A skill shapes how an answer " &
                 "is written, never which operation runs or what needs approval."
        if not editor.open:
          button(class = "plugin-primary"):
            text "New skill"
            proc onclick(event: Event, node: VNode) = openEditor(skillTemplate)
      if editor.error.len > 0:
        p(class = "operation-error", role = "alert"): text editor.error
      if editor.open:
        renderEditor(state)
      if rows.len == 0:
        p(class = "skills-empty"):
          text "No skills yet. Write one or upload a SKILL.md file; it applies when a request " &
               "mentions one of its triggers."
      for row in rows:
        renderSkill(state, row)
