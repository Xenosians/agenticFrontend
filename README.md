# Agentic Frontend

Nim/Karax browser frontend for the Agentic Developer Hub.

The frontend is a state-driven browser client. It submits durable jobs to Phoenix, polls Phoenix for lifecycle changes, renders real AI responses, and presents approval actions for governed mutations.

> Development prototype. The browser is a UI boundary, not an authorization or execution boundary.

## Stack

- Nim `>= 2.2.10`
- Karax `1.5.0`
- JavaScript backend
- static HTML/CSS/JS
- Phoenix REST API

Build output:

```text
src/agenticFrontend.nim
  -> public/js/app.js
```

## Current capabilities

- Karax chat UI
- durable Phoenix job creation
- real `job_id` tracking
- `GET /api/v1/jobs/:id` polling
- lifecycle rendering for:
  - `submitting`
  - `pending`
  - `processing`
  - `waiting_approval`
  - `approving`
  - `completed`
  - `failed`
- real AI answer rendering
- chat-level approval action for governed mutations
- job-scoped approval request through Phoenix
- inspector/run events
- tool/plugin preview UI
- one active durable job at a time in the current composer flow

The real Phoenix-backed path is the primary request path. Local mock behavior must not run alongside the real backend request.

## Architecture

```text
User
  |
  v
Karax frontend
  |
  | POST /api/v1/jobs
  v
Phoenix
  |
  | durable job lifecycle
  v
SurrealDB

Phoenix
  |
  | internal dispatch
  v
AI / ToolGateway / governed providers
  |
  v
Phoenix durable result
  ^
  |
  | GET /api/v1/jobs/:id
Karax frontend
```

For approval-required actions:

```text
AI proposes governed mutation
  |
  v
Phoenix job -> waiting_approval
  |
  v
Karax shows "Approve action"
  |
  | POST /api/v1/jobs/:job_id/approve
  v
Phoenix resolves trusted approval metadata
  |
  v
AI executes exact stored action
  |
  v
Phoenix job -> completed
  |
  v
Karax renders result
```

The browser submits the durable `job_id` only. It does not choose or submit the privileged `approval_id`.

## Public backend usage

The frontend currently targets:

```text
http://127.0.0.1:4000
```

Main calls:

```http
POST /api/v1/jobs
GET  /api/v1/jobs/:id
POST /api/v1/jobs/:id/approve
```

`src/api/client.nim` owns the current HTTP integration.

## Build

```bash
cd /mnt/c/project/agenticFrontend
nimble build
```

Karax unused-import warnings may be non-fatal depending on the current source state.

## Serve

```bash
python3 -m http.server 8080 -d public
```

Open:

```text
http://localhost:8080
```

## Main source layout

```text
src/
├── agenticFrontend.nim
├── api/
│   └── client.nim
├── app/
│   ├── backend_bridge.nim
│   ├── mock_agent.nim
│   ├── state.nim
│   └── types.nim
└── components/
    ├── brand.nim
    ├── chat.nim
    ├── composer.nim
    ├── inspector.nim
    └── sidebar.nim
```

Important runtime roles:

```text
client.nim
  HTTP create/get/approve calls

backend_bridge.nim
  maps Phoenix lifecycle into AppState

chat.nim
  renders conversation + approval action

composer.nim
  submission state and active-job gating

inspector.nim
  safe lifecycle/debug metadata
```

## Development rules

- keep application state driven through Karax VDOM
- avoid manual DOM mutation for application behavior
- frontend talks to Phoenix only
- frontend never calls FastAPI directly
- frontend never queries SurrealDB
- frontend never queries AI SQLite
- frontend never executes host shell directly
- visible controls should respond; unavailable controls should explain their preview state
- user-selected tools/plugins are preferences, never authorization
- do not expose internal model/tool implementation details as required frontend contracts

## Governed local execution

The browser can request developer operations, but execution remains server-side:

```text
Karax
  -> Phoenix
  -> AI proposes typed action
  -> ToolGateway validates
  -> governed process/provider execution
  -> Phoenix persists result
  -> Karax renders result
```

Current backend/AI work already supports governed read/mutation flows such as `pwd` and approval-gated directory creation. The browser approval path has been exercised end-to-end.

## Approval UX

When a job reaches:

```text
waiting_approval
```

the chat renders an approval action.

The frontend then calls:

```http
POST /api/v1/jobs/:job_id/approve
```

Expected successful lifecycle:

```text
waiting_approval
  -> approving
  -> completed
```

The frontend does not regenerate tool arguments and does not send a model-produced approval identifier back as authority.

## Known limitations

- backend base URL is currently hardcoded for local development
- polling is used instead of WebSocket/PubSub push
- one active job is intentionally enforced in the current composer path
- authentication is development-only
- plugin/tool cards are still largely preview UI
- some old mock/local-preview source may remain even though it must not be used on the real request path
- generated `public/js/app.js` is committed; the project should keep this policy consistent
- browser refresh/reconnect recovery is still limited by current conversation/history persistence

## Next useful capability

Expand the governed developer toolset with safe read-only operations before adding broader mutations.

A useful next read capability is directory listing, while preserving:

```text
typed request
-> deterministic policy
-> approved workspace
-> structured result
```

## Before commit

```text
[ ] nimble build succeeds
[ ] page loads
[ ] one durable job per submitted message
[ ] pending -> processing -> completed works
[ ] waiting_approval -> approve -> completed works
[ ] real AI result renders
[ ] no local mock answer appears on the real path
[ ] browser never sends approval_id as authority
```

See the project SRS for the cross-repository architecture.
