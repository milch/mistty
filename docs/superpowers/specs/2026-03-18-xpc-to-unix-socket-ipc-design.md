# Replace XPC with Unix Domain Socket IPC

## Problem

The current XPC-based communication between the Mistty CLI and app has two issues:
1. The CLI cannot reliably find/connect to the app's XPC service
2. Launchd plist management causes duplicate app launches

## Solution

Replace XPC with Unix domain sockets using length-prefixed framing. This is a transport-layer swap — the request/response format and service layer remain unchanged.

## Socket Location

`~/Library/Application Support/Mistty/mistty.sock`

## Wire Protocol

Unchanged from current implementation. Each message on the socket is length-prefixed:

```
[4 bytes: payload length as big-endian UInt32][payload bytes]
```

**Request payload:** JSON with `method` key + params (same as today).

```json
{"method": "createSession", "name": "Default", "directory": "/tmp"}
```

**Response payload:** First byte is status (`0x00` = success, `0x01` = error), rest is JSON data (same as today).

**Connection model:** One request/response per connection. CLI connects, sends request, reads response, disconnects.

## Server Side (IPCListener)

The app listens on the Unix domain socket.

**Lifecycle:**
- `start()`: If a stale socket file exists, delete it. Create socket, bind, listen.
- `stop()`: Close socket, delete socket file.

**Connection handling:**
- Accept connections on a background `DispatchQueue`.
- Per connection: read length-prefixed request → dispatch to `MisttyIPCService` → write length-prefixed response → close connection.

**Dispatch:** The existing routing logic (parse `method` key, call appropriate service method) stays the same. Only the transport changes.

**File:** `Mistty/Services/IPCListener.swift` (rewrite from CFMessagePort to Unix domain socket)

## Client Side (IPCClient)

**Connection flow:**
1. `connect()` — try to connect to the Unix domain socket.
2. If socket doesn't exist or connection is refused, launch app with `open -a Mistty`.
3. Retry with exponential backoff (100ms, 200ms, 400ms, 800ms, 1.6s).

**`call()` method:**
1. Write length-prefixed JSON request to socket.
2. Read 4-byte length prefix, then read that many bytes for response.
3. Check first byte for status, return data or throw error.
4. Close connection.

**File:** `MisttyCLI/XPCClient.swift` (rewrite transport, class already renamed to `IPCClient`)

## Renames

All XPC naming is replaced with IPC naming since XPC is no longer used:

| Old | New |
|-----|-----|
| `MisttyXPCService` (class) | `MisttyIPCService` |
| `XPCService.swift` | `IPCService.swift` |
| `XPCConstants.swift` | `IPCConstants.swift` |
| `MisttyXPC` (enum) | `MisttyIPC` |
| `XPCServiceTests.swift` | `IPCServiceTests.swift` |

## Shared Protocol Cleanup

- `MisttyServiceProtocol.swift`: Remove `@objc` attribute (was required for XPC, not needed for Unix sockets).
- `IPCConstants.swift`: Update `serviceName` and `errorDomain` strings.

## App Entry Point

- `MisttyApp.swift`: Update `XPCService` → `IPCService` reference. Remove legacy launchd plist cleanup code.

## Deletions

- `Mistty/Services/XPCListener.swift` (already deleted in working tree).

## What Does Not Change

- All 28 CLI commands and their request/response format
- The dispatch routing logic
- The service implementation internals (session/tab/pane/window/popup CRUD)
- Response models (`SessionResponse`, `TabResponse`, etc.)
- Output formatting
- Auto-launch behavior
- CLI command files (they call `client.connect()` / `client.call()` which keep the same interface)

## File Change Summary

| File | Action |
|------|--------|
| `Mistty/Services/IPCListener.swift` | Rewrite: CFMessagePort → Unix domain socket |
| `Mistty/Services/XPCService.swift` → `IPCService.swift` | Rename class to `MisttyIPCService` |
| `Mistty/Services/XPCListener.swift` | Delete (already done) |
| `Mistty/App/MisttyApp.swift` | Remove launchd cleanup, update service reference |
| `MisttyCLI/XPCClient.swift` | Rewrite transport: CFMessagePort → Unix domain socket |
| `MisttyShared/XPCConstants.swift` → `IPCConstants.swift` | Rename enum and update strings |
| `MisttyShared/MisttyServiceProtocol.swift` | Remove `@objc` |
| `MisttyTests/Services/XPCServiceTests.swift` → `IPCServiceTests.swift` | Rename references |
| CLI command files | No changes |
| Response models | No changes |
