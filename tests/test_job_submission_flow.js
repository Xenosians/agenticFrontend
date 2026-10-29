"use strict";
const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {webcrypto} = require("node:crypto");

const read = relative => fs.readFileSync(path.join(__dirname, relative), "utf8");
const driver = read("../.runtime/job_submission_flow_driver.js");
const helper = read("../public/js/job_submission.js");
const socket = read("../public/js/job_socket.js");
const base = "https://backend.example";

// Browser storage that fails the test if the frontend touches it.
function forbiddenStorage(touched) {
  const refuse = name => () => { touched.push(name); throw new Error("browser storage must not be used"); };
  return {getItem: refuse("getItem"), setItem: refuse("setItem"), removeItem: refuse("removeItem"),
    key: refuse("key"), get length() { touched.push("length"); return 0; }};
}

function fixture({crypto = webcrypto, delayPost = false} = {}) {
  const requests = [];
  const touched = [];
  let release;
  const context = vm.createContext({console, Headers, crypto,
    sessionStorage: forbiddenStorage(touched), localStorage: forbiddenStorage(touched),
    requestAnimationFrame: () => 1, setTimeout, clearTimeout,
    AGENTIC_CONFIG: {backendBaseUrl: base, pollIntervalMs: 1000},
    fetch: async (url, options) => {
      requests.push({url, options});
      if (options.method === "POST") {
        const request = JSON.parse(options.body);
        if (delayPost) await new Promise(resolve => { release = resolve; });
        return {ok: true, status: 202, text: async () => JSON.stringify({
          job_id: "saved-job", submission_id: request.submission_id, status: "completed",
        })};
      }
      return {ok: true, status: 200, text: async () => JSON.stringify({
        contract_version: 2, job_id: "saved-job", status: "completed", result: {answer: "Fixture result"},
      })};
    }});
  context.window = context;
  vm.runInContext(helper, context);
  vm.runInContext(socket, context);
  vm.runInContext(driver, context);
  return {context, requests, touched,
    initialize(draft, steps = []) { context.initializeSubmissionFlowForTest(draft, JSON.stringify(steps)); },
    snapshot() { return JSON.parse(context.submissionFlowSnapshotForTest()); },
    submit(message, recovering = false) { return context.submitFlowForTest(message, recovering); },
    setDraft(draft) { context.setSubmissionDraftForTest(draft); },
    release() { assert.equal(typeof release, "function"); release(); }};
}

test("a submission identity the browser cannot create keeps the exact composer draft and makes no POST", async () => {
  const f = fixture({crypto: {}});
  f.initialize("  Keep my unsent request  ");
  await f.submit("Keep my unsent request");
  assert.equal(f.snapshot().draft, "  Keep my unsent request  ");
  assert.match(f.snapshot().toast, /No new request was sent/);
  assert.equal(f.requests.length, 0);
  assert.deepEqual(f.touched, []);
});

test("an oversized reviewed workflow preserves the draft and never persists or posts", async () => {
  const f = fixture();
  f.initialize("A request with exact targets", [{id: "first", capability: "read_files",
    grounded_arguments: {paths: Array(16).fill("界".repeat(1024))}, after_success_of: null}]);
  await f.submit("A request with exact targets");
  assert.equal(f.snapshot().draft, "A request with exact targets");
  assert.match(f.snapshot().toast, /required operations are invalid/);
  assert.equal(f.requests.length, 0);
  assert.deepEqual(f.touched, []);
});

test("successful preparation consumes only its own draft before POST, preserving a later draft on acknowledgement", async () => {
  const f = fixture({delayPost: true});
  f.initialize("  Prepared request  ");
  const pending = f.submit("Prepared request");
  assert.equal(f.snapshot().draft, "");
  assert.equal(f.snapshot().status, "submitting");
  f.setDraft("My next request while the response is pending");
  f.release();
  await pending;
  assert.equal(f.snapshot().draft, "My next request while the response is pending");
  assert.equal(f.snapshot().status, "completed");
  assert.equal(f.requests.filter(row => row.options.method === "POST").length, 1);
  assert.deepEqual(f.touched, []);
});

test("recovering a pinned request leaves the independently typed next message intact", async () => {
  const f = fixture({delayPost: true});
  // The request pinned earlier in this page, whose acknowledgement was lost.
  const saved = f.context.AgenticJobSubmission.forPage(webcrypto, base, "owner-a", "chat-a")
    .prepare("The saved original request");
  f.initialize("My independent next message");
  const pending = f.submit(saved.message, true);
  assert.equal(f.snapshot().draft, "My independent next message");
  assert.equal(JSON.parse(f.requests[0].options.body).submission_id, saved.submission_id);
  f.setDraft("An edited next message during recovery");
  f.release();
  await pending;
  assert.equal(f.snapshot().draft, "An edited next message during recovery");
  assert.equal(f.snapshot().status, "completed");
  assert.equal(f.context.AgenticJobSubmission.forPage(webcrypto, base, "owner-a", "chat-a").pending(), null);
  assert.deepEqual(f.touched, []);
});

test("a direct request does not consume a composer draft belonging to another message", async () => {
  const f = fixture();
  f.initialize("An unrelated draft");
  await f.submit("A separate request");
  assert.equal(f.snapshot().draft, "An unrelated draft");
  assert.equal(f.snapshot().status, "completed");
});
