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

type
  FeedbackDraft = object
    open, sending, saved: bool
    identity, note, correction, error: string

var drafts = initTable[string, FeedbackDraft]()


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


proc renderMessageFeedback*(state: AppState, jobId: string): VNode =
  let draft = drafts.getOrDefault(jobId)
  result = buildHtml(tdiv(class = "message-feedback")):
    if draft.saved:
      p(class = "message-feedback-status", role = "status"):
        text "Feedback saved for review."
    elif not draft.open:
      button(class = "message-feedback-toggle"):
        text "Give feedback"
        proc onclick(event: Event, node: VNode) =
          var opened = drafts.getOrDefault(jobId)
          opened.open = true
          drafts[jobId] = opened
    else:
      tdiv(class = "message-feedback-form"):
        label(class = "message-feedback-field"):
          span:
            text "What was wrong?"
          textarea(rows = "2", value = cstring(draft.note), disabled = draft.sending):
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
