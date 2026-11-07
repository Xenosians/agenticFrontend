"""Streamed answer preview (SRS 1.9 FR-080).

While a job runs, the answer being written appears as a preview in the
progress row; the saved result read over HTTP replaces it, and the preview
never becomes part of the conversation. The socket is an in-page fake that
speaks the Phoenix frame format; no deployment service, credential, provider
or model is used.
Run after rebuilding: python tests/test_answer_streaming.py
"""
import json
import unittest
from urllib.parse import urlparse

from playwright.sync_api import expect

import test_chat_navigation as navigation

# A Phoenix-shaped socket: it answers the join, then the test pushes frames
# into it through window.answerFixture.push(...).
FAKE_SOCKET = """
(() => {
  const sockets = [];
  class FixtureSocket {
    constructor(url, protocols) {
      this.url = url; this.protocols = protocols; this.readyState = 0; sockets.push(this);
      setTimeout(() => { this.readyState = 1; this.onopen && this.onopen(); }, 0);
    }
    send(data) {
      const [joinRef, ref, topic, event] = JSON.parse(data);
      if (event === "phx_join") {
        this.joinRef = joinRef;
        this.topic = topic;
        setTimeout(() => this.deliver([joinRef, ref, topic, "phx_reply", {
          status: "ok", response: {job_id: "fixture-job", status: "processing", attempts: 1}}]), 0);
      }
    }
    deliver(frame) { this.onmessage && this.onmessage({data: JSON.stringify(frame)}); }
    close() { this.readyState = 3; }
  }
  window.WebSocket = FixtureSocket;
  window.answerFixture = {
    joined: () => sockets.some(socket => socket.joinRef),
    push: (event, payload) => {
      for (const socket of sockets) {
        if (socket.joinRef) socket.deliver([socket.joinRef, null, socket.topic, event, payload]);
      }
    },
  };
})();
"""


class AnswerStreamingTests(navigation.ChatNavigationTests):
    def setUp(self):
        self.job_status = "processing"
        super().setUp()
        self.context.add_init_script(FAKE_SOCKET)
        self.page.set_default_timeout(5000)

    def route(self, route):
        request = route.request
        path = urlparse(request.url).path
        if request.url.startswith(self.base + "/"):
            if path == "/api/v2/jobs/socket-token" and request.method == "POST":
                route.fulfill(json={"token": "fixture-socket-token"})
                return
            if path == "/api/v1/jobs" and request.method == "POST":
                payload = request.post_data_json
                self.submissions.append(payload)
                route.fulfill(json={"job_id": "fixture-job", "status": "pending",
                                    "submission_id": payload["submission_id"]})
                return
            if path == "/api/v2/jobs/fixture-job":
                result = {"answer": "The VPN is up on both routers."} if self.job_status == "completed" else {}
                body = {"contract_version": 2, "job_id": "fixture-job", "attempts": 1,
                        "status": self.job_status, "result": result}
                if self.job_status == "failed":
                    body["error"] = "The model provider did not finish the answer."
                route.fulfill(json=body)
                return
        super().route(route)

    def send(self, text):
        self.open_first_chat()
        self.page.locator("#messageInput").fill(text)
        self.page.locator("#messageInput").press("Enter")
        self.wait_for_predicate("window.answerFixture.joined()")

    def push_text(self, sequence, text, attempt=1):
        self.page.evaluate("([payload]) => window.answerFixture.push('job_answer_text', payload)",
                           [{"job_id": "fixture-job", "attempt": attempt, "sequence": sequence, "text": text}])

    def finish(self, status):
        # Phoenix announces every saved change on the job channel; the page then
        # reads the saved job over HTTP.
        self.job_status = status
        self.page.evaluate("([payload]) => window.answerFixture.push('job_updated', payload)",
                           [{"job_id": "fixture-job", "status": status, "attempts": 1}])

    def preview(self):
        return self.page.locator(".job-progress .answer-preview")

    def test_the_answer_appears_while_it_is_written_and_the_saved_answer_replaces_it(self):
        self.send("Is the VPN up?")
        self.push_text(1, "The VPN ")
        self.push_text(2, "is up")
        expect(self.preview()).to_have_text("The VPN is up")
        expect(self.page.locator(".job-progress")).to_contain_text("Writing the answer")
        # The preview is not a message: nothing is added to the conversation yet.
        expect(self.page.locator(".message-row.assistant .message-bubble")).to_have_count(0)
        self.finish("completed")
        expect(self.page.locator(".message-bubble.assistant")).to_contain_text("The VPN is up on both routers.")
        expect(self.preview()).to_have_count(0)
        expect(self.page.locator(".message-bubble.assistant")).to_have_count(1)
        self.assertEqual(self.errors, [])

    def test_a_preview_from_another_attempt_or_job_is_never_shown(self):
        self.send("Is the VPN up?")
        self.push_text(1, "stale attempt", attempt=2)
        self.page.evaluate("() => window.answerFixture.push('job_answer_text', "
                           "{job_id: 'other-job', attempt: 1, sequence: 1, text: 'other job'})")
        self.push_text(1, "Current")
        expect(self.preview()).to_have_text("Current")
        self.assertEqual(self.errors, [])

    def test_a_failed_job_clears_the_preview_and_keeps_no_partial_answer(self):
        self.send("Is the VPN up?")
        self.push_text(1, "Partial answer")
        expect(self.preview()).to_have_text("Partial answer")
        self.finish("failed")
        expect(self.preview()).to_have_count(0)
        expect(self.page.get_by_text("Partial answer")).to_have_count(0)
        self.assertEqual(self.errors, [])

    def test_the_preview_is_plain_text_and_keeps_the_page_readable(self):
        # Markdown and markup are shown as typed; the saved answer is the one rendered.
        self.send("Is the VPN up?")
        self.push_text(1, "<img src=x onerror=alert(1)> **bold** " + "long-word" * 60)
        expect(self.preview()).to_contain_text("<img src=x onerror=alert(1)> **bold**")
        self.assertEqual(self.page.locator(".job-progress img").count(), 0)
        self.assertFalse(self.page.evaluate("() => document.documentElement.scrollWidth > window.innerWidth"))
        self.assertEqual(self.errors, [])


def load_tests(loader, _tests, _pattern):
    return unittest.TestSuite(AnswerStreamingTests(name) for name in loader.getTestCaseNames(AnswerStreamingTests)
                             if name in AnswerStreamingTests.__dict__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
