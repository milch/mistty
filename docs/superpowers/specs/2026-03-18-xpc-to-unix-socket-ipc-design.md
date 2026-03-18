# Replace CFMessagePort with Unix Domain Socket IPC

## Problem

The current CFMessagePort-based communication between the Mistty CLI and app has two issues:
1. The CLI cannot reliably find/connect to the app's Mach port service
2. Launchd plist management causes duplicate app launches

## Solution

Replace CFMessagePort with Unix domain sockets using length-prefixed framing. This is a transport-layer swap — the request/response format and service layer remain unchanged.

## Socket Location

`~/Library/Application Support/Mistty/mistty.sock`

The parent directory should be created with `0700` permissions if it does not exist.

## Wire Protocol

Unchanged from current implementation. Each message on the socket is length-prefixed:

```
[4 bytes: payload length as big-endian UInt32][payload bytes]
```

**Maximum message size:** 16 MB. Reject any message declaring a length above this.

**Request payload:** JSON with `method` key + params (same as today).

```json
{"method": "createSession", "name": "Default", "directory": "/tmp"}
```

**Response payload:** First byte is status (`0x00` = success, `0x01` = error), rest is JSON data (same as today).

**Connection model:** One request/response per connection. CLI connects, sends request, reads response, disconnects.

## Server Side (IPCListener)

The app listens on the Unix domain socket.

**Lifecycle:**
- `start()`: Unconditionally unlink any existing socket file, then create socket, bind, and listen (backlog: 5).
- `stop()`: Close socket, delete socket file.

**Connection handling:**
- Accept connections on a background `DispatchQueue`.
- Per connection: read length-prefixed request → dispatch to `MisttyIPCService` → write length-prefixed response → close connection.
- Per-connection read timeout of 5 seconds to avoid leaked file descriptors from misbehaving clients.
- All reads and writes must loop to handle short reads/writes.
- Set `SO_NOSIGPIPE` on accepted sockets to avoid SIGPIPE crashes when writing to a closed connection.

**Dispatch:** The existing routing logic (parse `method` key, call appropriate service method) stays the same. Only the transport changes.

**File:** `Mistty/Services/IPCListener.swift` (rewrite from CFMessagePort to Unix domain socket)

## Client Side (IPCClient)

**Connection flow:**
1. `connect()` — try to connect to the Unix domain socket.
2. If socket doesn't exist or connection is refused, launch app with `open -a Mistty`.
3. Retry with exponential backoff, up to ~3 seconds total.

**`call()` method:**
1. Write length-prefixed JSON request to socket (loop for short writes).
2. Read 4-byte length prefix, then loop-read that many bytes for response.
3. Check first byte for status, return data or throw error.
4. Close connection.

Set `SO_NOSIGPIPE` on the client socket as well.

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

- `MisttyServiceProtocol.swift`: Remove `@objc` attribute (was required for XPC/ObjC interop, not needed for Unix sockets).
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

## File Change Summary

| File | Action |
|------|--------|
| `Mistty/Services/IPCListener.swift` | Rewrite: CFMessagePort → Unix domain socket |
| `Mistty/Services/XPCService.swift` → `IPCService.swift` | Rename class to `MisttyIPCService` |
| `Mistty/Services/XPCListener.swift` | Delete (already done) |
| `Mistty/App/MisttyApp.swift` | Remove launchd cleanup, update service reference |
| `MisttyCLI/XPCClient.swift` | Rewrite transport: CFMessagePort → Unix domain socket |
| `MisttyCLI/Commands/*.swift` | Update from XPCClient proxy pattern to IPCClient.call() pattern |
| `MisttyShared/XPCConstants.swift` → `IPCConstants.swift` | Rename enum and update strings |
| `MisttyShared/MisttyServiceProtocol.swift` | Remove `@objc` |
| `MisttyTests/Services/XPCServiceTests.swift` → `IPCServiceTests.swift` | Rename references |
| Response models | No changes |
