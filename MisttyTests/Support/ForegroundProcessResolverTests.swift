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
      deepestDescendant: { _ in nil },
      describe: fake.describe
    )
    let result = ForegroundProcessResolver.current(via: probe)
    XCTAssertEqual(result?.executable, "ssh")
    XCTAssertEqual(result?.argv, ["ssh", "isengard"])
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
