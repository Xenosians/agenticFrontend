"use strict";
const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {webcrypto} = require("node:crypto");

// Compile tests/job_submission_client_driver.nim to this ignored build file
// first. A missing artifact is a test failure, never an automatic skip.
const driver = fs.readFileSync(path.join(__dirname, "../.runtime/job_submission_client_driver.js"), "utf8");
function fixture(fetch) {
  const requests = [];
  const context = vm.createContext({console, Headers,
    AGENTIC_CONFIG: {backendBaseUrl: "https://backend.example", pollIntervalMs: 1000},
    fetch: async (url, options) => { requests.push({url, options}); return fetch(url, options); }});
  vm.runInContext(driver, context);
  const identity = webcrypto.randomUUID();
  return {requests, identity, submit: async (contract = null) => JSON.parse(await context.submitJobForTest("chat-a", "Read status", "test-csrf", identity, JSON.stringify(contract))),
    read: async () => JSON.parse(await context.readJobForTest("saved-job")),
    logout: async () => String(await context.logoutForTest("test-csrf"))};
}

test("production client sends the pinned identity and accepts an existing terminal job honestly", async () => {
  const f = fixture(async (_url, options) => {
    const request = JSON.parse(options.body);
    return {ok: true, status: 202, text: async () => JSON.stringify({job_id: "saved-job", status: "failed", submission_id: request.submission_id})};
  });
  assert.deepEqual(await f.submit(), {kind: "acknowledged", job_id: "saved-job", status: "failed", submission_id: f.identity});
  assert.deepEqual(JSON.parse(f.requests[0].options.body), {chat_id: "chat-a", message: "Read status", submission_id: f.identity});
  assert.equal(f.requests[0].options.credentials, "include");
});

test("production client submits the reviewed obligations unchanged under the same durable identity", async () => {
  const workflow = {version: 1, steps: [{id: "one", capability: "read_files",
    grounded_arguments: {paths: [" Exact path "]}, after_success_of: null}]};
  const f = fixture(async (_url, options) => {
    const request = JSON.parse(options.body);
    return {ok: true, status: 202, text: async () => JSON.stringify({job_id: "saved-job", status: "pending", submission_id: request.submission_id,
      workflow_contract: request.workflow_contract, workflow_contract_hash: "a".repeat(64)})};
  });
  assert.equal((await f.submit(workflow)).kind, "acknowledged");
  assert.deepEqual(JSON.parse(f.requests[0].options.body).workflow_contract, workflow);
});

test("a missing or changed workflow acknowledgement remains unknown even with the matching submission id", async () => {
  const workflow = {version: 1, steps: [{id: "one", capability: "read_files",
    grounded_arguments: {paths: [" Exact path "]}, after_success_of: null}]};
  for (const override of [{}, {workflow_contract: workflow}, {workflow_contract_hash: "a".repeat(64)},
    {workflow_contract: {...workflow, steps: []}, workflow_contract_hash: "a".repeat(64)},
    {workflow_contract: workflow, workflow_contract_hash: "A".repeat(64)},
    {workflow_contract: workflow, workflow_contract_hash: "a".repeat(63)}]) {
    const f = fixture(async (_url, options) => {
      const request = JSON.parse(options.body);
      return {ok: true, status: 202, text: async () => JSON.stringify({job_id: "saved-job", status: "pending", submission_id: request.submission_id, ...override})};
    });
    assert.equal((await f.submit(workflow)).kind, "unknown");
  }
});

test("native read failures reach the durable job observer as handled interruptions", async () => {
  const disconnected = fixture(async () => { throw new Error("connection lost while reading"); });
  assert.equal((await disconnected.read()).kind, "read_interrupted");
  const invalid = fixture(async () => ({ok: true, status: 200, text: async () => "not JSON"}));
  assert.equal((await invalid.read()).kind, "read_interrupted");
});

test("a lost create response stays unknown and repeat sends retain the same identity", async () => {
  const f = fixture(async () => { throw new Error("lost response after server persisted"); });
  assert.equal((await f.submit()).kind, "unknown");
  assert.equal((await f.submit()).kind, "unknown");
  assert.equal(JSON.parse(f.requests[0].options.body).submission_id, JSON.parse(f.requests[1].options.body).submission_id);
});

test("server errors and request timeouts are uncertain; confirmed input or access rejections are separate", async () => {
  for (const status of [408, 500, 502, 503]) {
    const f = fixture(async () => ({ok: false, status, text: async () => "upstream interrupted"}));
    assert.equal((await f.submit()).kind, "unknown");
  }
  for (const status of [400, 401, 403, 409, 422, 429]) {
    const f = fixture(async () => ({ok: false, status, text: async () => '{"error":"request_rejected"}'}));
    assert.equal((await f.submit()).kind, "rejected");
  }
});

test("sign-out is confirmed only by the server; a lost connection is never reported as signed out", async () => {
  const answer = status => fixture(async () => ({ok: status >= 200 && status < 300, status, text: async () => "{}"}));
  assert.equal(await answer(200).logout(), "loSignedOut");
  assert.equal(await answer(401).logout(), "loAlreadyEnded");
  for (const status of [403, 500, 503]) assert.equal(await answer(status).logout(), "loUnconfirmed");
  const lost = fixture(async () => { throw new TypeError("Failed to fetch"); });
  assert.equal(await lost.logout(), "raised");
  assert.equal(lost.requests[0].options.headers.get("X-CSRF-Token"), "test-csrf");
});

test("a rejected fetch becomes a handled error, never a silent failure", async () => {
  const f = fixture(async () => { throw new TypeError("Failed to fetch"); });
  assert.equal((await f.submit()).kind, "unknown");
  assert.equal((await f.read()).kind, "read_interrupted");
});

test("HTTP 200 alone cannot acknowledge a job with a missing or mismatched submission identity", async () => {
  for (const body of [{job_id: "job", status: "pending"},
    {job_id: "job", status: "pending", submission_id: webcrypto.randomUUID()},
    {job_id: "job", status: "success"}, {success: true}, "not JSON"]) {
    const f = fixture(async () => ({ok: true, status: 200, text: async () => typeof body === "string" ? body : JSON.stringify(body)}));
    assert.equal((await f.submit()).kind, "unknown");
  }
});
