"use strict";
const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {intentServer} = require("./fixtures/submission_intent_server.js");

// Exercise the production Nim API, compiled into ignored test output. Phoenix
// separately tests durable storage and the authority of operation receipts.
const driver = fs.readFileSync(path.join(__dirname, "../.runtime/job_submission_client_driver.js"), "utf8");
const base = "https://backend.example";
const proposal = () => ({chat_id: "chat-a", message: "Read the exact inventory"});
function fixture({server = intentServer(), intercept = null} = {}) {
  const requests = [], touched = [];
  const forbidden = new Proxy({}, {get(_target, name) {
    touched.push(String(name)); throw new Error("browser storage must not be used");
  }});
  const context = vm.createContext({console, Headers, crypto: {},
    localStorage: forbidden, sessionStorage: forbidden, indexedDB: forbidden,
    AGENTIC_CONFIG: {backendBaseUrl: base, pollIntervalMs: 1000},
    fetch: async (url, options) => {
      requests.push({url, options});
      return intercept ? intercept(url, options, server) : server.handle(url, options);
    }});
  vm.runInContext(driver, context);
  const decode = async promise => JSON.parse(await promise);
  return {server, requests, touched,
    read: (owner = "owner-a", kind = "chat", target = "chat-a") => decode(context.readIntentForTest(owner, kind, target)),
    reserve: (payload = proposal(), owner = "owner-a", kind = "chat", target = "chat-a") =>
      decode(context.reserveIntentForTest(owner, kind, target, JSON.stringify(payload))),
    acknowledge: (id, owner = "owner-a", kind = "chat", target = "chat-a") =>
      decode(context.acknowledgeIntentForTest(owner, kind, target, id)),
    cached: (owner = "owner-a", kind = "chat", target = "chat-a") => JSON.parse(context.cachedIntentForTest(owner, kind, target)),
    clear: owner => context.clearIntentForTest(owner),
    posts: () => requests.filter(row => row.options.method === "POST")};
}

test("server identity is reserved before dispatch without browser UUID or storage", async () => {
  const f = fixture(), first = await f.reserve();
  assert.equal(first.ok, true);
  assert.equal(first.intent.state, "pending");
  assert.match(first.intent.request.submission_id, /^[0-9a-f-]{36}$/);
  assert.equal(f.requests[0].options.method, "GET");
  assert.equal(f.posts().length, 1);
  assert.equal(f.posts()[0].options.headers.get("X-CSRF-Token"), "fixture-csrf");
  assert.equal(f.posts()[0].options.credentials, "include");
  assert.deepEqual(await f.reserve(), first);
  assert.equal(f.posts().length, 1);
  assert.deepEqual(f.touched, []);
});

test("a pending identity freezes exact text, obligations and target", async () => {
  const f = fixture();
  const reviewed = {...proposal(), workflow_contract: {version: 1, steps: [
    {id: "read", capability: "read_files", grounded_arguments: {paths: [" Exact target "]}, after_success_of: null}]}};
  const first = await f.reserve(reviewed);
  reviewed.workflow_contract.steps[0].grounded_arguments.paths[0] = "Different target";
  assert.equal((await f.reserve(reviewed)).ok, false);
  assert.equal((await f.reserve({...proposal(), message: "Changed text"})).ok, false);
  assert.equal(f.cached().intent.request.workflow_contract.steps[0].grounded_arguments.paths[0], " Exact target ");
  assert.equal(f.cached().intent.id, first.intent.id);
  assert.equal(f.posts().length, 1);
});

test("a lost reservation acknowledgement survives reload as a read-only exact identity", async () => {
  const server = intentServer();
  let lose = true;
  const firstPage = fixture({server, intercept(url, options, current) {
    const response = current.handle(url, options);
    if (options.method === "POST" && lose) { lose = false; throw new TypeError("reply lost"); }
    return response;
  }});
  assert.equal((await firstPage.reserve()).ok, false);
  const original = structuredClone(server.slots.get("chat:chat-a"));
  const reload = fixture({server});
  const recovered = await reload.read();
  assert.equal(recovered.intent.id, original.intent_id);
  assert.deepEqual(recovered.intent.request, original.request);
  assert.equal(reload.posts().length, 0);
  assert.deepEqual(await reload.reserve(), recovered);
  assert.equal(reload.posts().length, 0);
});

test("unknown acceptance cannot release a pending request or create another identity", async () => {
  let failAck = true;
  const f = fixture({intercept(url, options, server) {
    if (new URL(url).pathname.endsWith("/acknowledge") && failAck) {
      return {ok: false, status: 503, text: async () => '{"error":"submission_intent_unavailable"}'};
    }
    return server.handle(url, options);
  }});
  const first = await f.reserve();
  assert.equal((await f.acknowledge(first.intent.id)).ok, false);
  assert.equal(f.cached().intent.id, first.intent.id);
  assert.equal(f.cached().intent.state, "pending");
  assert.equal((await f.reserve({...proposal(), message: "Another request"})).ok, false);
  failAck = false;
  assert.equal((await f.acknowledge(first.intent.id)).intent.state, "acknowledged");
  const next = await f.reserve();
  assert.notEqual(next.intent.id, first.intent.id);
});

test("late tab reservations and acknowledgements cannot overwrite a newer request", async () => {
  const server = intentServer(), a = fixture({server}), b = fixture({server});
  await a.read(); await b.read();
  const first = await a.reserve();
  await a.acknowledge(first.intent.id);
  assert.equal((await b.reserve()).ok, false, "stale empty predecessor must not reserve again");
  await b.read();
  const next = await b.reserve();
  assert.notEqual(next.intent.id, first.intent.id);
  assert.equal((await a.acknowledge(first.intent.id)).ok, false);
  assert.equal(server.slots.get("chat:chat-a").intent_id, next.intent.id);
  assert.equal(server.slots.get("chat:chat-a").state, "pending");
});

test("owners and targets have separate caches and sign-out drops no server identity", async () => {
  const f = fixture(), first = await f.reserve();
  assert.equal(f.cached("owner-b").ok, false);
  assert.equal(f.cached("owner-a", "chat", "another-chat").ok, false);
  await f.read("owner-b");
  f.clear("owner-a");
  assert.equal(f.cached("owner-a").ok, false);
  assert.equal(f.cached("owner-b").intent.id, first.intent.id);
  assert.equal((await f.read()).intent.id, first.intent.id);
  assert.equal(f.posts().length, 1);
});

test("unavailable, missing and malformed slot observations never become verified absence", async () => {
  const replies = [null, {}, {schema: "submission-intent-slot.v1", kind: "chat", target_id: "wrong", intent: null}];
  for (const body of replies) {
    const f = fixture({intercept: () => ({ok: true, status: 200, text: async () => JSON.stringify(body)})});
    assert.equal((await f.reserve()).ok, false);
    assert.equal(f.cached().ok, false);
    assert.equal(f.posts().length, 0);
  }
  const failed = fixture({intercept: () => { throw new TypeError("network unavailable"); }});
  assert.equal((await failed.reserve()).ok, false);
  assert.equal(failed.posts().length, 0);
});

test("a mismatched reservation receipt stops before a usable dispatch identity exists", async () => {
  for (const field of ["target_id", "kind", "schema"]) {
    const f = fixture({intercept: async (url, options, server) => {
      const response = server.handle(url, options);
      if (options.method !== "POST") return response;
      const body = JSON.parse(await response.text()); body[field] = "wrong";
      return {ok: true, status: 200, text: async () => JSON.stringify(body)};
    }});
    assert.equal((await f.reserve()).ok, false);
    assert.equal(f.cached().intent.id, "");
  }
});

test("only an exact acknowledged receipt clears the original frozen request", async () => {
  for (const change of [row => { row.intent.intent_id = "f".repeat(32); },
    row => { row.intent.state = "pending"; }, row => { row.intent.request.message = "Changed"; }]) {
    const f = fixture({intercept: async (url, options, server) => {
      const response = server.handle(url, options);
      if (!new URL(url).pathname.endsWith("/acknowledge")) return response;
      const body = JSON.parse(await response.text()); change(body);
      return {ok: true, status: 200, text: async () => JSON.stringify(body)};
    }});
    const first = await f.reserve();
    assert.equal((await f.acknowledge(first.intent.id)).ok, false);
    assert.deepEqual(f.cached(), first);
  }
});

test("server admission refusals retain their reason and never allocate a fallback identity", async () => {
  const f = fixture();
  const oversized = {...proposal(), workflow_contract: {payload: "界".repeat(12000)}};
  const result = await f.reserve(oversized);
  assert.equal(result.ok, false);
  assert.match(result.error, /invalid/);
  assert.equal(f.server.slots.size, 0);
});
