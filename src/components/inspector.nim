import std/strutils

import ../app/types


proc escapeHtml(value: string): string =
  result = value
    .replace("&", "&amp;")
    .replace("<", "&lt;")
    .replace(">", "&gt;")
    .replace("\"", "&quot;")
    .replace("'", "&#39;")


proc displayValue(
  value: string,
  fallback: string
): string =
  if value.len == 0:
    fallback
  else:
    escapeHtml(value)


proc statusClass(status: string): string =
  case status
  of "pending":
    "pending"

  of "processing":
    "processing"

  of "completed":
    "completed"

  of "failed":
    "failed"

  of "waiting_approval":
    "waiting-approval"

  else:
    "pending"


proc statusTitle(status: string): string =
  case status
  of "pending":
    "Pending"

  of "processing":
    "Processing"

  of "completed":
    "Completed"

  of "failed":
    "Failed"

  of "waiting_approval":
    "Waiting approval"

  else:
    "Unknown"


proc statusDescription(status: string): string =
  case status
  of "pending":
    "Waiting for backend dispatch"

  of "processing":
    "Agent is processing the request"

  of "completed":
    "Run completed"

  of "failed":
    "Run failed"

  of "waiting_approval":
    "User approval is required"

  else:
    "Unknown run state"


proc renderInspector*(state: AppState): string =
  if not state.run.active:
    return """
      <div class="run-empty">

        <div class="run-empty-icon">
          ◌
        </div>

        <h3>
          No active run
        </h3>

        <p>
          Submit a request to inspect job state,
          routing, tool usage, and execution events.
        </p>

      </div>
    """

  let
    run = state.run

    currentStatusClass =
      statusClass(run.status)

    currentStatusTitle =
      statusTitle(run.status)

    currentStatusDescription =
      statusDescription(run.status)

    request =
      displayValue(
        run.request,
        "No request"
      )

    job =
      displayValue(
        run.jobId,
        "Local preview"
      )

    agent =
      displayValue(
        run.agent,
        "Not selected"
      )

    tool =
      displayValue(
        run.tool,
        "Not selected"
      )

  result = """
    <div class="run-details">

      <div class="run-status">

        <span
          class="status-indicator """ &
          currentStatusClass &
        """"
        ></span>

        <div>

          <strong>""" &
            currentStatusTitle &
          """</strong>

          <span>""" &
            currentStatusDescription &
          """</span>

        </div>

      </div>


      <div class="run-section">

        <span class="run-label">
          Request
        </span>

        <div class="run-value">""" &
          request &
        """</div>

      </div>


      <div class="run-section">

        <span class="run-label">
          Job
        </span>

        <div class="run-value">""" &
          job &
        """</div>

      </div>


      <div class="run-section">

        <span class="run-label">
          Agent
        </span>

        <div class="run-value">""" &
          agent &
        """</div>

      </div>


      <div class="run-section">

        <span class="run-label">
          Tool
        </span>

        <div class="run-value">""" &
          tool &
        """</div>

      </div>

    </div>
  """