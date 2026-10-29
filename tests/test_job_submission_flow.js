"use strict";
const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {webcrypto} = require("node:crypto");

const read = relative => fs.readFileSync(path.join(__dirname, relative), "utf8");
const driver = read("../.runtime/job_submission_flow_driver.js");
const socket = read("../public/js/job_socket.js");
const base = "https://backend.example";

// Browser storage that fails the test if the frontend touches it.
function forbiddenStorage(touched) {
  const refuse = name => () => { touched.push(name); throw new Error("browser storage must not be used"); };
  return {getItem: refuse("getItem"), setItem: refuse("setItem"), removeItem: refuse("removeItem"),
    key: refuse("key"), get length() { touched.push("length"); return 0; }};
}

const {intentServer} = require("./fixtures/submission_intent_server.js");

function fixture({crypto = webcrypto, delayPost = false} = {}) {
  const requests = [];
  const touched = [];
  const server = intentServer();
  const state = {refuseJobs: false};
  let release, markPosted;
  const posted = new Promise(resolve => { markPosted = resolve; });
  const context = vm.createContext({console, Headers, crypto,
    sessionStorage: forbiddenStorage(touched), localStorage: forbiddenStorage(touched),
    requestAnimationFrame: () => 1, setTimeout, clearTimeout,
    AGENTIC_CONFIG: {backendBaseUrl: base, pollIntervalMs: 1000},
    fetch: async (url, options) => {
      requests.push({url, options});
      if (new URL(url).pathname.startsWith("/api/v1/submission-intents")) return server.handle(url, options);
      if (options.method === "POST") {
        const request = JSON.parse(options.body);
        if (state.refuseJobs) {
          return {ok: false, status: 429, text: async () => JSON.stringify({error: "rate_limited", message: "Too many requests."})};
        }
        if (delayPost) {
          markPosted();
          await new Promise(resolve => { release = resolve; });
        }
        return {ok: true, status: 202, text: async () => JSON.stringify({
          job_id: "saved-job", submission_id: request.submission_id, status: "completed",
        })};
      }
      return {ok: true, status: 200, text: async () => JSON.stringify({
        contract_version: 2, job_id: "saved-job", status: "completed", result: {answer: "Fixture result"},
      })};
    }});
  context.window = context;
  vm.runInContext(socket, context);
  vm.runInContext(driver, context);
  return {context, requests, touched, server, state, posted,
    jobPosts: () => requests.filter(row => row.options.method === "POST" && new URL(row.url).pathname === "/api/v1/jobs")
      .map(row => JSON.parse(row.options.body)),
    initialize(draft, steps = []) { context.initializeSubmissionFlowForTest(draft, JSON.stringify(steps)); },
    snapshot() { return JSON.parse(context.submissionFlowSnapshotForTest()); },
    submit(message, recovering = false) { return context.submitFlowForTest(message, recovering); },
    async readPending() { return String(await context.readSubmissionForTest()); },
    setDraft(draft) { context.setSubmissionDraftForTest(draft); },
    release() { assert.equal(typeof release, "function"); release(); }};
}

test("the server allocates the submission identity, so the browser needs no UUID support", async () => {
  const f = fixture({crypto: {}});
  f.initialize("  Send this request  ");
  await f.submit("Send this request");
  const saved = f.server.slots.get("chat:chat-a");
  assert.deepEqual(f.jobPosts().map(job => job.submission_id), [saved.request.submission_id]);
  assert.equal(saved.state, "acknowledged");
  assert.equal(f.snapshot().status, "completed");
  assert.deepEqual(f.touched, []);
});

test("an oversized reviewed workflow is refused before any job and keeps the draft", async () => {
  const f = fixture();
  f.initialize("A request with exact targets", [{id: "first", capability: "read_files",
    grounded_arguments: {paths: Array(16).fill("界".repeat(1024))}, after_success_of: null}]);
  await f.submit("A request with exact targets");
  assert.equal(f.snapshot().draft, "A request with exact targets");
  assert.match(f.snapshot().toast, /^No new request was sent\. The server refused this request as invalid\./);
  assert.deepEqual(f.jobPosts(), []);
  assert.equal(f.server.slots.size, 0);
  assert.deepEqual(f.touched, []);
});

test("successful preparation consumes only its own draft before POST, preserving a later draft on acknowledgement", async () => {
  const f = fixture({delayPost: true});
  f.initialize("  Prepared request  ");
  const pending = f.submit("Prepared request");
  await f.posted; // The server reserved the request and the job POST is in flight.
  assert.equal(f.snapshot().draft, "");
  assert.equal(f.snapshot().status, "submitting");
  f.setDraft("My next request while the response is pending");
  f.release();
  await pending;
  assert.equal(f.snapshot().draft, "My next request while the response is pending");
  assert.equal(f.snapshot().status, "completed");
  assert.equal(f.jobPosts().length, 1);
  assert.deepEqual(f.touched, []);
});

test("recovering a server-held request sends it unchanged and leaves the next message intact", async () => {
  const f = fixture({delayPost: true});
  f.initialize("My independent next message");
  const saved = f.server.seed("chat", "chat-a", {chat_id: "chat-a", message: "The saved original request"});
  // Reading the saved request (as opening the chat does) never sends it.
  assert.equal(await f.readPending(), "The saved original request");
  assert.deepEqual(f.jobPosts(), []);
  const pending = f.submit(saved.message, true);
  await f.posted;
  assert.equal(f.snapshot().draft, "My independent next message");
  assert.deepEqual(f.jobPosts(), [saved]);
  f.setDraft("An edited next message during recovery");
  f.release();
  await pending;
  assert.equal(f.snapshot().draft, "An edited next message during recovery");
  assert.equal(f.snapshot().status, "completed");
  assert.equal(f.server.slots.get("chat:chat-a").state, "acknowledged");
  assert.deepEqual(f.touched, []);
});

test("a refused job attempt keeps its server-held request for an explicit retry", async () => {
  const f = fixture();
  f.initialize("Retry me later");
  f.state.refuseJobs = true;
  await f.submit("Retry me later");
  const saved = f.server.slots.get("chat:chat-a");
  assert.equal(saved.state, "pending");
  assert.equal(f.snapshot().status, "submission_unknown");
  assert.match(f.snapshot().toast, /Check the saved submission/);
  f.state.refuseJobs = false;
  await f.submit("Retry me later", true);
  assert.deepEqual(f.jobPosts().map(job => job.submission_id), [saved.request.submission_id, saved.request.submission_id]);
  assert.equal(f.server.slots.get("chat:chat-a").state, "acknowledged");
  assert.equal(f.snapshot().status, "completed");
});

test("a direct request does not consume a composer draft belonging to another message", async () => {
  const f = fixture();
  f.initialize("An unrelated draft");
  await f.submit("A separate request");
  assert.equal(f.snapshot().draft, "An unrelated draft");
  assert.equal(f.snapshot().status, "completed");
});
