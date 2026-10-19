import std/unittest
import ../src/api/http_call

suite "sign-out confirmation":
  test "only a 2xx answer confirms that the server ended the session":
    for status in [200, 204]:
      check logoutOutcome(status) == loSignedOut

  test "401 means the session is already gone":
    check logoutOutcome(401) == loAlreadyEnded

  test "every other answer leaves the session possibly active":
    for status in [0, 302, 400, 403, 404, 408, 409, 429, 500, 502, 503, 504]:
      check logoutOutcome(status) == loUnconfirmed
