# Audit Fixes Wave 4a-IPC: Versioned Envelope + Structured Errors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** IPC error codes survive the wire (CLI can distinguish not-found from failed, with distinct exit codes), requests carry a protocol version, and the listener can no longer accumulate unbounded parked threads when the main thread is busy.

**Architecture / compat story:** Requests stay flat JSON but gain a `"v": 1` key (old servers ignore unknown keys). Error responses stay `[0x01][payload]`, but when the request declared `v >= 1` the payload is JSON `{"code": <Int>, "message": <String>}`; for v-less (old) clients it remains plain text. The new CLI falls back to plain-text parsing when the payload isn't JSON (old server). Net: old CLI ↔ new app and new CLI ↔ old app both work. Exit codes: `entityNotFound` → 2, `invalidArgument` → 3, anything else → 1.

**Tech Stack:** Swift/SwiftPM, XCTest. Known-bad baseline: 23 `ChromePolishSnapshotTests` failures in full-suite runs; anything else is a regression. Tee logs, grep them.

---

### Task 1: Wire-error codec in MisttyShared (TDD)

**Files:**
- Modify: `MisttyShared/IPCConstants.swift`
- Test: Create `MisttyTests/IPC/IPCWireErrorTests.swift` (check whether a better-fitting existing test dir/file exists for IPCConstants — `buildVariantSuffix` already has tests somewhere; co-locate if sensible)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest

@testable import MisttyShared

final class IPCWireErrorTests: XCTestCase {
  func test_encodeDecode_roundTripsCodeAndMessage() {
    let err = MisttyIPC.error(.entityNotFound, "Tab 5 not found")
    let data = MisttyIPC.encodeWireError(err)
    let decoded = MisttyIPC.decodeWireError(data)
    XCTAssertEqual(decoded?.code, .entityNotFound)
    XCTAssertEqual(decoded?.message, "Tab 5 not found")
  }

  func test_encode_foreignError_usesOperationFailedAndDescription() {
    let err = NSError(domain: "other", code: 99,
                      userInfo: [NSLocalizedDescriptionKey: "boom"])
    let decoded = MisttyIPC.decodeWireError(MisttyIPC.encodeWireError(err))
    XCTAssertEqual(decoded?.code, .operationFailed)
    XCTAssertEqual(decoded?.message, "boom")
  }

  func test_decode_plainText_returnsNil() {
    XCTAssertNil(MisttyIPC.decodeWireError(Data("Tab 5 not found".utf8)))
  }
}
```

- [ ] **Step 2: Run to verify compile failure** (`cannot find 'encodeWireError'`)

- [ ] **Step 3: Implement in `MisttyShared/IPCConstants.swift`**

```swift
    /// Wire protocol version the CLI sends as `"v"` in each request.
    /// v0 (key absent) = legacy client: server replies to errors with
    /// plain text. v1+: server replies with the structured JSON below.
    public static let protocolVersion = 1

    /// Structured error payload carried after the 0x01 status byte for
    /// v1+ clients. Codable so both ends share one definition.
    public struct WireError: Codable, Equatable {
        public let code: Int
        public let message: String
    }

    /// Encode an error for the wire. Errors minted by `MisttyIPC.error`
    /// keep their code; foreign errors map to `.operationFailed`.
    public static func encodeWireError(_ error: Error) -> Data {
        let ns = error as NSError
        let code = ns.domain == errorDomain
            ? (ErrorCode(rawValue: ns.code) ?? .operationFailed)
            : .operationFailed
        let wire = WireError(code: code.rawValue, message: ns.localizedDescription)
        return (try? JSONEncoder().encode(wire)) ?? Data(ns.localizedDescription.utf8)
    }

    /// Decode a structured wire error; nil when the payload is legacy
    /// plain text (old server) or unparseable.
    public static func decodeWireError(_ data: Data) -> (code: ErrorCode, message: String)? {
        guard let wire = try? JSONDecoder().decode(WireError.self, from: data) else { return nil }
        return (ErrorCode(rawValue: wire.code) ?? .operationFailed, wire.message)
    }
```

- [ ] **Step 4: Tests pass; commit** — `feat(ipc): structured wire-error codec in MisttyShared` (+ Co-Authored-By trailer, as for all commits in this plan).

---

### Task 2: Server side — version-aware error replies + bounded connection concurrency

**Files:**
- Modify: `Mistty/Services/IPCListener.swift`

- [ ] **Step 1: Version-aware errors in `handleConnection`**

Current shape (post-Wave-3): parse JSON → semaphore-dispatch → on `responseError` write `errorResponse(errorMsg)`. Change to:

1. After parsing `json`, read `let clientVersion = json["v"] as? Int ?? 0`.
2. The reply closure captures the full `Error?` (not just `localizedDescription`): change `var responseError: String?` to `var responseError: Error?` and store the error object.
3. Error write path:

```swift
    if let error = responseError {
      let payload = clientVersion >= 1
        ? MisttyIPC.encodeWireError(error)
        : Data(error.localizedDescription.utf8)
      var result = Data([0x01])
      result.append(payload)
      UnixSocket.sendFrame(fd: fd, payload: result)
    } else { ... unchanged success path ... }
```

(Adjust to the file's current local helpers; `errorResponse(_: String)` can be deleted if nothing else uses it.)

- [ ] **Step 2: Bounded concurrency + main-actor wait timeout**

In `acceptLoop`, add a static limiter next to the existing setup:

```swift
  /// At most this many connections may be in flight (each parks a GCD
  /// worker on the main-actor reply). Backpressure: when saturated, the
  /// accept loop blocks until a slot frees instead of growing the pool
  /// toward GCD's ~64-thread limit while the main thread is busy.
  private static let connectionSlots = DispatchSemaphore(value: 16)
```

Acquire before dispatching each connection, release when it finishes:

```swift
      IPCListener.connectionSlots.wait()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { IPCListener.connectionSlots.signal() }
        handleConnection(clientFD, service: service)
      }
```

In `handleConnection`, replace the unbounded `semaphore.wait()` (the per-request dispatch one, not the slots) with a timeout so a modal-blocked main thread can't park workers forever:

```swift
    if semaphore.wait(timeout: .now() + 10) == .timedOut {
      let message = "Mistty.app did not respond within 10s (main thread busy?)"
      let payload = clientVersion >= 1
        ? MisttyIPC.encodeWireError(MisttyIPC.error(.operationFailed, message))
        : Data(message.utf8)
      var result = Data([0x01])
      result.append(payload)
      UnixSocket.sendFrame(fd: fd, payload: result)
      return
    }
```

(The late-arriving reply closure firing after timeout must be harmless: it only writes captured locals; it must NOT touch the closed fd. Ensure the post-timeout `return` path is the only fd writer — the reply closure just sets vars + signals.)

- [ ] **Step 3: Build + full suite** — baseline failures only. Preserve Wave 1 hardening (getpeereid, chmod) untouched.

- [ ] **Step 4: Commit** — `feat(ipc): version-aware structured errors + bounded listener concurrency`.

---

### Task 3: CLI side — send v1, decode structured errors, distinct exit codes

**Files:**
- Modify: `MisttyCLI/IPCClient.swift`, `MisttyCLI/IPCRun.swift`

- [ ] **Step 1: `IPCClient`**

1. In `call`, after `request["method"] = method`, add `request["v"] = MisttyIPC.protocolVersion`.
2. Extend the error enum (keep `.remoteError(String)` for legacy/plain-text — `VersionCommand` pattern-matches it and must keep working against old servers):

```swift
    case remoteCoded(code: MisttyIPC.ErrorCode, message: String)
```
with `description` returning the message. 
3. Status-byte handling:

```swift
        if statusByte == 0x01 {
            let payload = Data(payload)
            if let structured = MisttyIPC.decodeWireError(payload) {
                throw IPCClientError.remoteCoded(code: structured.code, message: structured.message)
            }
            let message = String(data: payload, encoding: .utf8) ?? "Unknown error"
            throw IPCClientError.remoteError(message)
        }
```

- [ ] **Step 2: `IPCRun` exit codes**

In `IPCRun.call`'s catch:

```swift
        } catch {
            formatter.printError(error.localizedDescription)
            Foundation.exit(Self.exitCode(for: error))
        }
```
with:

```swift
    /// Distinct exit codes so scripts can branch without parsing stderr:
    /// 2 = entity not found, 3 = invalid argument, 1 = everything else.
    static func exitCode(for error: Error) -> Int32 {
        guard case IPCClientError.remoteCoded(let code, _) = error else { return 1 }
        switch code {
        case .entityNotFound: return 2
        case .invalidArgument: return 3
        case .operationFailed: return 1
        }
    }
```

Printed output must remain byte-identical (`Error: <message>`); only the exit code differentiates.

- [ ] **Step 3: Verify**

Build; full suite at baseline. If the app is running, live-check: `mistty tab get 99999; echo $status` → prints `Error: Tab 99999 not found`, exits **2** (new server) — and `mistty session list` still works.

- [ ] **Step 4: Commit** — `feat(cli): structured IPC errors with distinct exit codes`.

---

### Final verification
- [ ] Full suite: baseline-only failures. One commit per task.
