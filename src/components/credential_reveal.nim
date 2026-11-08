## Reveal an approved request's temporary password once, inside Janus.
##
## The new person's mailbox does not exist yet, so the person who asked for the
## account reads the temporary password here and hands it over. The backend
## checks the request owner and the user's own password, and shows it only
## once. The password stays in memory while this panel is open and is cleared
## when it closes; nothing is stored in the browser.

import std/[asyncjs, strutils, tables]

include karax/prelude

import karax/kdom

import ../api/client
import ../app/types

type
  HandoverDraft = object
    open, busy: bool
    password, revealed, subject, error, notice: string

var drafts = initTable[string, HandoverDraft]()

proc writeClipboard(value: cstring) {.importjs: "navigator.clipboard.writeText(#)".}


proc refusalText(message: string): string =
  ## Plain words for the backend's refusal codes.
  if "credential_already_revealed" in message:
    "This temporary password was already revealed. Reset the password with a new approved request if it was lost."
  elif "credential_expired" in message:
    "This temporary password has expired. Reset the password with a new approved request."
  elif "invalid_credentials" in message:
    "That is not your Janus password."
  elif "sign_in_rate_limited" in message:
    "Too many password attempts. Wait a few minutes and try again."
  elif "forbidden" in message or "credential_not_found" in message:
    "Only the person who asked for this request can reveal its temporary password."
  else:
    "The temporary password could not be revealed. " & message


proc reveal(state: AppState, key, jobId, credentialId: string) {.async.} =
  var draft = drafts.getOrDefault(key)
  if draft.busy or draft.password.len == 0:
    return
  draft.busy = true
  draft.error = ""
  drafts[key] = draft
  redraw(kxi)
  try:
    let revealed = await revealTemporaryCredential(jobId, credentialId, draft.password, state.auth.csrfToken)
    drafts[key] = HandoverDraft(open: true, revealed: revealed.password, subject: revealed.subject)
  except CatchableError as exc:
    var failed = drafts.getOrDefault(key)
    failed.busy = false
    failed.password = ""
    failed.error = refusalText(exc.msg)
    drafts[key] = failed
  redraw(kxi)


proc renderCredentialHandover*(state: AppState, jobId, credentialId: string): VNode =
  let key = jobId & "/" & credentialId
  let draft = drafts.getOrDefault(key)
  result = buildHtml(tdiv(class = "credential-handover")):
    if draft.revealed.len > 0:
      tdiv(class = "credential-handover-secret", role = "status"):
        p:
          text "Temporary password" & (if draft.subject.len > 0: " for " & draft.subject else: "") &
            ". It is shown only now; give it to the person, who must change it at first sign-in."
        code(class = "credential-handover-value"):
          text draft.revealed
        tdiv(class = "credential-handover-actions"):
          button(class = "credential-handover-copy"):
            text "Copy password"
            proc onclick(event: Event, node: VNode) =
              writeClipboard(cstring(drafts.getOrDefault(key).revealed))
              var copied = drafts.getOrDefault(key)
              copied.notice = "Copied."
              drafts[key] = copied
          button(class = "credential-handover-close"):
            text "Done"
            proc onclick(event: Event, node: VNode) =
              drafts[key] = HandoverDraft(notice: "Revealed once and closed.")
        if draft.notice.len > 0:
          p(class = "credential-handover-notice"):
            text draft.notice
    elif draft.notice.len > 0:
      p(class = "credential-handover-notice"):
        text draft.notice
    elif not draft.open:
      button(class = "credential-handover-toggle"):
        text "Reveal temporary password"
        proc onclick(event: Event, node: VNode) =
          var opened = drafts.getOrDefault(key)
          opened.open = true
          drafts[key] = opened
    else:
      form(class = "credential-handover-form"):
        p(class = "credential-handover-hint"):
          text "Confirm with your own Janus password. The temporary password can be revealed only once."
        label(class = "credential-handover-field"):
          span:
            text "Your Janus password"
          input(`type` = "password", autocomplete = "current-password", value = cstring(draft.password),
                disabled = draft.busy):
            proc oninput(event: Event, node: VNode) =
              var edited = drafts.getOrDefault(key)
              edited.password = $node.value
              drafts[key] = edited
        if draft.error.len > 0:
          p(class = "credential-handover-error", role = "alert"):
            text draft.error
        tdiv(class = "credential-handover-actions"):
          button(`type` = "submit", disabled = draft.busy or draft.password.len == 0):
            text (if draft.busy: "Revealing…" else: "Reveal")
          button(`type` = "button", class = "credential-handover-close", disabled = draft.busy):
            text "Cancel"
            proc onclick(event: Event, node: VNode) =
              drafts.del(key)
        proc onsubmit(event: Event, node: VNode) =
          event.preventDefault()
          discard reveal(state, key, jobId, credentialId)
