import XCTest
@testable import Mistty

final class ForegroundProcessResolverTests: XCTestCase {
  private final class FakeDescribe {
    var byPID: [pid_t: ForegroundProcess] = [:]
    func describe(pid: pid_t) -> ForegroundProcess? { byPID[pid] }
  }

  // Simple foreground app: the pgroup contains just nvim (fish did setpgid
  // when launching it as the foreground job).
  func test_pgroupPath_returnsLoneNonShellInForegroundPgroup() {
    let fake = FakeDescribe()
    fake.byPID[4242] = .init(executable: "nvim", path: "/usr/bin/nvim",
                             argv: ["nvim", "foo"], pid: 4242)
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 1000 },
      tcgetpgrpOnPTY: { _ in 4242 },
      pidsInPgroup: { pgid in pgid == 4242 ? [4242] : [] },
      childrenOf: { _ in [] },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "nvim")
    XCTAssertEqual(result?.argv, ["nvim", "foo"])
  }

  // Idle prompt: tcgetpgrp returns the shell's own pid, pgroup = [shell],
  // filter removes it, return nil.
  func test_pgroupPath_returnsNilWhenOnlyShellInForegroundPgroup() {
    let fake = FakeDescribe()
    fake.byPID[1000] = .init(executable: "zsh", path: "/bin/zsh",
                              argv: ["-zsh"], pid: 1000)
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 1000 },
      tcgetpgrpOnPTY: { _ in 1000 },
      pidsInPgroup: { pgid in pgid == 1000 ? [1000] : [] },
      childrenOf: { _ in [] },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
  }

  // Session-Manager auto-launched ssh: ghostty spawns
  // `/usr/bin/login -flp $USER /bin/bash --noprofile --norc -c "exec -l ssh …"`,
  // login forks bash which execs into ssh, all in login's pgroup. The
  // foreground pgroup on the tty is login's pid (inherited), but the
  // actual app the user cares about is ssh. Filter out login → ssh wins.
  func test_pgroupPath_skipsLoginWrapperToFindSSH() {
    let fake = FakeDescribe()
    fake.byPID[81416] = .init(executable: "login", path: "/usr/bin/login",
                              argv: ["login"], pid: 81416)
    fake.byPID[81418] = .init(executable: "ssh", path: "/usr/bin/ssh",
                              argv: ["ssh", "isengard"], pid: 81418)
    let probe = ForegroundProcessProbe(
      ptyFD: { 27 },
      shellPID: { 81416 },
      tcgetpgrpOnPTY: { _ in 81416 },
      pidsInPgroup: { pgid in pgid == 81416 ? [81416, 81418] : [] },
      childrenOf: { _ in [] },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "ssh")
    XCTAssertEqual(result?.argv, ["ssh", "isengard"])
  }

  // Regression for the `{{pid}}` substitution bug: pgroup contains
  // [helper, nvim] where nvim is the pgroup leader (pid == pgid) and
  // `helper` is some non-shell process sharing nvim's pgroup (e.g. an
  // LSP client, a plugin subprocess, or whatever sibling happened to
  // share the pgroup at capture time). The old "last non-shell in
  // arbitrary kernel order" heuristic could pick `helper` over nvim
  // when the kernel listed helper last. This test pins the pgid-leader
  // preference: nvim wins because nvim.pid == pgid.
  func test_pgroupPath_prefersPgroupLeaderOverSiblingNonShells() {
    let fake = FakeDescribe()
    fake.byPID[18101] = .init(executable: "lsp-helper", path: "/usr/local/bin/lsp-helper",
                              argv: ["lsp-helper"], pid: 18101)
    fake.byPID[18102] = .init(executable: "nvim", path: "/usr/local/bin/nvim",
                              argv: ["nvim", "foo.txt"], pid: 18102)
    let probe = ForegroundProcessProbe(
      ptyFD: { 9 },
      shellPID: { 9000 },
      tcgetpgrpOnPTY: { _ in 18102 },                   // nvim is the leader
      pidsInPgroup: { pgid in
        // Kernel orders helper AFTER nvim — with the old heuristic
        // this made helper win. pgid-equality fixes that.
        pgid == 18102 ? [18102, 18101] : []
      },
      childrenOf: { _ in [] },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "nvim")
    XCTAssertEqual(result?.pid, 18102)
  }

  // Regression for the dark-notify bug: fish spawns dark-notify in the
  // background (gets its own pgroup) and nvim in the foreground (different
  // pgroup). tcgetpgrp returns nvim's pgroup, pidsInPgroup returns just
  // nvim — dark-notify isn't in the foreground pgroup and doesn't poison
  // the result. The OLD descendant-walk resolver picked dark-notify
  // arbitrarily; this test pins the fix.
  func test_pgroupPath_ignoresBackgroundedSiblings() {
    let fake = FakeDescribe()
    // dark-notify runs as a background job — different pgroup.
    fake.byPID[5000] = .init(executable: "dark-notify", path: "/opt/homebrew/bin/dark-notify",
                              argv: ["/opt/homebrew/bin/dark-notify"], pid: 5000)
    // nvim is the foreground job.
    fake.byPID[6000] = .init(executable: "nvim", path: "/opt/homebrew/bin/nvim",
                              argv: ["nvim"], pid: 6000)
    let probe = ForegroundProcessProbe(
      ptyFD: { 7 },
      shellPID: { 2000 },
      tcgetpgrpOnPTY: { _ in 6000 },             // nvim owns the tty
      pidsInPgroup: { pgid in pgid == 6000 ? [6000] : [] },
      childrenOf: { _ in [] },
      deepestDescendant: { _ in 5000 },          // would pick dark-notify — unused
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "nvim")
  }

  // PTY fd unavailable (e.g. ghostty patch missing) → fall back to
  // descendant walk.
  func test_fallbackPath_walksDescendantsWhenPTYUnavailable() {
    let fake = FakeDescribe()
    fake.byPID[7] = .init(executable: "htop", path: "/usr/bin/htop",
                          argv: ["htop"], pid: 7)
    let probe = ForegroundProcessProbe(
      ptyFD: { -1 },
      shellPID: { 2 },
      tcgetpgrpOnPTY: { _ in -1 },
      pidsInPgroup: { _ in [] },
      childrenOf: { _ in [] },
      deepestDescendant: { _ in 7 },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "htop")
  }

  func test_fallbackPath_returnsNilWhenNoDescendants() {
    let probe = ForegroundProcessProbe(
      ptyFD: { -1 },
      shellPID: { 2 },
      tcgetpgrpOnPTY: { _ in -1 },
      pidsInPgroup: { _ in [] },
      childrenOf: { _ in [] },
      deepestDescendant: { _ in nil },
      describe: { _ in nil }
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
  }

  func test_bothPathsFail_returnsNil() {
    let probe = ForegroundProcessProbe(
      ptyFD: { -1 },
      shellPID: { -1 },
      tcgetpgrpOnPTY: { _ in -1 },
      pidsInPgroup: { _ in [] },
      childrenOf: { _ in [] },
      deepestDescendant: { _ in nil },
      describe: { _ in nil }
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
  }

  // Neovim 0.12+ forks itself into TUI parent + server child, both named
  // "nvim". The TUI owns the tty (pgroup leader) but `vim.fn.getpid()`
  // from inside the running instance returns the server child's pid. We
  // descend the same-executable chain to capture the server, so `{{pid}}`
  // substitution lines up with the PID the user's autocmds see.
  func test_pgroupPath_descendsIntoSameExecutableChild_forNvimTUISplit() {
    let fake = FakeDescribe()
    // TUI parent: owns the tty, is the pgroup leader.
    fake.byPID[23803] = .init(executable: "nvim",
                              path: "/nix/store/.../bin/nvim",
                              argv: ["/nix/store/.../bin/nvim", "--cmd", "…"],
                              pid: 23803)
    // Server child: same executable, does the Lua work. This is what
    // `vim.fn.getpid()` returns.
    fake.byPID[23804] = .init(executable: "nvim",
                              path: "/nix/store/.../bin/nvim",
                              argv: ["/nix/store/.../bin/nvim", "--cmd", "…"],
                              pid: 23804)
    let probe = ForegroundProcessProbe(
      ptyFD: { 10 },
      shellPID: { 23748 },
      tcgetpgrpOnPTY: { _ in 23803 },
      pidsInPgroup: { pgid in pgid == 23803 ? [23803] : [] },
      childrenOf: { parent in
        if parent == 23803 { return [23804] }
        if parent == 23804 { return [23805] }  // dark-notify, different exe
        return []
      },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.pid, 23804, "should descend from TUI (23803) to server (23804)")
    XCTAssertEqual(result?.executable, "nvim")
  }

  // Descend-into-same-executable must stop when the child has a different
  // name (the common nvim-with-LSP-helpers case). nvim doesn't self-fork;
  // its subprocesses are named differently (node, harper-ls, dark-notify).
  // We capture nvim itself.
  func test_pgroupPath_stopsDescentAtDifferentlyNamedChild() {
    let fake = FakeDescribe()
    fake.byPID[9000] = .init(executable: "nvim", path: "/usr/bin/nvim",
                             argv: ["nvim"], pid: 9000)
    fake.byPID[9001] = .init(executable: "node", path: "/usr/bin/node",
                             argv: ["node"], pid: 9001)
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 8000 },
      tcgetpgrpOnPTY: { _ in 9000 },
      pidsInPgroup: { pgid in pgid == 9000 ? [9000] : [] },
      childrenOf: { parent in parent == 9000 ? [9001] : [] },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.pid, 9000)
    XCTAssertEqual(result?.executable, "nvim")
  }

  func test_stripLoginShellDash_stripsWhenSuffixMatchesExecutable() {
    let result = ForegroundProcessResolver.stripLoginShellDash(
      ["-ssh", "isengard"], executable: "ssh")
    XCTAssertEqual(result, ["ssh", "isengard"])
  }

  func test_stripLoginShellDash_leavesGenuineFlagsAlone() {
    let result = ForegroundProcessResolver.stripLoginShellDash(
      ["nvim", "-u", "init.lua"], executable: "nvim")
    XCTAssertEqual(result, ["nvim", "-u", "init.lua"])
  }

  func test_stripLoginShellDash_preservesNonMatchingDashPrefix() {
    let result = ForegroundProcessResolver.stripLoginShellDash(
      ["-weirdname", "arg"], executable: "ssh")
    XCTAssertEqual(result, ["-weirdname", "arg"])
  }

  func test_stripLoginShellDash_noopOnEmptyArgv() {
    XCTAssertEqual(
      ForegroundProcessResolver.stripLoginShellDash([], executable: "ssh"),
      [])
  }

  // Real-syscall smoke test — runs against the current process. Primarily
  // guards readArgv against the KERN_PROCARGS2 offset-skip bug that returns
  // empty argv elements for padding nuls.
  func test_describe_onCurrentProcess_returnsNonEmptyArgv() {
    guard let result = ForegroundProcessResolver.describe(pid: getpid())
    else { return XCTFail("describe returned nil for current process") }
    XCTAssertFalse(result.executable.isEmpty, "executable basename should be non-empty")
    XCTAssertFalse(result.argv.isEmpty, "argv should be non-empty")
    XCTAssertFalse(result.argv[0].isEmpty,
                   "argv[0] should not be empty — bug: readArgv is consuming padding nuls as argv entries")
  }
}
