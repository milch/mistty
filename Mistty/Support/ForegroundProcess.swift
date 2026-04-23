import Darwin
import Foundation

struct ForegroundProcess: Equatable {
  let executable: String     // basename, e.g. "nvim"
  let path: String           // full path, e.g. "/usr/local/bin/nvim"
  let argv: [String]         // includes argv[0]
  let pid: pid_t
}

/// Injectable probe so tests can drive the resolver without a real pane.
/// Every closure returns `-1` / `nil` for the "unavailable" case.
struct ForegroundProcessProbe {
  var ptyFD: () -> Int32
  var shellPID: () -> pid_t
  var tcgetpgrpOnPTY: (Int32) -> pid_t
  var deepestDescendant: (pid_t) -> pid_t?
  var describe: (pid_t) -> ForegroundProcess?
}

enum ForegroundProcessResolver {
  /// Convenience entrypoint used in production — builds a probe backed by
  /// real syscalls and calls `current(via:)`.
  @MainActor
  static func current(for pane: MisttyPane) -> ForegroundProcess? {
    let probe = ForegroundProcessProbe(
      ptyFD: { pane.ptyFD },
      shellPID: { pane.shellPID },
      tcgetpgrpOnPTY: { fd in tcgetpgrp(fd) },
      deepestDescendant: Self.deepestLiveDescendant(of:),
      describe: Self.describe(pid:)
    )
    return current(via: probe)
  }

  /// Pure dispatch logic; all I/O lives in the probe closures.
  static func current(via probe: ForegroundProcessProbe) -> ForegroundProcess? {
    // Primary: tcgetpgrp on the pty.
    let fd = probe.ptyFD()
    if fd >= 0 {
      let pgid = probe.tcgetpgrpOnPTY(fd)
      if pgid > 0 {
        let shell = probe.shellPID()
        if pgid != shell {
          if let described = probe.describe(pgid) { return described }
        } else {
          // Shell is foreground — no user program running, explicit nil.
          return nil
        }
      }
    }
    // Fallback: deepest descendant of shell PID.
    let shell = probe.shellPID()
    guard shell > 0, let deepest = probe.deepestDescendant(shell), deepest != shell
    else { return nil }
    return probe.describe(deepest)
  }

  // MARK: - Real-syscall helpers

  /// BFS through children of `rootPid`, returning the deepest PID still alive.
  /// Uses `proc_listpids(PROC_PPID_ONLY, parent, …)` to enumerate at each level.
  static func deepestLiveDescendant(of rootPid: pid_t) -> pid_t? {
    var deepest: pid_t? = nil
    var frontier = [rootPid]
    while !frontier.isEmpty {
      var next: [pid_t] = []
      for parent in frontier {
        let children = Self.childrenOf(parent)
        next.append(contentsOf: children)
      }
      if let last = next.last { deepest = last }
      frontier = next
    }
    return deepest
  }

  private static func childrenOf(_ parent: pid_t) -> [pid_t] {
    // proc_listpids signature: (type, typeinfo, buffer, buffersize)
    let count = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
    guard count > 0 else { return [] }
    let bufSize = Int(count) * MemoryLayout<pid_t>.stride
    var buf = [pid_t](repeating: 0, count: Int(count))
    let actual = buf.withUnsafeMutableBufferPointer { ptr in
      proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), ptr.baseAddress, Int32(bufSize))
    }
    guard actual > 0 else { return [] }
    let n = Int(actual) / MemoryLayout<pid_t>.stride
    return Array(buf.prefix(n).filter { $0 > 0 })
  }

  /// Resolve `pid` to a full `ForegroundProcess` via `proc_pidpath` +
  /// `KERN_PROCARGS2`. Returns nil if either call fails.
  static func describe(pid: pid_t) -> ForegroundProcess? {
    // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4096; the macro is not importable by Swift.
    var pathBuf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
    guard n > 0 else { return nil }
    let path = pathBuf.withUnsafeBufferPointer { buf in
      String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    let executable = (path as NSString).lastPathComponent
    let argv = Self.readArgv(pid: pid) ?? [executable]
    return ForegroundProcess(executable: executable, path: path, argv: argv, pid: pid)
  }

  /// Read argv via `sysctl [CTL_KERN, KERN_PROCARGS2, pid]`. Layout:
  /// `int argc` (aligned), `argv[0]`, `argv[1]`, ..., `env[0]`, ...,
  /// all nul-terminated. We return only the first `argc` strings after the
  /// int header. Falls back to nil on malformed buffer.
  static func readArgv(pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    // First pass: size
    if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size < MemoryLayout<Int32>.size {
      return nil
    }
    var buf = [UInt8](repeating: 0, count: size)
    if sysctl(&mib, 3, &buf, &size, nil, 0) != 0 { return nil }
    return buf.withUnsafeBufferPointer { ptr in
      let base = ptr.baseAddress!
      let argc = base.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
      var offset = MemoryLayout<Int32>.size
      // Skip argv[0]'s leading nulls (executable path echoed before argv).
      while offset < size && base[offset] == 0 { offset += 1 }
      // Skip the executable path (one nul-terminated string).
      while offset < size && base[offset] != 0 { offset += 1 }
      offset += 1  // past the nul
      var result: [String] = []
      var remaining = Int(argc)
      while remaining > 0 && offset < size {
        let start = offset
        while offset < size && base[offset] != 0 { offset += 1 }
        if offset >= size { return nil }
        let bytes = Array(ptr[start..<offset])
        let s = String(bytes: bytes, encoding: .utf8) ?? ""
        result.append(s)
        offset += 1
        remaining -= 1
      }
      return result.isEmpty ? nil : result
    }
  }
}
