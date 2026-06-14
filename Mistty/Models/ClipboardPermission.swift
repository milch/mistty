/// Pure precedence logic for OSC-52 clipboard-read decisions. The
/// side-effecting parts (resolving the pane's process, prompting, persisting)
/// live in `ClipboardPermissionCoordinator`; this is the testable core.
enum ClipboardPermission {
  /// Most specific wins: in-memory session override → persisted per-process
  /// rule → global default.
  static func resolve(
    global: ClipboardReadMode,
    processRule: ClipboardReadMode?,
    sessionOverride: ClipboardReadMode?
  ) -> ClipboardReadMode {
    sessionOverride ?? processRule ?? global
  }
}
