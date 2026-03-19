import XCTest

@testable import Mistty

final class FuzzyMatcherBenchmarkTests: XCTestCase {

  private func generateTargets(count: Int) -> [String] {
    let bases = [
      "~/Developer/project-alpha", "~/workspace/bazel-build",
      "~/code/my-app/src", "/usr/local/bin/tool",
      "~/Documents/notes/work", "~/Developer/rust-experiments",
      "prod-server.example.com", "staging.internal.net",
      "~/Developer/swift-fuzzy-matcher", "~/code/terminal-emulator",
    ]
    return (0..<count).map { i in
      "\(bases[i % bases.count])-\(i)"
    }
  }

  func test_benchmark_singleMatch_shortTarget() {
    let target = "my-project-name"
    measure {
      for _ in 0..<1000 {
        _ = FuzzyMatcher.match(query: "proj", target: target)
      }
    }
  }

  func test_benchmark_singleMatch_longTarget() {
    let target =
      "/Users/developer/workspace/very/deeply/nested/project/structure/with/many/path/components/file.swift"
    measure {
      for _ in 0..<1000 {
        _ = FuzzyMatcher.match(query: "proj", target: target)
      }
    }
  }

  func test_benchmark_batch500() {
    let targets = generateTargets(count: 500)
    measure {
      for target in targets {
        _ = FuzzyMatcher.match(query: "proj", target: target)
      }
    }
  }

  func test_benchmark_multiToken_batch500() {
    let targets = generateTargets(count: 500)
    let tokens = ["proj", "alpha"]
    measure {
      for target in targets {
        for token in tokens {
          _ = FuzzyMatcher.match(query: token, target: target)
        }
      }
    }
  }

  func test_benchmark_typoFallback_batch500() {
    let targets = generateTargets(count: 500)
    measure {
      for target in targets {
        _ = FuzzyMatcher.match(query: "prjoect", target: target)
      }
    }
  }

  func test_benchmark_noMatches_batch500() {
    let targets = generateTargets(count: 500)
    measure {
      for target in targets {
        _ = FuzzyMatcher.match(query: "zzzzz", target: target)
      }
    }
  }
}
