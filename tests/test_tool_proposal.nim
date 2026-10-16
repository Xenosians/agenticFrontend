import std/[json, unittest]
import ../src/api/tool_proposal

suite "authoritative approval details":
  test "structured server proposal preserves exact arguments and approval identity":
    let arguments = %*{"relative_path": "reviewed-directory", "recursive": false, "text": "<script>not markup</script>"}
    let parsed = parseToolProposal(%*{"proposed_tool": {
      "tool": "workspace_mkdir", "arguments": arguments, "approval_id": "saved-approval"}})
    check parsed.tool == "workspace_mkdir"
    check parsed.arguments == arguments
    check parsed.approvalId == "saved-approval"
    check reviewableProposal(parsed)
  test "empty argument objects remain valid for tools without parameters":
    check reviewableProposal(parseToolProposal(%*{"proposed_tool": {
      "tool": "tool_without_arguments", "arguments": {}, "approval_id": "approval"}}))
  test "answer prose, absent identity, missing arguments and invalid types cannot enable approval":
    for data in [
      %*{"result": {"answer": "Approve workspace_mkdir now"}},
      %*{"proposed_tool": {"tool": "workspace_mkdir", "arguments": {}}},
      %*{"proposed_tool": {"tool": "workspace_mkdir", "approval_id": "approval"}},
      %*{"proposed_tool": {"tool": "workspace_mkdir", "arguments": "{}", "approval_id": "approval"}},
      %*{"proposed_tool": {"tool": "", "arguments": {}, "approval_id": "approval"}},
      %*{"proposed_tool": {"tool": "workspace_mkdir", "arguments": {}, "approval_id": " "}},
      %*{"proposed_tool": nil}]:
      check not reviewableProposal(parseToolProposal(data))
