import Foundation
import Observation

/// Single source of truth for config in the SwiftUI view layer. Wraps the
/// `MisttyConfig.current` bootstrap global and refreshes on reload, so views
/// observe one reactive value instead of carrying a `@State` snapshot that can
/// drift from `.current` within a render pass (audit finding #6).
///
/// Scope is deliberately the view layer: non-view services/models/AppKit code
/// keep reading `MisttyConfig.current` directly (the bootstrap global), per the
/// audit's "keep the static only for bootstrap" guidance. Because this store
/// reads *through* the static rather than holding a separate copy, there is
/// exactly one underlying value — nothing to drift.
@MainActor
@Observable
final class ConfigStore {
  private(set) var config: MisttyConfig

  @ObservationIgnored private var observer: NSObjectProtocol?

  init() {
    config = MisttyConfig.current
    observer = NotificationCenter.default.addObserver(
      forName: .misttyConfigDidReload, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  /// Re-read the current config (after a reload or an in-place Settings save).
  func refresh() { config = MisttyConfig.current }
}
