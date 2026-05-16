import XCTest

@testable import Mistty

/// Per-keystroke filtering is the latency-critical path in the session
/// manager: every typed character re-runs the fuzzy matcher across every
/// directory + SSH host the user has. At realistic scale (~1k zoxide
/// entries, ~50 hosts) this is ~4k fuzzy-match calls per keystroke; the
/// benchmarks below sit on top of the per-call `FuzzyMatcherBenchmarkTests`
/// to catch regressions at the view-model layer (scoring, subtitle
/// penalty, sort, matchResults bookkeeping).
@MainActor
final class SessionManagerViewModelBenchmarkTests: XCTestCase {
  private static let directoryCount = 1000
  private static let sshHostCount = 50

  private func generateDirectories(count: Int) -> [URL] {
    let bases = [
      "Developer/project-alpha", "Developer/swift-fuzzy-matcher",
      "Developer/terminal-emulator", "Developer/bazel-build",
      "Documents/notes/work", "Documents/notes/personal",
      "code/my-app/src", "code/rust-experiments",
      "workspace/client-foo", "workspace/client-bar",
    ]
    return (0..<count).map { i in
      URL(fileURLWithPath: "/Users/me/\(bases[i % bases.count])-\(i)")
    }
  }

  private func generateHosts(count: Int) -> [SSHHost] {
    let bases = [
      ("prod-web", "10.0.1"), ("prod-db", "10.0.2"),
      ("staging-web", "10.1.1"), ("staging-db", "10.1.2"),
      ("dev-box", "10.2.0"),
    ]
    return (0..<count).map { i in
      let (alias, prefix) = bases[i % bases.count]
      return SSHHost(alias: "\(alias)-\(i)", hostname: "\(prefix).\(i)")
    }
  }

  /// Fresh view-model populated with the benchmark fixtures. `load()` runs
  /// the initial sort, so per-query `measure` blocks isolate `updateQuery`
  /// cost from setup.
  private func makeLoadedViewModel() async -> SessionManagerViewModel {
    let windowsStore = WindowsStore()
    let store = windowsStore.createWindow()
    let dirs = generateDirectories(count: Self.directoryCount)
    let hosts = generateHosts(count: Self.sshHostCount)
    let frecencyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("mistty-bench-frecency-\(UUID().uuidString).json")
    let frecency = FrecencyService(storageURL: frecencyURL)
    let vm = SessionManagerViewModel(
      state: store,
      windowsStore: windowsStore,
      frecencyService: frecency,
      recentDirectories: { dirs },
      sshHosts: { hosts }
    )
    await vm.load()
    return vm
  }

  func test_benchmark_load_1050items() {
    let dirs = generateDirectories(count: Self.directoryCount)
    let hosts = generateHosts(count: Self.sshHostCount)
    measure {
      let expectation = expectation(description: "load")
      Task { @MainActor in
        let windowsStore = WindowsStore()
        let store = windowsStore.createWindow()
        let frecencyURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("mistty-bench-frecency-\(UUID().uuidString).json")
        let vm = SessionManagerViewModel(
          state: store,
          windowsStore: windowsStore,
          frecencyService: FrecencyService(storageURL: frecencyURL),
          recentDirectories: { dirs },
          sshHosts: { hosts }
        )
        await vm.load()
        expectation.fulfill()
      }
      wait(for: [expectation], timeout: 5)
    }
  }

  func test_benchmark_updateQuery_singleToken() async {
    let vm = await makeLoadedViewModel()
    measure {
      vm.updateQuery("proj")
    }
  }

  func test_benchmark_updateQuery_multiToken() async {
    let vm = await makeLoadedViewModel()
    measure {
      vm.updateQuery("proj alpha")
    }
  }

  func test_benchmark_updateQuery_noMatches() async {
    let vm = await makeLoadedViewModel()
    measure {
      vm.updateQuery("zzzzz")
    }
  }

  func test_benchmark_updateQuery_sshPrefixed() async {
    let vm = await makeLoadedViewModel()
    measure {
      vm.updateQuery("ssh prod")
    }
  }

  /// Models the actual typing experience: backspace + retype cycles. Each
  /// `measure` iteration runs five updateQuery calls — closer to the real
  /// jank-budget question ("does typing five characters feel laggy?")
  /// than a single call.
  func test_benchmark_updateQuery_typingSequence() async {
    let vm = await makeLoadedViewModel()
    let sequence = ["p", "pr", "pro", "proj", "proje"]
    measure {
      for q in sequence {
        vm.updateQuery(q)
      }
    }
  }

  /// Longer typing sequence — exposes any algorithm whose per-keystroke
  /// cost grows with query length (e.g. Damerau-Levenshtein in the typo
  /// fallback is O(qLen × windowLen) per cell, so cost scales ~qLen²
  /// without an early-out).
  func test_benchmark_updateQuery_longTypingSequence() async {
    let vm = await makeLoadedViewModel()
    let sequence = [
      "p", "pr", "pro", "proj", "proje", "projec", "project",
      "project-", "project-a", "project-al", "project-alp",
      "project-alph", "project-alpha",
    ]
    measure {
      for q in sequence {
        vm.updateQuery(q)
      }
    }
  }
}
