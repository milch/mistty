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

  func test_primaryPath_returnsNilWhenShellIsForeground() {
    let probe = ForegroundProcessProbe(
      ptyFD: { 5 },
      shellPID: { 1000 },
      tcgetpgrpOnPTY: { _ in 1000 },  // shell pgroup == shell pid = no fg app
      deepestDescendant: { _ in nil },
      describe: { _ in nil }
    )
    XCTAssertNil(ForegroundProcessResolver.current(via: probe))
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
