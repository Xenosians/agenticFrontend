# Agentic Frontend

Nim/Karax browser app for the Agentic Developer Hub and ITSM platform. It provides authenticated chat, durable job status, approval controls, structured results, and personal model/dataset connections.

> **Project status:** SRS 1.8 MVP candidate. The frontend represents durable server state and never treats an interrupted mutation decision as success.

## Features

- Registration, email verification, login, password reset, and session management.
- Saved chats and history, current-chat search, and a command palette with saved-chat navigation at every screen size.
- Live job updates over authenticated WebSockets, durable state recovery, explicit approve/reject decisions with saved action details, and structured result cards.
- Display of completed, failed, denied, and unknown-outcome jobs.
- Run inspector, activity view, and backend/AI integration status.
- A connections area for compatible model APIs, including Groq, installed local profiles, and available Pi/OpenCode harnesses.
- Per-account model selection, connection probes, local model folder uploads, reference datasets, and reviewed training-data exports.
- Provider usage settings for shared request/token queues and supported reasoning controls, editable without re-entering the saved API key.
- Responsive dark workspace, growing message input, keyboard commands, readable text/code results, and live task progress.

## How the repositories fit together

```text
agenticFrontend (this browser app)
    -> agenticBackend / itsm_backend (Phoenix API + SurrealDB)
        -> agenticaiPersonal / itsm-agent (inference and guarded tools)
```

The browser calls Phoenix only. Phoenix owns sessions, chats, jobs, and resource ownership; the AI runtime owns inference and guarded execution. Approval requests refer to a durable job, while the server retains the exact action and arguments.
The approval card displays that saved action before offering **Approve action** or **Reject action**. Both decisions go through Phoenix and remain disabled while their outcome is pending. An interrupted response requires reading the saved job again; the browser does not retry a mutation or assume a rejection succeeded. Completed decisions restore the saved tool result or rejection reason on reload.

Job observation uses Phoenix's read-only `job:<id>` channel. The browser obtains a short-lived token through the session/CSRF-protected `/api/v2/jobs/socket-token` endpoint and sends it in the WebSocket subprotocol, never in its URL. A join or `job_updated` event triggers an authorized `/api/v2/jobs/:id` read; socket messages cannot supply a result or execute an action. The client checks its account, chat, job, and observation generation before applying a response. Heartbeats and reconnects recover live updates, with polling while unavailable and periodic reads to catch missed events. Trusted `job_progress` stages describe work in progress; the saved job determines its outcome.

Assistant messages support headings, lists, emphasis, inline code, and fenced code through text nodes. Uploaded or generated HTML remains literal text. The composer stays available for drafting during a task; sending another task remains disabled until the current action is resolved.

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
  pollIntervalMs: 1000
});
```

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
- The networking specialist keeps its existing model and does not receive the additional private dataset context.

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
nim js -r tests/test_approval_result.nim
nim js -r tests/test_connection_options.nim
nim js -r tests/test_message_format.nim
nim js -r tests/test_request_context.nim
node --test tests/test_job_socket.js
```

These cover shortcuts, versioned lifecycle validation, job/history restoration, approval details and outcomes, stale decision responses, connection settings, safe message formatting, and the WebSocket protocol/reconnect lifecycle. They do not replace browser checks against running services. Check login/session restore, chat history, job completion, approve/reject decisions, and result rendering after changes to those flows.

## Current boundaries

- The composer allows one active job at a time. Closing the browser does not cancel its saved server task.
- WebSockets deliver progress and state-change notifications rather than a durable event log; reconnects recover the current saved job through HTTP.
- The node builder and simulator are design previews. n8n/workflow support is manifest validation only; it does not execute workflows or register webhooks.
- Reference retrieval has no embedding/vector-provider connector yet, and user datasets do not replace the application database.
- An unknown execution outcome requires server-side reconciliation; the UI does not automatically retry the mutation.
- Live provider availability depends on the configured backend and AI services. Deployment still requires correct origin, cookie, and service configuration across all three repositories.

## Source references

- [Runtime configuration](src/config/runtime_config.nim)
- [Backend client](src/api/client.nim) and [job lifecycle contract](src/api/job_lifecycle.nim)
- [Chat/job state bridge](src/app/backend_bridge.nim)
- [WebSocket observer](public/js/job_socket.js) and [safe message formatting](src/api/message_format.nim)
- [Model and dataset connections](src/components/connections.nim)
- [Extension requests](src/api/extensions.nim)
- [Workspace commands and shortcuts](src/app/commands.nim)
