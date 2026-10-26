import std/[json, unittest]
import ../src/app/job_feedback

suite "feedback on a task's result":
  test "the request names the escaped task":
    check feedbackPath("job") == "/api/v1/jobs/job/feedback"
    check feedbackPath("job/other") == "/api/v1/jobs/job%2Fother/feedback"
    expect ValueError:
      discard feedbackPath("")

  test "a note is required and a blank correction is left out":
    check feedbackPayload("identity", "  It chose the wrong directory ", "  ") ==
      %*{"submission_id": "identity", "note": "It chose the wrong directory"}
    check feedbackPayload("identity", "Wrong", " Use reviewed/ ") ==
      %*{"submission_id": "identity", "note": "Wrong", "correction": "Use reviewed/"}
    for note in ["", "   "]:
      expect ValueError:
        discard feedbackPayload("identity", note, "Use reviewed/")
    expect ValueError:
      discard feedbackPayload("", "Wrong", "")
