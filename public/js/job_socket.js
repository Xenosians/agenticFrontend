/* Read-only Phoenix channel observation. Job results always come from the
 * authenticated HTTP API; socket messages only request a fresh read. */
(function (root) {
  "use strict";

  function create(baseUrl, jobId, csrfToken, pollIntervalMs, isCurrent, onMode, onProgress, dependencies) {
    const env = dependencies || root;
    const schedule = env.setTimeout.bind(env);
    const cancel = env.clearTimeout.bind(env);
    const topic = "job:" + jobId;
    let stopped = false;
    let socket = null;
    let reconnectTimer, heartbeatTimer, replyTimer, contextTimer, joinTimer, tokenTimer;
    let waiter = null;
    let dirty = false;
    let live = false;
    let retryDelay = 1000;
    let reference = 0;
    let joinRef = "";
    let heartbeatRef = "";
    let controller = null;
    let attempt = null;
    const stages = new Set(["routing", "planning", "executing", "synthesizing", "waiting_provider"]);

    function current() {
      return !stopped && isCurrent();
    }

    function signal() {
      dirty = true;
      if (waiter) waiter();
    }

    function mode(value) {
      if (current()) onMode(value);
    }

    function close() {
      if (stopped) return;
      stopped = true;
      for (const timer of [reconnectTimer, heartbeatTimer, replyTimer, contextTimer, joinTimer, tokenTimer]) cancel(timer);
      if (controller) controller.abort();
      if (socket) {
        socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
        socket.close();
        socket = null;
      }
      if (waiter) waiter();
    }

    function checkContext() {
      if (!current()) return close();
      contextTimer = schedule(checkContext, 500);
    }

    function reconnect(connection) {
      if (connection !== socket || !current()) return;
      connection.onopen = connection.onmessage = connection.onclose = connection.onerror = null;
      connection.close();
      socket = null;
      live = false;
      for (const timer of [heartbeatTimer, replyTimer, joinTimer]) cancel(timer);
      mode("reconnecting");
      signal();
      reconnectTimer = schedule(connect, retryDelay);
      retryDelay = Math.min(retryDelay * 2, 15000);
    }

    function send(connection, frame) {
      if (connection === socket && connection.readyState === 1) {
        connection.send(JSON.stringify(frame));
        return true;
      }
      return false;
    }

    function heartbeat(connection) {
      if (!current() || connection !== socket || !live) return;
      heartbeatRef = String(++reference);
      if (!send(connection, [null, heartbeatRef, "phoenix", "heartbeat", {}])) return reconnect(connection);
      replyTimer = schedule(() => reconnect(connection), 10000);
      heartbeatTimer = schedule(() => heartbeat(connection), 25000);
    }

    async function connect() {
      if (!current()) return close();
      if (typeof env.WebSocket !== "function") return mode("polling");
      mode(retryDelay > 1000 ? "reconnecting" : "connecting");
      try {
        controller = typeof env.AbortController === "function" ? new env.AbortController() : null;
        tokenTimer = schedule(() => { if (controller) controller.abort(); }, 10000);
        const response = await env.fetch(baseUrl + "/api/v2/jobs/socket-token", {
          method: "POST", credentials: "include", mode: "cors",
          headers: {"Content-Type": "application/json", "X-CSRF-Token": csrfToken},
          body: "{}", ...(controller ? {signal: controller.signal} : {})
        });
        if (!current()) return close();
        if (!response.ok) {
          // Unsupported deployments and lost authorization keep the existing
          // HTTP recovery path. Never loop a failed credential request.
          mode("polling");
          return;
        }
        const data = await response.json();
        cancel(tokenTimer);
        if (!current()) return close();
        if (!data || typeof data.token !== "string" || !data.token) return mode("polling");
        const address = new URL(baseUrl + "/socket/websocket");
        address.protocol = address.protocol === "https:" ? "wss:" : "ws:";
        address.search = "?vsn=2.0.0";
        const encoded = env.btoa(data.token).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
        const connection = new env.WebSocket(address.href, ["phoenix", "base64url.bearer.phx." + encoded]);
        socket = connection;
        joinRef = String(++reference);
        joinTimer = schedule(() => reconnect(connection), 10000);
        connection.onopen = () => {
          if (!current()) return close();
          send(connection, [joinRef, joinRef, topic, "phx_join", {}]);
        };
        connection.onmessage = (event) => {
          if (!current()) return close();
          if (connection !== socket) return;
          let frame;
          try { frame = JSON.parse(event.data); } catch (_) { return; }
          if (!Array.isArray(frame) || frame.length !== 5) return;
          const [frameJoin, ref, frameTopic, eventName, payload] = frame;
          if (frameTopic === "phoenix" && eventName === "phx_reply" && ref === heartbeatRef) {
            cancel(replyTimer);
            return;
          }
          if (frameTopic !== topic || (frameJoin !== null && frameJoin !== joinRef)) return;
          if (eventName === "phx_reply" && ref === joinRef) {
            if (frameJoin !== joinRef) return;
            if (!payload || payload.status !== "ok" || !payload.response || payload.response.job_id !== jobId) {
              return reconnect(connection);
            }
            cancel(joinTimer);
            attempt = payload.response.attempts;
            live = true;
            retryDelay = 1000;
            mode("live");
            signal(); // Join is a new snapshot: always catch up through GET.
            heartbeatTimer = schedule(() => heartbeat(connection), 25000);
          } else if (eventName === "job_updated" && live && payload && payload.job_id === jobId) {
            attempt = payload.attempts;
            signal();
          } else if (eventName === "job_progress" && live && payload && payload.job_id === jobId &&
                     Number.isInteger(attempt) && payload.attempt === attempt && stages.has(payload.stage)) {
            onProgress(payload.stage);
          } else if (eventName === "phx_error" || eventName === "phx_close") {
            reconnect(connection);
          }
        };
        connection.onclose = connection.onerror = () => reconnect(connection);
      } catch (_) {
        if (!current()) return close();
        mode("polling");
        reconnectTimer = schedule(connect, retryDelay);
        retryDelay = Math.min(retryDelay * 2, 15000);
      } finally {
        cancel(tokenTimer);
      }
    }

    function wait() {
      if (!current()) { close(); return Promise.resolve(); }
      if (dirty) { dirty = false; return Promise.resolve(); }
      return new Promise((resolve) => {
        // A periodic authoritative read also recovers a missed event without
        // pretending the socket is a durable event log.
        const timer = schedule(finish, live ? Math.max(15000, pollIntervalMs) : pollIntervalMs);
        function finish() {
          if (waiter !== finish) return;
          cancel(timer);
          waiter = null;
          dirty = false;
          resolve();
        }
        waiter = finish;
      });
    }

    checkContext();
    void connect();
    return {wait, close};
  }

  root.AgenticJobSocket = Object.freeze({create});
  if (typeof module !== "undefined" && module.exports) module.exports = root.AgenticJobSocket;
})(globalThis);
