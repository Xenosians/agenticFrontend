import std/unittest
import ../src/app/types
import ../src/components/statusbar

suite "status bar labels":
  test "an unread health result is never reported as ready":
    check healthLabel(SystemState()) == "Services not checked"
    check healthLabel(SystemState(checking: true)) == "Checking services"
    # A re-read keeps showing the last answer instead of flickering to unknown.
    check healthLabel(SystemState(checking: true, checked: true, backendConnected: true,
                                  aiReachable: true, aiReady: true)) == "Services ready"
  test "each public health state has its own label":
    check healthLabel(SystemState(checked: true)) == "Backend unavailable"
    check healthLabel(SystemState(checked: true, backendConnected: true)) == "AI runtime unavailable"
    check healthLabel(SystemState(checked: true, backendConnected: true, aiReachable: true)) ==
      "AI runtime starting"
    check healthLabel(SystemState(checked: true, backendConnected: true, aiReachable: true,
                                  aiReady: true)) == "Services ready"
  test "only a job still being observed appears":
    check not observedJob(RunState())
    check not observedJob(RunState(active: true, jobId: "fixture-job"))
    check observedJob(RunState(active: true, jobId: "fixture-job", observationMode: "polling"))
    check observationLabel("interrupted") == "Connection interrupted"
    check observationLabel("") == "Checking saved progress"
