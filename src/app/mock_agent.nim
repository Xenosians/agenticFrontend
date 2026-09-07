import std/strutils


type
  LocalAgentResult* = object
    agent*: string
    tool*: string
    response*: string


proc routeLocalRequest*(
  message: string
): LocalAgentResult =

  let normalized =
    message.toLowerAscii()


  if "account" in normalized or
     "user" in normalized or
     "locked" in normalized or
     "unlock" in normalized:

    return LocalAgentResult(
      agent: "Account Specialist",
      tool: "account_status",
      response:
        "I would route this request to the Account Specialist " &
        "and inspect the account state using the account tool."
    )


  if "access" in normalized or
     "permission" in normalized or
     "role" in normalized or
     "group" in normalized:

    return LocalAgentResult(
      agent: "Access Specialist",
      tool: "check_access",
      response:
        "I would route this request to the Access Specialist " &
        "and inspect the user's current access."
    )


  if "docker" in normalized or
     "shell" in normalized or
     "command" in normalized or
     "terminal" in normalized:

    return LocalAgentResult(
      agent: "Developer Specialist",
      tool: "shell",
      response:
        "This looks like a developer or shell request. " &
        "The final system will propose a governed shell operation " &
        "rather than executing raw model output directly."
    )


  if "git" in normalized or
     "repo" in normalized or
     "commit" in normalized or
     "branch" in normalized:

    return LocalAgentResult(
      agent: "Developer Specialist",
      tool: "git",
      response:
        "This looks like a Git-related request. " &
        "The developer agent would inspect repository state " &
        "through a controlled Git capability."
    )


  if "file" in normalized or
     "folder" in normalized or
     "directory" in normalized:

    return LocalAgentResult(
      agent: "Developer Specialist",
      tool: "files",
      response:
        "This looks like a filesystem request. " &
        "The final agent will use a governed file capability " &
        "with explicit read and mutation boundaries."
    )


  result = LocalAgentResult(
    agent: "General Agent",
    tool: "none",
    response:
      "I received the request. " &
      "No specialist tool is required by the local frontend router yet."
  )