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
