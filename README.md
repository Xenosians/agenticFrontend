# Agentic Frontend

Nim/Karax browser frontend for the Agentic Developer Hub.

The UI creates durable jobs through Phoenix, polls Phoenix for job state, and renders the real AI result.

> Development prototype.

## Stack

- Nim `>= 2.2.10`
- Karax `1.5.0`
- JavaScript backend
- static HTML/CSS/JS

Build output:

```text
src/agenticFrontend.nim
  -> public/js/app.js
```

## Current behavior

- chat UI
- durable Phoenix job creation
- real `job_id`
- `GET /api/v1/jobs/:id` polling
- pending/processing/completed state
- real AI answer rendering
- inspector/run events
- tool/plugin preview UI

The real backend path is the primary submission path.

## Build

```bash
cd /mnt/c/project/agenticFrontend
nimble build
```

Karax unused-import warnings are currently non-fatal.

## Serve

```bash
python3 -m http.server 8080 -d public
```

Open:

```text
http://localhost:8080
```

## Job flow

```text
user submits
  -> add user message
  -> status=submitting
  -> POST /api/v1/jobs
  -> receive job_id
  -> poll GET /api/v1/jobs/:id
  -> pending
  -> processing
  -> completed
  -> render result.answer
```

Do not reintroduce the old double path where local mock output and the real backend request both run.

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

## Development rules

- keep UI state-driven through Karax
- avoid manual DOM mutation for app state
- frontend never queries SurrealDB or AI SQLite directly
- frontend never executes host shell directly
- every visible control should respond, even if it only explains preview state

## Shell/process MVP

The browser can absolutely be the interface for real local execution, but execution must happen behind the trusted backend/AI runner:

```text
Karax
  -> Phoenix
  -> AI proposes process tool
  -> ToolGateway validates
  -> trusted local runner
  -> Phoenix stores result
  -> Karax renders result
```

For mutating commands such as `mkdir`, the frontend will likely need an approval UI.

Expected approval flow:

```text
job -> waiting_approval
user explicitly approves
POST approval endpoint
execution continues
job -> completed
```

## Known limitations

- backend URL is hardcoded for local development
- polling is used instead of realtime push
- one active job is intentionally enforced in the current composer path
- authentication is development-only
- some old mock/local-preview code may remain
- plugin/tool cards are mostly preview UI

## Before commit

```text
[ ] nimble build succeeds
[ ] page loads
[ ] one durable job per submitted message
[ ] pending -> processing -> completed is visible
[ ] real AI result renders
[ ] no local mock answer appears
```

See the cross-repository `PROJECT_HANDOFF.md`.
