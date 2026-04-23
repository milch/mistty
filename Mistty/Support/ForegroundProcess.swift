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

  /// Basenames we treat as "nothing to capture" — plain shells where the
  /// user is at a prompt, plus macOS login-shell wrappers that ghostty
  /// inserts between the spawned command and the actual target process.
  /// On macOS a `cfg.command` pane gets spawned as
  /// `/usr/bin/login -flp $USER /bin/bash --noprofile --norc -c "exec -l $cmd"`,
  /// and login appears to fork rather than fully exec-through, so
  /// `login` (or whatever shim it currently uses) stays as the tracked
  /// pid while the real app runs as a descendant.
  static let shellExecutables: Set<String> = [
    "bash", "dash", "fish", "ksh", "login", "nu", "sh", "tcsh", "zsh",
  ]

  /// Pure dispatch logic; all I/O lives in the probe closures.
  static func current(via probe: ForegroundProcessProbe) -> ForegroundProcess? {
    // First: walk descendants of the spawned process. This catches both
    // "user typed `ssh host` at zsh" (descends zsh → ssh) and
    // "cfg.command = 'ssh host' went through login/bash/ssh" (descends
    // login → bash → ssh, or whatever subset macOS actually forks).
    let shell = probe.shellPID()
    if shell > 0, let deepest = probe.deepestDescendant(shell), deepest != shell,
       let described = probe.describe(deepest),
       !shellExecutables.contains(described.executable)
    {
      return described
    }
    // Second: tcgetpgrp on the pty, for cases where exec-chains (rather
    // than fork-chains) leave the spawned process's own pid as the
    // foreground app — e.g. a user ran `ssh host` bare in a pane spawned
    // without a cfg.command.
    let fd = probe.ptyFD()
    if fd >= 0 {
      let pgid = probe.tcgetpgrpOnPTY(fd)
      if pgid > 0, let described = probe.describe(pgid),
         !shellExecutables.contains(described.executable)
      {
        return described
      }
    }
    return nil
  }

  // MARK: - Real-syscall helpers

  /// BFS through descendants of `rootPid`, returning the deepest PID. When
  /// multiple children exist at the same depth the kernel's ordering decides
  /// which one wins — the fallback path is a heuristic, not a guarantee
  /// of "most-recently-forked." Reached only when `tcgetpgrp` is
  /// unavailable; callers should treat this as best-effort.
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
    // proc_listpids(type, typeinfo, buffer, buffersize-in-bytes). Both the
    // first probe and the second populated call return *bytes* written, not
    // pid count. We need to convert to pid_t elements.
    let byteCount = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
    guard byteCount > 0 else { return [] }
    let pidCapacity = Int(byteCount) / MemoryLayout<pid_t>.stride
    var buf = [pid_t](repeating: 0, count: pidCapacity)
    let actualBytes = buf.withUnsafeMutableBufferPointer { ptr in
      proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), ptr.baseAddress, byteCount)
    }
    guard actualBytes > 0 else { return [] }
    let n = Int(actualBytes) / MemoryLayout<pid_t>.stride
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
    let rawArgv = Self.readArgv(pid: pid) ?? [executable]
    let argv = Self.stripLoginShellDash(rawArgv, executable: executable)
    return ForegroundProcess(executable: executable, path: path, argv: argv, pid: pid)
  }

  /// Normalize argv[0] for login-shell invocations. POSIX convention is
  /// that when argv[0] is prefixed with `-` the process is being invoked
  /// as a login shell. Ghostty's macOS `cfg.command` path wraps the user
  /// command as `bash -c "exec -l ssh …"`, which leaves the spawned ssh
  /// process with argv `["-ssh", "host"]`. On restore we replay argv via
  /// the user's interactive shell, which then treats `-ssh` as a literal
  /// command name and fails. Strip the leading dash when the remaining
  /// suffix matches the resolved executable basename — that way we only
  /// touch the login-shell marker case, not genuine CLI flags.
  static func stripLoginShellDash(_ argv: [String], executable: String) -> [String] {
    guard let first = argv.first,
          first.hasPrefix("-"),
          String(first.dropFirst()) == executable
    else { return argv }
    var copy = argv
    copy[0] = executable
    return copy
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
      // Skip the executable-path echo (no leading nuls on modern macOS —
      // exec_path starts immediately after the argc int).
      while offset < size && base[offset] != 0 { offset += 1 }
      offset += 1  // past the nul terminator
      // Skip alignment padding between exec_path and argv[0].
      while offset < size && base[offset] == 0 { offset += 1 }
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
