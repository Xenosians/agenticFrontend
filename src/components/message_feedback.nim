## Feedback on an answer (FR-089), offered under each answer that came from a
## saved task.
##
## The note and optional correct result are saved by the backend for review,
## linked to the task's request, proposal and provenance. A note keeps one
## identity until it is saved, so sending it again after a lost response can
## never save it twice. Saving feedback changes nothing else.

import std/[asyncjs, strutils, tables]

include karax/prelude

import ../api/client
import ../app/job_feedback
import ../app/types
import icons

type
  FeedbackDraft = object
    open, sending, saved: bool
    identity, note, correction, error: string

var drafts = initTable[string, FeedbackDraft]()

# After a redraw: the opened form's first field, or the action row's button after Cancel. The element
# is found by the job's own id, so with several answers on screen the right one is focused; the form
# is scrolled fully into view (a phone shows little below the answer).
proc focusAfterRedraw(id: cstring, reveal: bool) {.importjs: """((id, reveal) => requestAnimationFrame(() =>
  requestAnimationFrame(() => {
    const target = document.getElementById(id);
    if (!target) return;
    target.focus({preventScroll: true});
    const form = reveal ? target.closest('.message-feedback-form') : null;
    (form || target).scrollIntoView({block: 'nearest'});
  })))(#, #)""".}

proc feedbackDomId(prefix, jobId: string): string =
  ## A DOM id from the job id: only letters, digits and dashes.
  result = prefix
  for ch in jobId:
    result.add(if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-'}: ch else: '-')


proc sendDraft(state: AppState, jobId: string) {.async.} =
  var draft = drafts.getOrDefault(jobId)
  if draft.sending or draft.note.strip().len == 0:
    return
  if draft.identity.len == 0:
    draft.identity = newFeedbackIdentity()
  draft.sending = true
  draft.error = ""
  drafts[jobId] = draft
  redraw(kxi)
  try:
    await sendJobFeedback(jobId, draft.identity, draft.note, draft.correction, state.auth.csrfToken)
    drafts[jobId] = FeedbackDraft(saved: true)
  except CatchableError as exc:
    var failed = drafts.getOrDefault(jobId)
    failed.sending = false
    failed.error = "Feedback was not saved. " & exc.msg
    drafts[jobId] = failed
  redraw(kxi)


proc feedbackToggleShown*(jobId: string): bool =
  ## The action row's feedback button shows until the form opens or the feedback is saved.
  let draft = drafts.getOrDefault(jobId)
  not (draft.saved or draft.open)


proc renderFeedbackToggle*(jobId: string): VNode =
  ## The small icon button in the answer's action row (Hermes); the form opens below the answer with
  ## its first field focused.
  result = buildHtml(button(id = cstring(feedbackDomId("feedback-toggle-", jobId)),
                            class = "message-action message-feedback-toggle", `aria-label` = "Give feedback",
                            title = "Give feedback on this answer")):
    icon("feedback", 14)
    proc onclick(event: Event, node: VNode) =
      var opened = drafts.getOrDefault(jobId)
      opened.open = true
      drafts[jobId] = opened
      focusAfterRedraw(cstring(feedbackDomId("feedback-note-", jobId)), true)


proc renderMessageFeedback*(state: AppState, jobId: string): VNode =
  ## Below the answer: the open form, or the saved note's status. The toggle sits in the action row.
  let draft = drafts.getOrDefault(jobId)
  result = buildHtml(tdiv(class = "message-feedback")):
    if draft.saved:
      p(class = "message-feedback-status", role = "status"):
        text "Feedback saved for review."
    elif draft.open:
      tdiv(class = "message-feedback-form"):
        label(class = "message-feedback-field"):
          span:
            text "What was wrong?"
          textarea(id = cstring(feedbackDomId("feedback-note-", jobId)), rows = "2", value = cstring(draft.note),
                   disabled = draft.sending):
            proc oninput(event: Event, node: VNode) =
              var edited = drafts.getOrDefault(jobId)
              edited.note = $node.value
              drafts[jobId] = edited
        label(class = "message-feedback-field"):
          span:
            text "Correct result (optional)"
          textarea(rows = "2", value = cstring(draft.correction), disabled = draft.sending):
            proc oninput(event: Event, node: VNode) =
              var edited = drafts.getOrDefault(jobId)
              edited.correction = $node.value
              drafts[jobId] = edited
        if draft.error.len > 0:
          p(class = "message-feedback-error", role = "alert"):
            text draft.error
        tdiv(class = "message-feedback-actions"):
          button(class = "approval-recovery-button",
                 disabled = draft.sending or draft.note.strip().len == 0):
            text (if draft.sending: "Sending…" else: "Send feedback")
            proc onclick(event: Event, node: VNode) =
              discard sendDraft(state, jobId)
          button(class = "approval-recovery-button message-feedback-cancel", disabled = draft.sending):
            text "Cancel"
            proc onclick(event: Event, node: VNode) =
              drafts.del(jobId)
              focusAfterRedraw(cstring(feedbackDomId("feedback-toggle-", jobId)), false)
