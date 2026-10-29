# Agentic Frontend

Nim/Karax browser app for the Agentic Developer Hub and ITSM platform. It provides authenticated chat, durable job status, approval controls, structured results, and personal model/dataset connections.

## Features

- Registration, email verification, login, password reset, and session management.
- Account settings: read and save task completion email preferences, inspect sessions, and revoke other sessions while retaining the current one. Unconfirmed changes require refreshing saved state; the browser does not resend them automatically. Authentication, approval and failure notices stay independent.
- Separate workspace navigation rail and scrollable chat sidebar, with pinned conversations, date groups, filtering and rename controls. Untitled chats take their first saved request as a title; manual names are preserved.
- File/Edit/View/Help menus, saved-chat history, search across every saved chat, and keyboard commands at every screen size. Menu actions share the same navigation and permissions as the rest of the app.
- Live job status and AI progress over authenticated WebSockets, with reconnect recovery and polling fallback.
- Durable submission identities prevent duplicate jobs when an acknowledgement is lost; the same request can be recovered after reopening its chat.
- The optional acceptance-only Required operations editor pins capabilities, exact targets and supported success dependencies to a saved request. It is hidden in the normal composer; tool selection and approvals still work normally.
- Explicit approve/reject decisions bound to the displayed saved action, separate approval for each workflow step, and structured result cards.
- Safe formatting for headings, lists and code, responsive navigation, keyboard shortcuts, and drafting while a task runs.
- Display of completed, failed, denied, and unknown-outcome jobs.
- Feedback on any answer from a saved task: what was wrong and, optionally, the correct result, saved for review. A note that was not confirmed is kept and resent under the same identity.
- Review (administrators only): pending critiques and corrections with the request and answer they describe; each record gets one decision — accept or dismiss — with a reason. A refused decision is stated on the record, and a decision never changes the task.
- Knowledge: your ready reference datasets with version, digest, source and license, which one is used for your requests, and a search of one chosen source. Each passage is shown as untrusted reference text with its dataset, chunk and citation; searching never changes the selected dataset, and passages never grant permission or change routing.
- Cited answers: under an answer, the reference passages its model was given (kept with the chat, so they survive a reload). **Show passage** reopens that exact version for you only, quoted as untrusted reference text; a reply for another passage, version or trust level is refused.
- Lua row transforms (Data tab → Dataset → Transform rows with Lua, when the AI host supports them): a short Lua script maps each JSON line of the chosen file to a new row, or drops it. **Preview** shows the kept-row count, the first five rows and how the script was isolated, and stores nothing. **Apply and upload** appears only after a preview of the current script, and uploads the result through the same dataset checks as any upload. The script runs in the AI service's isolated worker, never in the browser.
- Learning (command palette → Learning readiness): choose SFT, DPO or PPO, a role, LoRA/QLoRA/full adaptation, one of your models and a current training dataset version, then check readiness. The answer lists every gate that still blocks a candidate run. A ready check (SFT with LoRA/QLoRA on your local weights) offers **Start candidate run**: one run trains at a time on the host, and its progress, losses and outcome update by themselves while it trains. You can cancel your active run. A finished candidate shows its digest and is never served or promoted from here.
- Automation (command palette → Automation workflows): draw a workflow from registered capabilities on a canvas, give each step its exact targets and an optional "after the previous step succeeds" dependency, then save it as a version. A run uses the saved version, becomes one ordinary job in its own chat, and asks for approval before any change. An unconfirmed run stays locked in the browser; only an explicit retry sends that same run again, so it is never duplicated.
- PCB / Infrastructure Simulator (rail, or command palette → Infrastructure topology and drift / PCB netlist inspection): draw the desired topology of containers, endpoints and router interfaces with the properties you expect, save it as a version, then check that exact version for drift. The report is a labelled simulated comparison against what the read tools observe; each source reports its own failure, and nothing is ever changed. The PCB tab inspects a KiCad netlist export for connectivity findings; nothing is fabricated or flashed.
- Run inspector, owner-scoped Operations queue and recorded inference timings, and backend/AI integration status.
- A Capabilities page listing every governed operation by specialist, with its effect, approval need and its provider's setup state (Configured, Simulated, Needs setup with the missing setting names). Setup comes from the AI service's configuration and is labelled as such; it is not a provider check.
- A connections area for compatible model APIs, including Groq, installed local profiles, and available Pi/OpenCode harnesses.
- Per-account model selection, connection probes, local model folder uploads, reference datasets, and reviewed training-data exports.
- Dataset versions: a changed dataset is uploaded as a new version of the latest one (**Upload as**). Each dataset shows its version and digest prefix, a replaced version says which version replaced it, and versions of one dataset are named with their version number.
- Provider usage settings for shared request/token queues and supported reasoning controls, editable without re-entering the saved API key.

## How the repositories fit together

```text
agenticFrontend (this browser app)
    -> agenticBackend / itsm_backend (Phoenix API + SurrealDB)
        -> agenticaiPersonal / itsm-agent (inference and guarded tools)
```

The browser calls Phoenix only. Phoenix owns sessions, chats, jobs, and resource ownership; the AI runtime owns inference and guarded execution. Approval requests refer to a durable job, while the server retains the exact action and arguments.
The approval card displays that saved action before offering **Approve action** or **Reject action**. Both decisions go through Phoenix and remain disabled while their outcome is pending. An interrupted response requires reading the saved job again; the browser does not retry a mutation or assume a rejection succeeded. Completed decisions restore the saved tool result or rejection reason on reload.

Before creating a job, the browser pins its submission UUID and request text in this tab's session storage, scoped to the backend, account and chat. It removes that temporary record after the exact submission is acknowledged, or on explicit sign-out. If the acknowledgement is interrupted, **Check saved submission** and reopening the chat use the same identity. Phoenix atomically creates one job for that owner and identity and rejects a changed chat or message. Recovering a submission does not replay its tools or reset its existing job state. Browser storage and secure UUID generation must be available before a new request can be sent.

For acceptance testing that needs exact reviewed operations, explicitly set `AGENTIC_CONFIG.requiredOperations: true`; the editor then appears above the composer. Other values leave it hidden. Choose registered capabilities, optionally enter exact target values and a supported success dependency. Success dependencies currently support one pair; unsupported graphs are rejected by the servers. The original selection remains bound to the submission and is recovered unchanged after a lost acknowledgement. It never grants permission or approves an action. The Operations view restores any saved operation list from the current job.

Rename and pin changes are shown as saved only after the server confirms the exact chat and submitted values. If a response is interrupted, **Refresh chats** reads the saved state before another metadata change is allowed. Pinning, renaming and filtering do not dispatch AI jobs.

## Stack

Nim `>= 2.2.10`, Karax `1.5.0`, and static HTML/CSS/JavaScript. Nim compiles [src/agenticFrontend.nim](src/agenticFrontend.nim) to `public/js/app.js`.

## Build and run

Install Nim/Nimble and run from this repository:

```bash
nimble install -d
nimble build
```

Set the public runtime values in [public/config.js](public/config.js):

```javascript
window.AGENTIC_CONFIG = Object.freeze({
  backendBaseUrl: "http://127.0.0.1:4000",
  pollIntervalMs: 1000,
  healthIntervalMs: 30000
});
```

`healthIntervalMs` is optional: it sets how often the status bar re-reads public service health. Without it, health is read at sign-in and on an explicit refresh.

Serve the `public` directory, for example:

```bash
python -m http.server 8080 -d public
```

Open `http://127.0.0.1:8080`. Phoenix must be running with a matching allowed frontend origin and cookie policy. The AI service must be running for chat execution and connection management. Backend registration/verification requires its configured mail transport; the local development mailbox is available at `http://127.0.0.1:4000/dev/mailbox` when enabled.

The generated `public/js/app.js` is tracked. Rebuild it when changing Nim source.
`nimble build` also stamps the JavaScript, runtime configuration and stylesheet URLs with their content hashes, so browsers fetch changed assets. After compiling the bundle directly, run `nim e scripts/stamp_assets.nims` before serving or deploying it.

## Models and datasets

Open connections with **Ctrl/Cmd+,**, or use the command palette with **Ctrl/Cmd+K**.
Open saved chats with the header's **Chats** button or **Ctrl/Cmd+Alt+C**. Reopening a conversation checks its outstanding saved job with the server before showing approval controls.

- Local models are the default. Selecting another model applies to future requests for your account.
- Hosted APIs need valid provider access, credentials, and quota. A saved connection does not by itself prove connectivity; use its probe and then test the intended task.
- Pi and OpenCode are available only when installed on the AI host. They supply inference while application tools remain governed by server policy and approvals.
- Local model uploads accept supported safetensors folders. The AI service validates their format; this does not guarantee model quality or enough GPU memory.
- Reference uploads use local full-text retrieval. Training JSONL requires provenance and review; exporting/importing data does not start training or promote a model.
- Networking uses the existing dedicated model by default. Each saved model's **Settings** can explicitly choose **Use this connection for networking**, including local and uploaded models. For an external connection, networking requests and device details go to that provider. Private datasets remain excluded from networking in either mode.

The AI repository's `docs/user-extensions.md` documents formats, limits, storage, and configuration. The frontend uses authenticated `/api/v1/extensions` requests; credentials are stored server-side and omitted from returned catalogs.

## Tests

With Node.js available for Nim's JavaScript test runner:

```bash
nim js -r tests/test_commands.nim
nim js -r tests/test_job_lifecycle.nim
nim js -r tests/test_chat_history.nim
nim js -r tests/test_chat_projection.nim
nim js -r tests/test_job_status.nim
nim js -r tests/test_tool_proposal.nim
nim js -r tests/test_job_decision.nim
nim js -r tests/test_job_feedback.nim
nim js -r tests/test_feedback_review.nim
nim js -r tests/test_knowledge.nim
nim js -r tests/test_learning.nim
nim js -r tests/test_workflows.nim
nim js -r tests/test_engineering.nim
nim js -r tests/test_answer_references.nim
nim js -r tests/test_lua_transforms.nim
nim js -r tests/test_integration_setup.nim
nim js -r tests/test_dataset_versions.nim
nim js -r tests/test_approval_result.nim
nim js -r tests/test_connection_options.nim
nim js -r tests/test_logout_outcome.nim
nim js -r tests/test_workflow_request.nim
nim js -o:.runtime/job_submission_client_driver.js tests/job_submission_client_driver.nim
nim js -o:.runtime/job_submission_flow_driver.js tests/job_submission_flow_driver.nim
node --test tests/test_job_submission.js tests/test_job_submission_client.js tests/test_job_submission_flow.js tests/test_job_socket.js
```

Sign-out clears the workspace only after Phoenix confirms that the session ended (401 means it already had). If the answer is lost or the server cannot confirm revocation, the user stays signed in and is asked to sign out again.

These cover shortcuts, versioned lifecycle validation, job/history restoration, approval details and outcomes, stale decision responses, and connection settings. They do not replace browser checks against running services. Check login/session restore, chat history, job completion, approve/reject decisions, and result rendering after changes to those flows.

After rebuilding, the isolated browser navigation regression can run with Python,
Playwright and its Chromium browser installed:

```bash
python tests/test_chat_navigation.py
python tests/test_job_feedback.py
python tests/test_feedback_review.py
python tests/test_knowledge.py
python tests/test_learning.py
python tests/test_workflows.py
python tests/test_engineering.py
python tests/test_answer_references.py
python tests/test_lua_transforms.py
python tests/test_workspace_navigation.py
python tests/test_connection_actions.py
```

It delays chat-history responses to verify that clicking Send or pressing Enter
cannot submit into the previous chat, keeps the draft, and preserves recovery of
the original submission identity and reviewed required operations. It also checks
the metadata picker, exact targets, dependencies and chat draft isolation. It serves the built frontend on a temporary
loopback port and uses test-only API fixtures; it needs no app credentials or live
providers and does not certify provider execution.

Workspace and connection browser tests also check each displayed row's exact
chat, session, provider or resource target, and keyboard command focus. They
intercept all API requests with isolated fixtures and never revoke real sessions,
delete real chats or admit a live provider connection.

## Current boundaries

- The composer allows one active job at a time. A reconnect reads saved server state and never repeats inference, a tool, or an approval.
- Operations shows an owner-scoped snapshot of all task status counts and the most recent 25 tasks. Refresh loads a new snapshot. Queue wait is submission to the current worker claim; task elapsed includes approval waits. Recorded inference calls show measured durations and available token counts for the current attempt only. Missing historical measurements say **Not recorded**, and truncated call lists are labelled. Call times may overlap; they are not a task's wall-clock total.
- WebSockets carry progress and status notifications; creation and approval stay on the authenticated REST API.
- The node builder and simulator are design previews. n8n/workflow support is manifest validation only; it does not execute workflows or register webhooks.
- Reference retrieval has no embedding/vector-provider connector yet, and user datasets do not replace the application database.
- An unknown execution outcome requires server-side reconciliation; the UI does not automatically retry the mutation.
- Live provider availability depends on the configured backend and AI services. Deployment still requires correct origin, cookie, and service configuration across all three repositories.

## Source references

- [Runtime configuration](src/config/runtime_config.nim)
- [Backend client](src/api/client.nim) and [job lifecycle contract](src/api/job_lifecycle.nim)
- [Chat/job state bridge](src/app/backend_bridge.nim)
- [WebSocket observer](public/js/job_socket.js)
- [Model and dataset connections](src/components/connections.nim)
- [Extension requests](src/api/extensions.nim)
- [Workspace commands and shortcuts](src/app/commands.nim)
