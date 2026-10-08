import std/[json, unittest]
import ../src/api/job_lifecycle
suite "versioned job lifecycle":
  test "known v2 states render only with explicit version":
    for status in publicJobStates:
      validateJobV2(%*{"contract_version": 2, "status": status})
  test "unknown versions, legacy and unrecognized states fail closed":
    for data in [%*{"status": "completed"}, %*{"contract_version": 3, "status": "completed"}, %*{"contract_version": 2, "status": "reconciliation_required"}, %*{"contract_version": 2, "status": "invented"}]:
      expect ValueError:
        validateJobV2(data)
