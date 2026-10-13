# Agentic Frontend

Nim/Karax browser frontend for the **Agentic Developer Hub / ITSM Platform**.

The frontend is a state-driven browser client that authenticates against Phoenix, owns the interactive chat experience, submits durable jobs, restores chat history, polls job lifecycle, renders real AI results, and exposes explicit approval controls for governed mutations.

> **Boundary rule:** the browser is a UI boundary, never an authorization or execution boundary.

---

## Stack

- Nim `>= 2.2.10`
- Karax `1.5.0`
- JavaScript target
- static HTML/CSS/JS
- Phoenix REST API

Build output:

```text
src/agenticFrontend.nim
    |
    v
public/js/app.js
```

---

## Application architecture

```text
User
  |
  v
Nim / Karax browser UI
  |
  | public REST + session cookie
  v
Phoenix / Elixir backend
  |
  +--> authentication / chats / durable jobs
  |
  +--> SurrealDB
  |
  +--> AI dispatch
          |
          v
       FastAPI AI
          |
          v
     governed tools/providers
          |
          v
       Phoenix
          |
          v
       Frontend
```

The browser never calls FastAPI, SurrealDB, LDAP, Jira, Git, or the host shell directly.

---

## Current capabilities

### Authentication

The frontend currently supports:

```text
register
email verification
resend verification
login
session restore
logout
forgot password
reset password
session listing
session revocation
```

Phoenix owns the actual identity/session policy.

The browser receives a CSRF token for authenticated state-changing requests while the backend owns the HTTP-only session cookie.

### Chats

Current chat support includes:

- durable authenticated chat creation;
- remote chat listing;
- chat selection;
- durable chat-history loading;
- new-chat creation;
- conversation restore on application bootstrap.

Phoenix job rows remain the source of chat turns.

### Durable AI jobs

The frontend submits:

```http
POST /api/v1/jobs
```

and polls:

```http
GET /api/v1/jobs/:id
```

Current rendered lifecycle includes:

```text
submitting
pending
processing
waiting_approval
approving
completed
failed
```

The frontend tracks the real Phoenix `job_id`.

### Approval UX

When Phoenix reports:

```text
waiting_approval
```

the UI renders an explicit approval control.

Approval request:

```http
POST /api/v1/jobs/:job_id/approve
```

The browser sends the durable job ID and CSRF token.

It does **not** send or invent privileged execution arguments and does not treat a model-generated approval identifier as authority.

### Structured results

Structured presentation cards returned through the AI -> Phoenix -> frontend contract are rendered alongside assistant messages.

### System status

The frontend can query and present backend/AI health/readiness state.

### Inspector/run events

The UI records bounded lifecycle/debug events such as:

```text
request submitted
backend job created
job status transition
approval required
approval execution
completion
backend error
```

These are UX/debug metadata, not execution authority.

---

## Runtime configuration

Frontend deployment values are loaded from:

```text
public/config.js
```

`src/config/runtime_config.nim` requires:

```text
AGENTIC_CONFIG.backendBaseUrl
AGENTIC_CONFIG.pollIntervalMs
```

Example shape:

```javascript
globalThis.AGENTIC_CONFIG = {
  backendBaseUrl: "http://127.0.0.1:4000",
  pollIntervalMs: 1000
};
```

The backend URL is therefore runtime-configurable rather than compiled as a fixed source-code constant.

---

## Public backend calls

Authentication:

```text
/api/v1/auth/*
```

Chats:

```http
POST /api/v1/chats
GET  /api/v1/chats
GET  /api/v1/chats/:id/history
```

Jobs:

```http
POST /api/v1/jobs
GET  /api/v1/jobs/:id
POST /api/v1/jobs/:id/approve
```

System health is queried through the Phoenix-facing client path.

---

## State model

Important application state includes:

```text
authentication/session
chat list
current chat
messages
current run/job
structured presentations
run events
system health
active view
```

Application behavior is kept in Karax state/VDOM rather than manual DOM mutation.

---

## Real request flow

```text
user enters message
        |
        v
frontend validates authenticated/current-chat state
        |
        v
POST durable Phoenix job
        |
        v
poll job
        |
        +--> pending
        |
        +--> processing
        |
        +--> waiting_approval
        |        |
        |        v
        |     approval button
        |        |
        |        v
        |   POST /approve
        |
        +--> completed
        |        |
        |        v
        |   assistant message + result cards
        |
        +--> failed
```

Local mock behavior must not run alongside the real Phoenix-backed request path.

---

## Authentication flow

Startup:

```text
load public runtime config
        |
        v
inspect verify/reset query tokens
        |
        v
GET /api/v1/auth/me
        |
        +--> authenticated
        |       |
        |       v
        |   load remote chats/history
        |
        +--> unauthenticated
                |
                v
            auth screen
```

Verification/reset tokens are removed from the browser URL when their flow completes.

---

## Build

```bash
cd /mnt/c/project/agenticFrontend
nimble build
```

Serve static assets locally:

```bash
python3 -m http.server 8080 -d public
```

Then open:

```text
http://127.0.0.1:8080
```

Phoenix must allow the frontend origin through CORS and its auth cookie policy must match the deployment.

---

## Main source layout

```text
src/
├── agenticFrontend.nim
├── api/
│   ├── auth_client.nim
│   └── client.nim
├── app/
│   ├── auth_bridge.nim
│   ├── backend_bridge.nim
│   ├── mock_agent.nim
│   ├── state.nim
│   └── types.nim
├── components/
│   ├── auth.nim
│   ├── brand.nim
│   ├── chat.nim
│   ├── composer.nim
│   ├── inspector.nim
│   ├── result_card.nim
│   └── sidebar.nim
└── config/
    └── runtime_config.nim

public/
├── config.js
├── index.html
├── css/
├── assets/
└── js/app.js
```

---

## Cross-repository project visibility

Project planning/status reporting is currently handled by the separate local `projectOps` workspace rather than by the browser frontend.

```text
agenticFrontend Git history
agenticBackend Git history
agenticAI Git history
        +
explicit SDLC status catalog
        |
        v
projectOps
        |
        +--> Notion board
        +--> weekly Gmail brief
```

The frontend therefore remains focused on product interaction and durable job UX. The Notion SDLC board is an engineering/project-operations surface, not a browser authorization source.

---

## Current deliberate limitations

The frontend is already connected to the real backend flow, but it remains an MVP.

Current gaps include:

- job lifecycle updates use polling rather than server push/SSE/WebSocket;
- the composer intentionally allows one active durable job at a time;
- reconnect/in-flight recovery is still limited compared with a production collaboration client;
- dynamic capability/plugin discovery is not yet fully driven by trusted server metadata;
- some tool/plugin UI remains preview-oriented;
- generated `public/js/app.js` is committed and that policy should remain consistent;
- lifecycle does not yet have first-class rendering for future backend states such as `denied` or `outcome_unknown`;
- deployment auth/cookie/CORS hardening still depends on correct environment configuration.

Authentication itself is no longer only a mock/development UI; real backend registration, verification, sessions, chats, password reset, and ownership-aware API calls are implemented.

---

## Development rules

1. Frontend calls Phoenix only.
2. Never call FastAPI directly from browser code.
3. Never expose SurrealDB, LDAP, Jira, Git, shell, or AI SQLite directly to the browser.
4. Never make frontend controls an authorization source.
5. Keep state transitions in Karax state/VDOM.
6. Preserve CSRF/session handling on state-changing authenticated requests.
7. Treat the durable job ID as the browser-facing operation identity.
8. Render server-owned result/presentation structures rather than reconstructing privileged tool state client-side.
9. Keep unavailable/preview features explicit instead of pretending they execute.
10. Verify cross-repository contracts whenever job/result/auth payloads change.

---

## Before commit

```text
[ ] nimble build succeeds
[ ] application loads public/config.js
[ ] registration/login/session restore work
[ ] chat list/history load
[ ] one durable job is created per submitted message
[ ] pending -> processing -> completed works
[ ] waiting_approval -> approve -> completed works
[ ] structured result cards render
[ ] failed jobs render clearly
[ ] no mock answer appears on the real path
[ ] browser never sends privileged approval/tool authority
```

---

## Design summary

```text
The browser owns interaction.
Phoenix owns durable application truth.
The AI runtime owns reasoning.
Trusted server-side policy owns authority.
```
