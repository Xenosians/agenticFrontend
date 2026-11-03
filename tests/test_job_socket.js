"use strict";
const {test} = require("node:test");
const assert = require("node:assert/strict");
const {create} = require("../public/js/job_socket.js");

function fixture(options = {}) {
  let now = 0, sequence = 0, current = true;
  const timers = new Map(), requests = [], sockets = [], modes = [], progress = [], answers = [];
  const env = {
    setTimeout(fn, delay) { const id = ++sequence; timers.set(id, {at: now + delay, fn}); return id; },
    clearTimeout(id) { timers.delete(id); },
    btoa(value) { return Buffer.from(value, "binary").toString("base64"); },
    AbortController,
    async fetch(url, init) {
      requests.push({url, init});
      return {ok: options.ok !== false, json: async () => ({token: options.token || "private-token-" + requests.length})};
    },
    WebSocket: class {
      constructor(url, protocols) { this.url = url; this.protocols = protocols; this.sent = []; this.readyState = 0; sockets.push(this); }
      send(data) { this.sent.push(JSON.parse(data)); }
      close() { this.readyState = 3; this.closed = true; }
      open() { this.readyState = 1; this.onopen?.(); }
      receive(frame) { this.onmessage?.({data: JSON.stringify(frame)}); }
    }
  };
  if (options.unsupported) delete env.WebSocket;
  const observer = create("https://example.test", "job-123", "csrf-secret", 1000,
    () => current, value => modes.push(value), value => progress.push(value), env,
    (sequence, text) => answers.push([sequence, text]));
  async function settle() { for (let count = 0; count < 8; count++) await Promise.resolve(); }
  async function tick(duration) {
    const end = now + duration;
    while (true) {
      const next = [...timers].filter(([, timer]) => timer.at <= end).sort((a,b) => a[1].at - b[1].at)[0];
      if (!next) break;
      now = next[1].at;
      timers.delete(next[0]);
      next[1].fn();
      await settle();
    }
    now = end;
    await settle();
  }
  async function join(index = 0) {
    await settle();
    const socket = sockets[index];
    socket.open();
    const joinRef = socket.sent[0][0];
    socket.receive([joinRef, joinRef, "job:job-123", "phx_reply", {
      status: "ok", response: {job_id: "job-123", status: "processing", attempts: 1}
    }]);
    await settle();
    return {socket, joinRef};
  }
  return {observer, requests, sockets, modes, progress, answers, settle, tick, join,
    invalidate() { current = false; }, timerCount() { return timers.size; }};
}

test("uses cookie and CSRF for a short-lived token, never a credential URL", async () => {
  const f = fixture();
  const {socket} = await f.join();
  assert.equal(f.requests[0].url, "https://example.test/api/v2/jobs/socket-token");
  assert.equal(f.requests[0].init.credentials, "include");
  assert.equal(f.requests[0].init.headers["X-CSRF-Token"], "csrf-secret");
  assert.equal(socket.url, "wss://example.test/socket/websocket?vsn=2.0.0");
  assert.deepEqual(socket.protocols, ["phoenix", "base64url.bearer.phx." + Buffer.from("private-token-1").toString("base64").replace(/=/g, "")]);
  assert.deepEqual(socket.sent[0].slice(2), ["job:job-123", "phx_join", {}]);
  f.observer.close();
});

test("matches Phoenix's standard Base64 decoder even for URL-sensitive bytes", async () => {
  const f = fixture({token: "???~~~"});
  const {socket} = await f.join();
  assert.equal(socket.protocols[1], "base64url.bearer.phx.Pz8/fn5+");
  f.observer.close();
});

test("join and matching updates wake authoritative reads; untrusted frames do not", async () => {
  const f = fixture();
  const {socket, joinRef} = await f.join();
  await f.observer.wait(); // Initial join invalidates the HTTP snapshot.
  let woke = false;
  const waiting = f.observer.wait().then(() => { woke = true; });
  socket.receive([joinRef, null, "job:someone-else", "job_updated", {job_id: "someone-else"}]);
  socket.receive(["old-join", null, "job:job-123", "job_updated", {job_id: "job-123"}]);
  socket.receive([null, null, "job:job-123", "job_updated", {job_id: "someone-else"}]);
  socket.onmessage({data: "not-json"});
  await f.settle();
  assert.equal(woke, false);
  socket.receive([null, null, "job:job-123", "job_updated", {job_id: "job-123", attempts: 1, status: "completed", result: "untrusted"}]);
  await waiting;
  assert.equal(woke, true);
  assert.deepEqual(f.progress, []); // Socket payload never becomes a result card.
  f.observer.close();
});

test("disconnection polls while reconnecting and fetches a new token before joining", async () => {
  const f = fixture();
  const {socket} = await f.join();
  await f.observer.wait();
  socket.onclose();
  await f.observer.wait();
  assert.equal(f.modes.at(-1), "reconnecting");
  await f.tick(1000);
  assert.equal(f.requests.length, 2);
  const next = await f.join(1);
  assert.notDeepEqual(next.socket.protocols, socket.protocols);
  assert.equal(f.modes.at(-1), "live");
  await f.observer.wait(); // Rejoin forces a fresh authoritative GET.
  f.observer.close();
});

test("heartbeat loss reconnects, and acknowledgments keep a healthy channel alive", async () => {
  const f = fixture();
  const {socket} = await f.join();
  await f.tick(25000);
  const frame = socket.sent.at(-1);
  assert.deepEqual(frame.slice(2), ["phoenix", "heartbeat", {}]);
  socket.receive([null, frame[1], "phoenix", "phx_reply", {status: "ok", response: {}}]);
  await f.tick(10000);
  assert.equal(socket.closed, undefined);
  await f.tick(15000);
  await f.tick(10000);
  assert.equal(socket.closed, true);
  assert.equal(f.modes.at(-1), "reconnecting");
  f.observer.close();
});

test("unsupported socket deployments continue polling without retrying denied credentials", async () => {
  for (const options of [{ok: false}, {unsupported: true}]) {
    const f = fixture(options);
    await f.settle();
    assert.equal(f.modes.at(-1), "polling");
    let woke = false;
    const waiting = f.observer.wait().then(() => { woke = true; });
    await f.tick(999);
    assert.equal(woke, false);
    await f.tick(1);
    await waiting;
    await f.tick(20000);
    assert.equal(f.requests.length, options.unsupported ? 0 : 1);
    f.observer.close();
  }
});

test("context changes close the socket and release pending reads without delivering stale events", async () => {
  const f = fixture();
  const {socket, joinRef} = await f.join();
  await f.observer.wait();
  const waiting = f.observer.wait();
  f.invalidate();
  socket.receive([joinRef, null, "job:job-123", "job_progress", {job_id: "job-123", attempt: 1, stage: "executing"}]);
  await waiting;
  assert.equal(socket.closed, true);
  assert.deepEqual(f.progress, []);
  assert.equal(f.timerCount(), 0);
  await f.tick(60000);
  assert.equal(f.requests.length, 1);
});

test("only bounded stages for the current persisted attempt are shown", async () => {
  const f = fixture();
  const {socket, joinRef} = await f.join();
  for (const [attempt, stage] of [[0, "executing"], [1, "<script>"], [1, "routing"], [1, "waiting_provider"]]) {
    socket.receive([joinRef, null, "job:job-123", "job_progress", {job_id: "job-123", attempt, stage}]);
  }
  assert.deepEqual(f.progress, ["routing", "waiting_provider"]);
  socket.receive([joinRef, null, "job:job-123", "job_updated", {job_id: "job-123", attempts: 2}]);
  socket.receive([joinRef, null, "job:job-123", "job_progress", {job_id: "job-123", attempt: 1, stage: "executing"}]);
  assert.deepEqual(f.progress, ["routing", "waiting_provider"]);
  f.observer.close();
});

test("streamed answer text for the current attempt is passed on in order, once", async () => {
  const f = fixture();
  const {socket, joinRef} = await f.join();
  const frame = (attempt, sequence, text, jobId = "job-123") =>
    socket.receive([joinRef, null, "job:job-123", "job_answer_text", {job_id: jobId, attempt, sequence, text}]);
  frame(1, 1, "The VPN ");
  frame(1, 1, "The VPN ");      // a repeated part is ignored
  frame(0, 2, "stale attempt");
  frame(1, 2, "other job", "job-999");
  frame(1, 2, 42);
  frame(1, 0, "no sequence");
  frame(1, 3, "is up.");        // a gap keeps the order; nothing is reordered
  assert.deepEqual(f.answers, [[1, "The VPN "], [3, "is up."]]);
  socket.receive([joinRef, null, "job:job-123", "job_updated", {job_id: "job-123", attempts: 2}]);
  frame(1, 4, "old attempt");
  frame(2, 1, "Retry ");        // a new attempt starts its own sequence
  assert.deepEqual(f.answers, [[1, "The VPN "], [3, "is up."], [1, "Retry "]]);
  f.observer.close();
  frame(2, 2, "after close");
  assert.equal(f.answers.length, 3);
});

test("the live channel still performs periodic reads to recover missed notifications", async () => {
  const f = fixture();
  await f.join();
  await f.observer.wait();
  let woke = false;
  const waiting = f.observer.wait().then(() => { woke = true; });
  await f.tick(14999);
  assert.equal(woke, false);
  await f.tick(1);
  await waiting;
  assert.equal(woke, true);
  f.observer.close();
});
