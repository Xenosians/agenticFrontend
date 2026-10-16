import std/[asyncjs, jsffi]

proc observeJob*(baseUrl, jobId, csrfToken: cstring, pollIntervalMs: int,
                 isCurrent: proc(): bool, onMode: proc(mode: cstring),
                 onProgress: proc(stage: cstring)): JsObject {.
  importjs: "globalThis.AgenticJobSocket.create(#, #, #, #, #, #, #)"
.}

proc waitForUpdate*(observer: JsObject): Future[void] {.importjs: "#.wait()".}
proc closeObservation*(observer: JsObject) {.importjs: "#.close()".}
