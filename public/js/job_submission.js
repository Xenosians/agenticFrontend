/* Pending submissions keep one identity across a lost acknowledgement or reload.
 * Records are scoped to the backend, signed-in owner and chat. No credentials
 * are stored, and an acknowledgement never means the job itself succeeded. */
(function (root) {
  "use strict";
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  const states = new Set(["pending", "processing", "waiting_approval", "completed", "failed", "denied", "outcome_unknown"]);
  const prefix = "janus.pending-submission.v1:";

  function canonical(value) {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
    return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}";
  }

  function workflowContract(value) {
    if (value === undefined || value === null) return null;
    const fail = () => { throw new Error("The required operations are invalid. Review them before sending."); };
    const keys = (row, expected) => row && typeof row === "object" && !Array.isArray(row) &&
      Object.keys(row).sort().join(",") === expected.slice().sort().join(",");
    if (!keys(value, ["version", "steps"]) || value.version !== 1 || !Array.isArray(value.steps) ||
        value.steps.length < 1 || value.steps.length > 8) fail();
    const ids = new Set(), capabilities = new Set();
    for (const step of value.steps) {
      if (!keys(step, ["id", "capability", "grounded_arguments", "after_success_of"]) ||
          typeof step.id !== "string" || !/^[A-Za-z][A-Za-z0-9_-]{0,79}$/.test(step.id) || ids.has(step.id) ||
          typeof step.capability !== "string" || !/^[A-Za-z0-9_.-]{1,150}$/.test(step.capability) || capabilities.has(step.capability) ||
          !(step.after_success_of === null || typeof step.after_success_of === "string" && ids.has(step.after_success_of)) ||
          !step.grounded_arguments || typeof step.grounded_arguments !== "object" || Array.isArray(step.grounded_arguments)) fail();
      const argumentNames = Object.keys(step.grounded_arguments);
      if (argumentNames.length > 32 || argumentNames.some(name => !/^[A-Za-z_][A-Za-z0-9_]{0,149}$/.test(name))) fail();
      for (const values of Object.values(step.grounded_arguments)) {
        if (!Array.isArray(values) || values.length < 1 || values.length > 16 ||
            values.some(item => typeof item !== "string" || !item.trim() || [...item].length > 1024)) fail();
      }
      ids.add(step.id); capabilities.add(step.capability);
    }
    // encodeURIComponent counts the UTF-8 bytes without relying on optional
    // browser globals. It also rejects malformed Unicode rather than altering it.
    if (encodeURIComponent(JSON.stringify(value)).replace(/%[A-F\d]{2}/gi, "x").length > 32768) fail();
    return JSON.parse(JSON.stringify(value));
  }

  function create(storage, crypto, backend, owner, chat) {
    if (![backend, owner, chat].every(value => typeof value === "string" && value.length > 0)) {
      throw new Error("A signed-in owner and saved chat are required before submission.");
    }
    const key = prefix + JSON.stringify([backend, owner, chat]);

    function pending() {
      const text = storage.getItem(key);
      if (text === null) return null;
      let saved;
      try { saved = JSON.parse(text); } catch (_) {
        throw new Error("The saved submission is unreadable. Do not submit again before checking the chat's saved jobs.");
      }
      if (!saved || saved.version !== 1 || !uuid.test(saved.submission_id) ||
          saved.backend !== backend || saved.owner !== owner || saved.chat_id !== chat ||
          typeof saved.message !== "string" || !saved.message.trim()) {
        throw new Error("The saved submission is invalid. Check the chat's saved jobs before submitting again.");
      }
      workflowContract(saved.workflow_contract);
      return saved;
    }

    function prepare(message, contract) {
      if (typeof message !== "string" || !message.trim()) throw new Error("Enter a message before submitting.");
      const reviewed = workflowContract(contract);
      const saved = pending();
      if (saved) {
        if (saved.message !== message || canonical(saved.workflow_contract ?? null) !== canonical(reviewed)) {
          throw new Error("Check the unresolved submission before starting a different request in this chat.");
        }
        return saved;
      }
      if (!crypto || typeof crypto.randomUUID !== "function") throw new Error("This browser cannot create a safe submission identity.");
      const identity = crypto.randomUUID();
      if (!uuid.test(identity)) throw new Error("The browser returned an invalid submission identity.");
      const record = {version: 1, backend, owner, chat_id: chat, submission_id: identity, message};
      if (reviewed !== null) record.workflow_contract = reviewed;
      storage.setItem(key, JSON.stringify(record)); // Persist before the first POST, or fail closed.
      return record;
    }

    function acknowledge(response) {
      const saved = pending();
      if (!saved || !response || response.submission_id !== saved.submission_id ||
          typeof response.job_id !== "string" || !response.job_id || !states.has(response.status)) {
        throw new Error("The response did not confirm the saved submission. Reopen this chat to recover its outcome.");
      }
      if (saved.workflow_contract && (canonical(response.workflow_contract) !== canonical(saved.workflow_contract) ||
          typeof response.workflow_contract_hash !== "string" || !/^[0-9a-f]{64}$/.test(response.workflow_contract_hash))) {
        throw new Error("The response did not confirm the reviewed required operations. Recover the same saved submission.");
      }
      storage.removeItem(key);
      return response;
    }

    function reject(identity) {
      const saved = pending();
      if (saved && saved.submission_id === identity) storage.removeItem(key);
    }
    return Object.freeze({prepare, pending, acknowledge, reject});
  }

  function clearOwner(storage, backend, owner) {
    // Explicit sign-out clears pending request text from this browser tab.
    const keys = [];
    for (let index = 0; index < storage.length; index++) {
      const key = storage.key(index);
      if (!key || !key.startsWith(prefix)) continue;
      try {
        const scope = JSON.parse(key.slice(prefix.length));
        if (scope[0] === backend && scope[1] === owner) keys.push(key);
      } catch (_) { /* Unrelated invalid keys cannot grant access or execute. */ }
    }
    for (const key of keys) storage.removeItem(key);
  }
  root.AgenticJobSubmission = Object.freeze({create, clearOwner});
  if (typeof module !== "undefined" && module.exports) module.exports = root.AgenticJobSubmission;
})(globalThis);
