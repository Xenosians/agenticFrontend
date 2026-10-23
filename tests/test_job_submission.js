"use strict";
const {test} = require("node:test");
const assert = require("node:assert/strict");
const {webcrypto} = require("node:crypto");
const {create, clearOwner} = require("../public/js/job_submission.js");

function storage() {
  const values = new Map();
  return {getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value),
    removeItem: key => values.delete(key), key: index => [...values.keys()][index] ?? null,
    get length() { return values.size; }};
}
const bind = (saved, owner = "owner-a", chat = "chat-a", base = "https://backend.example") =>
  create(saved, webcrypto, base, owner, chat);
const ack = (request, status = "pending") => ({submission_id: request.submission_id, job_id: "durable-job", status});

test("identity and exact request are pinned before sending, and duplicate attempts reuse them", () => {
  const saved = storage(), client = bind(saved);
  const first = client.prepare("Check the service");
  assert.deepEqual(client.pending(), first);
  assert.deepEqual(client.prepare("Check the service"), first);
  assert.throws(() => client.prepare("A different request"), /unresolved submission/);
  assert.equal(saved.length, 1);
});

test("lost create acknowledgement survives a browser reload with the same durable identity", async () => {
  const saved = storage(), beforeReload = bind(saved);
  const first = beforeReload.prepare("Read the account status");
  // Sending succeeded but its acknowledgement was lost. The production
  // helper must keep the pinned request; it cannot infer a failed job.
  await assert.rejects(async () => { throw new Error("connection interrupted after POST"); });
  const afterReload = bind(saved), recovered = afterReload.pending();
  assert.deepEqual(recovered, first);
  assert.equal(afterReload.prepare(recovered.message).submission_id, first.submission_id);
  afterReload.acknowledge(ack(recovered, "processing"));
  assert.equal(afterReload.pending(), null);
});

test("an acknowledgement records existing failure or unknown execution without inventing success", () => {
  for (const status of ["failed", "denied", "outcome_unknown", "completed", "waiting_approval"]) {
    const client = bind(storage()), request = client.prepare("Check saved request");
    assert.equal(client.acknowledge(ack(request, status)).status, status);
    assert.equal(client.pending(), null);
  }
});

test("invalid or unrelated acknowledgements cannot clear a pending submission", () => {
  const client = bind(storage()), request = client.prepare("One request");
  for (const response of [null, {}, {...ack(request), submission_id: webcrypto.randomUUID()},
    {...ack(request), job_id: ""}, {...ack(request), status: "success"}]) {
    assert.throws(() => client.acknowledge(response), /did not confirm/);
    assert.deepEqual(client.pending(), request);
  }
});

test("concurrent preparations for the same tab and chat reuse a single pinned identity", async () => {
  const saved = storage();
  const requests = await Promise.all(Array.from({length: 16}, async () => bind(saved).prepare("Same request")));
  assert.equal(new Set(requests.map(request => request.submission_id)).size, 1);
  assert.equal(saved.length, 1);
});

test("owners, backends and chats have separate recovery records and explicit sign out removes only its owner", () => {
  const saved = storage(), first = bind(saved).prepare("Owner A request");
  const second = bind(saved, "owner-b").prepare("Owner B request");
  bind(saved, "owner-a", "chat-b").prepare("Other chat");
  const otherBackend = bind(saved, "owner-a", "chat-a", "https://other.example").prepare("Other backend");
  assert.notEqual(first.submission_id, second.submission_id);
  clearOwner(saved, "https://backend.example", "owner-a");
  assert.equal(bind(saved).pending(), null);
  assert.deepEqual(bind(saved, "owner-b").pending(), second);
  assert.deepEqual(bind(saved, "owner-a", "chat-a", "https://other.example").pending(), otherBackend);
});

test("storage or identity-generation failure prevents preparing a request for POST", () => {
  assert.throws(() => bind({getItem() { return null; }, setItem() { throw new Error("storage full"); }}).prepare("Request"), /storage full/);
  assert.throws(() => create(storage(), {}, "base", "owner", "chat").prepare("Request"), /safe submission identity/);
});

test("confirmed rejection clears only the rejected request, never a newer identity", () => {
  const client = bind(storage()), first = client.prepare("Rejected request");
  client.reject(webcrypto.randomUUID());
  assert.deepEqual(client.pending(), first);
  client.reject(first.submission_id);
  const next = client.prepare("Corrected request");
  client.reject(first.submission_id);
  assert.deepEqual(client.pending(), next);
});

test("corrupt or cross-owner saved records fail closed instead of generating a new identity", () => {
  const saved = storage(), client = bind(saved);
  client.prepare("Request");
  saved.setItem(saved.key(0), "not JSON");
  assert.throws(() => client.prepare("Request"), /unreadable/);
  const other = bind(storage(), "owner-b").prepare("Private request");
  saved.setItem(saved.key(0), JSON.stringify(other));
  assert.throws(() => client.prepare("Request"), /invalid/);
});

const contract = () => ({version: 1, steps: [
  {id: "step_1", capability: "identity_create", grounded_arguments: {login: [" Exact Value "]}, after_success_of: null},
  {id: "step_2", capability: "issue_create", grounded_arguments: {}, after_success_of: "step_1"}
]});

test("the reviewed workflow is copied and pinned with its message across reload and uncertain acknowledgement", () => {
  const saved = storage(), before = bind(saved), reviewed = contract();
  const request = before.prepare("Create identity, then issue", reviewed);
  reviewed.steps[0].grounded_arguments.login[0] = "Different target";
  assert.equal(request.workflow_contract.steps[0].grounded_arguments.login[0], " Exact Value ");
  const after = bind(saved), pinned = after.pending();
  assert.deepEqual(pinned, request);
  assert.equal(after.prepare(pinned.message, pinned.workflow_contract).submission_id, request.submission_id);
  assert.throws(() => after.prepare(pinned.message), /unresolved submission/);
  assert.throws(() => after.prepare(pinned.message, reviewed), /unresolved submission/);
  const changedDependency = contract(); changedDependency.steps[1].after_success_of = null;
  assert.throws(() => after.prepare(pinned.message, changedDependency), /unresolved submission/);
  const reorderedKeys = {steps: contract().steps, version: 1};
  assert.equal(after.prepare(pinned.message, reorderedKeys).submission_id, request.submission_id);
});

test("malformed obligations and oversized UTF-8 input never persist a submission", () => {
  const cases = [[], {}, {version: 1, steps: []}, {...contract(), extra: true}, contract(), contract(), contract(), contract(), contract(), contract(), contract()];
  cases[4].steps[1].id = "step_1";
  cases[5].steps[1].capability = "identity_create";
  cases[6].steps[0].after_success_of = "step_2";
  cases[7].steps[0].grounded_arguments = {login: "exact"};
  cases[8].steps[0].grounded_arguments = {login: [" "]};
  cases[9].steps[0].grounded_arguments = {login: ["x".repeat(1025)]};
  cases[10].steps[0].grounded_arguments = {login: Array(16).fill("界".repeat(1024))};
  for (const invalid of cases) {
    const saved = storage();
    assert.throws(() => bind(saved).prepare("Request", invalid), /required operations are invalid/);
    assert.equal(saved.length, 0);
  }
});

test("corrupt saved obligations block recovery instead of dropping the workflow", () => {
  const saved = storage(), client = bind(saved);
  client.prepare("Request", contract());
  const damaged = JSON.parse(saved.getItem(saved.key(0)));
  delete damaged.workflow_contract.steps[1].after_success_of;
  saved.setItem(saved.key(0), JSON.stringify(damaged));
  assert.throws(() => client.pending(), /required operations are invalid/);
  assert.equal(saved.length, 1);
});

test("invalid grounded argument names and excessive field counts cannot be prepared or recovered", () => {
  for (const fields of [{"bad-target": ["value"]}, {["a".repeat(151)]: ["value"]},
    {"target_界": ["value"]}, Object.fromEntries(Array.from({length: 33}, (_, index) => ["field_" + index, ["value"]]))]) {
    const reviewed = contract(); reviewed.steps[0].grounded_arguments = fields;
    const saved = storage(), client = bind(saved);
    assert.throws(() => client.prepare("Request", reviewed), /required operations are invalid/);
    assert.equal(saved.length, 0);
    client.prepare("Request", contract());
    const damaged = JSON.parse(saved.getItem(saved.key(0)));
    damaged.workflow_contract = reviewed;
    saved.setItem(saved.key(0), JSON.stringify(damaged));
    assert.throws(() => client.pending(), /required operations are invalid/);
    assert.equal(saved.length, 1);
  }
});

test("a matching UUID cannot clear reviewed obligations without their exact persisted acknowledgement", () => {
  const client = bind(storage()), request = client.prepare("Request", contract());
  for (const response of [ack(request), {...ack(request), workflow_contract: contract()},
    {...ack(request), workflow_contract: contract(), workflow_contract_hash: "A".repeat(64)},
    {...ack(request), workflow_contract: {version: 1, steps: []}, workflow_contract_hash: "a".repeat(64)}]) {
    assert.throws(() => client.acknowledge(response), /reviewed required operations/);
    assert.deepEqual(client.pending(), request);
  }
  client.acknowledge({...ack(request), workflow_contract: contract(), workflow_contract_hash: "a".repeat(64)});
  assert.equal(client.pending(), null);
});
