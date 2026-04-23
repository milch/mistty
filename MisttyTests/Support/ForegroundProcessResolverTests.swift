import XCTest
@testable import Mistty

final class ForegroundProcessResolverTests: XCTestCase {
  private final class FakeDescribe {
    var byPID: [pid_t: ForegroundProcess] = [:]
    func describe(pid: pid_t) -> ForegroundProcess? { byPID[pid] }
  }

  func test_primaryPath_returnsPgroupLeaderWhenNotShell() {
    let fake = FakeDescribe()
    fake.byPID[4242] = .init(executable: "nvim", path: "/usr/bin/nvim",
                             argv: ["nvim", "foo"], pid: 4242)
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 1000 },
      tcgetpgrpOnPTY: { _ in 4242 },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "nvim")
    XCTAssertEqual(result?.argv, ["nvim", "foo"])
  }

  // Plain shell at the prompt: tcgetpgrp describes to `zsh` → no capture.
  func test_primaryPath_returnsNilWhenShellIsForeground() {
    let fake = FakeDescribe()
    fake.byPID[1000] = .init(executable: "zsh", path: "/bin/zsh",
                              argv: ["-zsh"], pid: 1000)
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 1000 },
      tcgetpgrpOnPTY: { _ in 1000 },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
  }

  // SSH session spawned via cfg.command: ghostty does `sh -c 'ssh …'`
  // which execs into ssh, so shellPID == tcgetpgrp == ssh's pid. The prior
  // version of the resolver short-circuited to nil on pgid==shell, missing
  // ssh entirely. This test pins the fix: describe and keep non-shell pids.
  func test_primaryPath_capturesSSHEvenWhenPgidEqualsShellPID() {
    let fake = FakeDescribe()
    fake.byPID[42] = .init(executable: "ssh", path: "/usr/bin/ssh",
                            argv: ["ssh", "user@host"], pid: 42)
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 42 },
      tcgetpgrpOnPTY: { _ in 42 },
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "ssh")
    XCTAssertEqual(result?.argv, ["ssh", "user@host"])
  }

  // Auto-launched SSH via Session Manager goes through
  // `/usr/bin/login -flp $USER /bin/bash --noprofile --norc -c "exec -l ssh …"`.
  // Empirically login forks rather than exec-chaining, so shellPID stays
  // pointed at login (with executable "login") while ssh runs as a
  // descendant in the same process group. The resolver must descend
  // through login to find the real app.
  func test_primaryPath_descendsThroughLoginToFindSSH() {
    let fake = FakeDescribe()
    fake.byPID[81416] = .init(executable: "login", path: "/usr/bin/login",
                              argv: ["login"], pid: 81416)
    fake.byPID[81418] = .init(executable: "ssh", path: "/usr/bin/ssh",
                              argv: ["ssh", "isengard"], pid: 81418)
    let probe = ForegroundProcessProbe(
      ptyFD: { 27 },
      shellPID: { 81416 },           // ghostty tracks login
      tcgetpgrpOnPTY: { _ in 81416 }, // foreground pgroup == login's pid
      deepestDescendant: { _ in 81418 }, // ssh is the real child
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "ssh")
    XCTAssertEqual(result?.argv, ["ssh", "isengard"])
  }

  func test_fallbackPath_walksDescendantsWhenPTYUnavailable() {
    let fake = FakeDescribe()
    fake.byPID[7] = .init(executable: "htop", path: "/usr/bin/htop",
                          argv: ["htop"], pid: 7)
    let probe = ForegroundProcessProbe(
      ptyFD: { -1 },                      // no pty fd
      shellPID: { 2 },
      tcgetpgrpOnPTY: { _ in -1 },
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
      deepestDescendant: { _ in nil },
      describe: { _ in nil }
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
  }

  func test_stripLoginShellDash_stripsWhenSuffixMatchesExecutable() {
    let result = ForegroundProcessResolver.stripLoginShellDash(
      ["-ssh", "isengard"], executable: "ssh")
    XCTAssertEqual(result, ["ssh", "isengard"])
  }

  func test_stripLoginShellDash_leavesGenuineFlagsAlone() {
    // A real flag like `-l` is NOT argv[0] — it'd appear at argv[1+].
    // argv[0] with a `-` prefix but suffix that doesn't match executable
    // (e.g. argv[0] = "-bash", executable = "sh") is still treated as
    // login-shell marker (only matched when the suffix == basename).
    let result = ForegroundProcessResolver.stripLoginShellDash(
      ["nvim", "-u", "init.lua"], executable: "nvim")
    XCTAssertEqual(result, ["nvim", "-u", "init.lua"])
  }

  func test_stripLoginShellDash_preservesNonMatchingDashPrefix() {
    // If the suffix after `-` doesn't match executable, it's not the
    // login-shell convention and we leave it alone.
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
