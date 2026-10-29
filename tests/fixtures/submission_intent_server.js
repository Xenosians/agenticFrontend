"use strict";
const {webcrypto} = require("node:crypto");

// The Phoenix submission-intent contract: the server allocates and keeps each
// request's identity. Its storage and receipt checks are tested in Phoenix.
function intentServer() {
  const slots = new Map();
  const hex = size => Buffer.from(webcrypto.getRandomValues(new Uint8Array(size / 2))).toString("hex");
  const reply = (status, body) => ({ok: status < 300, status, text: async () => JSON.stringify(body)});
  const slot = (kind, target) => ({schema: "submission-intent-slot.v1", kind, target_id: target,
    intent: structuredClone(slots.get(kind + ":" + target) ?? null)});
  const record = (kind, target, request, previous) => {
    const saved = {intent_id: hex(32), previous_id: previous, kind, target_id: target, state: "pending",
      request: {...structuredClone(request), submission_id: kind === "learning" ? hex(32) : webcrypto.randomUUID()},
      context: null, receipt: null, request_sha256: hex(64)};
    slots.set(kind + ":" + target, saved);
    return saved;
  };
  const withoutIdentity = request => { const copy = {...request}; delete copy.submission_id; return copy; };
  return {slots,
    seed: (kind, target, request) => record(kind, target, request, null).request,
    handle(url, options) {
      const address = new URL(url);
      if (options.method !== "POST") {
        return reply(200, slot(address.searchParams.get("kind"), address.searchParams.get("target_id")));
      }
      const body = JSON.parse(options.body);
      const current = slots.get(body.kind + ":" + body.target_id) ?? null;
      if (address.pathname.endsWith("/acknowledge")) {
        if (!current || current.intent_id !== body.intent_id) return reply(409, {error: "submission_intent_conflict"});
        current.state = "acknowledged";
        current.receipt = {submission_id: current.request.submission_id};
        return reply(200, slot(body.kind, body.target_id));
      }
      if (current && current.state === "pending") {
        return current.previous_id === body.expected_id && JSON.stringify(withoutIdentity(current.request)) === JSON.stringify(body.request)
          ? reply(200, slot(body.kind, body.target_id)) : reply(409, {error: "submission_intent_conflict"});
      }
      if ((current?.intent_id ?? null) !== body.expected_id) return reply(409, {error: "submission_intent_conflict"});
      // Like Phoenix, a contract above 32 KiB of UTF-8 JSON is refused before anything is stored.
      const contract = body.request.workflow_contract;
      if (contract !== undefined && Buffer.byteLength(JSON.stringify(contract)) > 32768) {
        return reply(422, {error: "invalid_submission_intent"});
      }
      record(body.kind, body.target_id, body.request, body.expected_id);
      return reply(200, slot(body.kind, body.target_id));
    }};
}

module.exports = {intentServer};
