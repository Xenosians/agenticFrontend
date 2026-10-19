proc statusTitle*(status: string): string =
  case status
  of "submitting": "Submitting"
  of "submission_unknown": "Submission not confirmed"
  of "restoring": "Checking saved job"
  of "pending": "Pending"
  of "processing": "Processing"
  of "approving": "Approving"
  of "rejecting": "Rejecting"
  of "completed": "Completed"
  of "failed": "Failed"
  of "denied": "Denied"
  of "waiting_approval": "Waiting approval"
  of "outcome_unknown", "reconciliation_required": "Outcome unresolved"
  else: "Idle"

proc statusDescription*(status: string): string =
  case status
  of "submitting": "Submitting the request to the backend"
  of "submission_unknown": "The acknowledgement was interrupted; recover the same saved request before submitting another"
  of "restoring": "Checking the authoritative saved job state"
  of "pending": "Waiting for backend dispatch"
  of "processing": "Agent is processing the request"
  of "approving": "Submitting explicit approval"
  of "rejecting": "Submitting your rejection; checking the saved decision"
  of "completed": "Run completed successfully"
  of "failed": "Run failed"
  of "denied": "The action did not proceed. See the saved response for the reason."
  of "waiting_approval": "User approval is required"
  of "outcome_unknown", "reconciliation_required":
    "Execution outcome unresolved; trusted reconciliation is required. Automatic retry is disabled."
  else: "No active run"

proc indicatorClass*(status: string): cstring =
  case status
  of "submitting", "restoring", "processing", "approving", "rejecting":
    cstring"status-indicator processing"
  of "completed": cstring"status-indicator completed"
  of "failed", "denied": cstring"status-indicator failed"
  of "waiting_approval": cstring"status-indicator waiting-approval"
  of "outcome_unknown", "reconciliation_required", "submission_unknown": cstring"status-indicator unresolved"
  else: cstring"status-indicator pending"
