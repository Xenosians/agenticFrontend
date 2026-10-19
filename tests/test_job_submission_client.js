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
const submissionHelper = fs.readFileSync(path.join(__dirname, "../public/js/job_submission.js"), "utf8");
function fixture(fetch) {
  const requests = [];
  const context = vm.createContext({console, Headers,
    AGENTIC_CONFIG: {backendBaseUrl: "https://backend.example", pollIntervalMs: 1000},
    fetch: async (url, options) => { requests.push({url, options}); return fetch(url, options); }});
  vm.runInContext(driver, context);
  const identity = webcrypto.randomUUID();
  return {requests, identity, submit: async () => JSON.parse(await context.submitJobForTest("chat-a", "Read status", "test-csrf", identity)),
    read: async () => JSON.parse(await context.readJobForTest("saved-job"))};
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

test("native browser storage exceptions become handled Nim errors before any POST", () => {
  let posts = 0;
  const context = vm.createContext({console, Headers, crypto: webcrypto,
    sessionStorage: {getItem() { return null; }, setItem() { throw new Error("storage unavailable"); }},
    fetch() { posts++; throw new Error("must not post"); },
    AGENTIC_CONFIG: {backendBaseUrl: "https://backend.example", pollIntervalMs: 1000}});
  vm.runInContext(submissionHelper, context);
  vm.runInContext(driver, context);
  assert.equal(JSON.parse(context.prepareJobForTest("owner-a", "chat-a", "Request")).kind, "storage_error");
  assert.equal(posts, 0);
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

test("HTTP 200 alone cannot acknowledge a job with a missing or mismatched submission identity", async () => {
  for (const body of [{job_id: "job", status: "pending"},
    {job_id: "job", status: "pending", submission_id: webcrypto.randomUUID()},
    {job_id: "job", status: "success"}, {success: true}, "not JSON"]) {
    const f = fixture(async () => ({ok: true, status: 200, text: async () => typeof body === "string" ? body : JSON.stringify(body)}));
    assert.equal((await f.submit()).kind, "unknown");
  }
});
