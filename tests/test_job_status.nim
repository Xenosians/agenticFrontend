import std/[strutils, unittest]
import ../src/app/job_status

suite "durable job status presentation":
  test "denial is not idle or queued and does not mislabel human rejection as policy":
    check statusTitle("denied") == "Denied"
    check "saved response" in statusDescription("denied")
    check "policy" notin statusDescription("denied")
    check $indicatorClass("denied") == "status-indicator failed"
  test "unresolved execution is explicit and never suggests retrying":
    for status in ["outcome_unknown", "reconciliation_required"]:
      check statusTitle(status) == "Outcome unresolved"
      check "trusted reconciliation" in statusDescription(status)
      check "Automatic retry is disabled" in statusDescription(status)
      check $indicatorClass(status) == "status-indicator unresolved"
  test "restoration reports observation rather than execution":
    check statusTitle("restoring") == "Checking saved job"
    check "authoritative" in statusDescription("restoring")
