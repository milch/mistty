# Popup shell & env overrides — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each popup optionally override the shell used to launch its command and inject environment variables, so users can swap slow login-shell startup for `/bin/sh` without losing `PATH`.

**Architecture:** Two new optional fields on `PopupDefinition` (`shell`, `env`) flow through `MisttyPane` → `TerminalSurfaceView` → `ghostty_surface_config_s`. Env uses ghostty's existing `env_vars` array field. The `TerminalSurfaceView` C-string handling is refactored from nested `withCString` closures to `strdup` + `defer free` to handle the variable-count env array cleanly. Settings UI gets a shell field only; env is TOML-only this pass.

**Tech Stack:** Swift, TOMLKit (TOML parsing), libghostty (C FFI via `ghostty_surface_config_s`).

**Spec:** `docs/superpowers/specs/2026-04-18-popup-shell-env-design.md`

---

### Task 1: Extend `PopupDefinition` with `shell` and `env`

**Files:**
- Modify: `Mistty/Models/PopupDefinition.swift`

- [ ] **Step 1: Add the two new fields with defaults**

Replace the file contents with:

```swift
import Foundation

struct PopupDefinition: Codable, Sendable, Equatable {
  var name: String
  var command: String
  var shortcut: String?
  var width: Double
  var height: Double
  var closeOnExit: Bool
  var shell: String?
  var env: [String: String]

  init(
    name: String,
    command: String,
    shortcut: String? = nil,
    width: Double = 0.8,
    height: Double = 0.8,
    closeOnExit: Bool = true,
    shell: String? = nil,
    env: [String: String] = [:]
  ) {
    self.name = name
    self.command = command
    self.shortcut = shortcut
    self.width = width
    self.height = height
    self.closeOnExit = closeOnExit
    self.shell = shell
    self.env = env
  }
}
```

- [ ] **Step 2: Build to confirm nothing else breaks**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log`
Expected: SUCCESS. `swift build` uses the default init everywhere popups are constructed; new params have defaults so existing call sites still compile.

- [ ] **Step 3: Commit**

```bash
git add Mistty/Models/PopupDefinition.swift
git commit -m "feat(popup): Add shell and env fields to PopupDefinition"
```

---

### Task 2: Parse `shell` and `env` from TOML

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift:204-216`
- Test: `MisttyTests/Config/MisttyConfigTests.swift`

- [ ] **Step 1: Write the failing test for parsing `shell`**

Add to `MisttyTests/Config/MisttyConfigTests.swift` after `test_popupDefaultValues`:

```swift
func test_parsesPopupShellAndEnv() throws {
  let toml = """
    [[popup]]
    name = "scratch"
    command = "nvim"
    shell = "/bin/sh"
    env = { PATH = "/usr/local/bin:/usr/bin", TERM = "xterm-256color" }
    """
  let config = try MisttyConfig.parse(toml)
  XCTAssertEqual(config.popups.count, 1)
  XCTAssertEqual(config.popups[0].shell, "/bin/sh")
  XCTAssertEqual(config.popups[0].env["PATH"], "/usr/local/bin:/usr/bin")
  XCTAssertEqual(config.popups[0].env["TERM"], "xterm-256color")
  XCTAssertEqual(config.popups[0].env.count, 2)
}

func test_popupShellEnvOmitted() throws {
  let toml = """
    [[popup]]
    name = "basic"
    command = "lazygit"
    """
  let config = try MisttyConfig.parse(toml)
  XCTAssertNil(config.popups[0].shell)
  XCTAssertEqual(config.popups[0].env, [:])
}

func test_popupEnvIgnoresNonStringValues() throws {
  let toml = """
    [[popup]]
    name = "weird"
    command = "sh"
    env = { A = "x", B = 42, C = true }
    """
  let config = try MisttyConfig.parse(toml)
  XCTAssertEqual(config.popups[0].env, ["A": "x"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MisttyConfigTests.test_parsesPopupShellAndEnv 2>&1 | tee /tmp/mistty-test.log`
Expected: FAIL — `shell` is nil and `env` is empty because parser doesn't read them yet.

- [ ] **Step 3: Extend the popup parser to read `shell` and `env`**

In `Mistty/Config/MisttyConfig.swift`, replace the `PopupDefinition(...)` construction at lines 207-214 with:

```swift
        var envMap: [String: String] = [:]
        if let envTable = t["env"]?.table {
          for (key, value) in envTable {
            if let str = value.string {
              envMap[key] = str
            }
          }
        }
        return PopupDefinition(
          name: t["name"]?.string ?? "",
          command: t["command"]?.string ?? "",
          shortcut: t["shortcut"]?.string,
          width: max(0.1, min(1.0, t["width"]?.double ?? 0.8)),
          height: max(0.1, min(1.0, t["height"]?.double ?? 0.8)),
          closeOnExit: t["close_on_exit"]?.bool ?? true,
          shell: t["shell"]?.string,
          env: envMap
        )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MisttyConfigTests 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS — all three new tests plus all existing tests.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat(popup): Parse shell and env from TOML popup blocks"
```

---

### Task 3: Extract `rendered` computed property and emit new fields

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift:344-373`
- Test: `MisttyTests/Config/MisttyConfigTests.swift`

Rationale: `save(to:)` today builds the TOML string inline then writes. Extracting a `rendered: String` property gives us a pure string for round-trip testing, and the refactor is tiny.

This step uses three targeted edits that keep the unchanged ssh/copy_mode/ui/ghostty rendering in place.

- [ ] **Step 1a: Rename `save` into a `rendered` computed property**

In `Mistty/Config/MisttyConfig.swift`, replace the `save(to:)` declaration and its prologue with a `rendered` opener. Find this block (starts around line 344):

```swift
  func save(to url: URL = configURL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var lines: [String] = []
```

Replace it with:

```swift
  /// TOML serialization of all known fields. Drops comments and any unknown
  /// keys — see the TODO on `save(to:)` for the long-term fix.
  var rendered: String {
    var lines: [String] = []
```

- [ ] **Step 1b: Add shell and env emission in the popup loop**

Inside the `for popup in popups` loop, find the existing line:

```swift
      lines.append("close_on_exit = \(popup.closeOnExit)")
    }
```

Replace with:

```swift
      lines.append("close_on_exit = \(popup.closeOnExit)")
      if let shell = popup.shell {
        lines.append("shell = \"\(tomlEscape(shell))\"")
      }
      if !popup.env.isEmpty {
        let entries = popup.env.keys.sorted().map { key in
          "\(key) = \"\(tomlEscape(popup.env[key]!))\""
        }
        lines.append("env = { \(entries.joined(separator: ", ")) }")
      }
    }
```

Also fix the existing name/command/shortcut emission at the top of the same popup loop to escape properly — find:

```swift
      lines.append("name = \"\(popup.name)\"")
      lines.append("command = \"\(popup.command)\"")
      if let shortcut = popup.shortcut {
        lines.append("shortcut = \"\(shortcut)\"")
      }
```

Replace with:

```swift
      lines.append("name = \"\(tomlEscape(popup.name))\"")
      lines.append("command = \"\(tomlEscape(popup.command))\"")
      if let shortcut = popup.shortcut {
        lines.append("shortcut = \"\(tomlEscape(shortcut))\"")
      }
```

- [ ] **Step 1c: Close `rendered` and add a new `save`**

At the very end of the (now renamed) method body, find the existing closing line (at roughly line 443 in the current file):

```swift
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }
```

Replace with:

```swift
    return lines.joined(separator: "\n") + "\n"
  }

  /// Serialize and write the config to disk. Thin wrapper over `rendered`
  /// that handles directory creation.
  func save(to url: URL = configURL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try rendered.write(to: url, atomically: true, encoding: .utf8)
  }
```

**Note:** If the actual closing of `save(to:)` differs from the snippet above (e.g. already uses `.write(to:...)` on a different variable name), adjust the `old_string` for this edit accordingly. The goal is: `rendered` returns the joined string with a trailing newline; `save(to:)` writes it to disk.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log`
Expected: SUCCESS.

- [ ] **Step 3: Write the failing round-trip test**

Add to `MisttyTests/Config/MisttyConfigTests.swift`:

```swift
func test_roundTripPopupShellEnv() throws {
  let toml = """
    [[popup]]
    name = "scratch"
    command = "nvim"
    shell = "/bin/sh"
    env = { PATH = "/usr/bin", TERM = "xterm" }
    """
  let parsed = try MisttyConfig.parse(toml)
  let rendered = parsed.rendered
  let reparsed = try MisttyConfig.parse(rendered)
  XCTAssertEqual(reparsed.popups, parsed.popups)
}

func test_roundTripPreservesEnvOrder() throws {
  // Give keys in reverse order on input, expect alphabetical in output.
  let config = MisttyConfig(
    popups: [
      PopupDefinition(
        name: "t", command: "c",
        env: ["Z": "1", "A": "2", "M": "3"]
      )
    ]
  )
  // Extract the `env = { ... }` line.
  let envLine = config.rendered.split(separator: "\n").first { $0.hasPrefix("env =") }
  XCTAssertNotNil(envLine)
  XCTAssertEqual(String(envLine!), "env = { A = \"2\", M = \"3\", Z = \"1\" }")
}
```

Note the second test constructs `MisttyConfig` directly with a `popups` array. If `MisttyConfig` doesn't have a public initializer that accepts `popups`, use the default init then mutate:

```swift
  var config = MisttyConfig()
  config.popups = [
    PopupDefinition(
      name: "t", command: "c",
      env: ["Z": "1", "A": "2", "M": "3"]
    )
  ]
```

(Use whichever form works given `MisttyConfig`'s existing init surface — check the top of `MisttyConfig.swift` first.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MisttyConfigTests 2>&1 | tee /tmp/mistty-test.log`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift MisttyTests/Config/MisttyConfigTests.swift
git commit -m "feat(popup): Render shell and env in TOML output with deterministic key order"
```

---

### Task 4: Add `shell` and `env` fields to `MisttyPane` and wire through session

**Files:**
- Modify: `Mistty/Models/MisttyPane.swift`
- Modify: `Mistty/Models/MisttySession.swift:74-85, 96-107`

- [ ] **Step 1: Add fields to `MisttyPane`**

Edit `Mistty/Models/MisttyPane.swift`. Add two properties after `useCommandField`:

```swift
  /// Shell override for popups: when set, used as cfg.command with the
  /// popup's command wrapped as initial_input. Only meaningful when
  /// useCommandField is false (i.e. closeOnExit=true). Ignored otherwise.
  var shell: String?

  /// Env vars injected into the surface's spawned process. Applies in
  /// every mode.
  var env: [String: String] = [:]
```

Update the `surfaceView` lazy var to pass the new fields:

```swift
  @ObservationIgnored
  lazy var surfaceView: TerminalSurfaceView = {
    let view = TerminalSurfaceView(
      frame: .zero,
      workingDirectory: directory,
      command: useCommandField ? command : nil,
      initialInput: useCommandField ? nil : command,
      shell: useCommandField ? nil : shell,
      env: env
    )
    view.pane = self
    return view
  }()
```

The `shell: useCommandField ? nil : shell` enforces the spec: shell is ignored when `closeOnExit=false` (i.e. `useCommandField=true`).

- [ ] **Step 2: Populate fields in session popup creation paths**

Edit `Mistty/Models/MisttySession.swift`. In `togglePopup(definition:)` (around line 74-85), after `pane.command = definition.command` add:

```swift
    pane.shell = definition.shell
    pane.env = definition.env
```

Do the same in `openPopup(definition:)` (around line 96-107) after `pane.command = definition.command`.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log`
Expected: FAIL — `TerminalSurfaceView.init` doesn't yet accept `shell:` and `env:`. This is expected and Task 5 fixes it.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Models/MisttyPane.swift Mistty/Models/MisttySession.swift
git commit -m "feat(popup): Plumb shell and env through MisttyPane and session"
```

(Build is red at this commit; intentional — Task 5 completes the wiring.)

---

### Task 5: Refactor `TerminalSurfaceView` C-string handling and accept `shell` / `env`

**Files:**
- Modify: `Mistty/Views/Terminal/TerminalSurfaceView.swift:28-127`

This replaces the nested `withCString` ladder with `strdup` + `defer free` to handle any combination of fields and arbitrary env counts.

- [ ] **Step 1: Replace the init signature and body**

Replace the entire `init(frame:workingDirectory:command:initialInput:)` method and the internal `createSurface(_:)` helper (currently lines 28-127) with this block. Carefully preserve the existing `super.init`, `wantsLayer = true`, and app-availability check.

```swift
  init(
    frame: NSRect,
    workingDirectory: URL? = nil,
    command: String? = nil,
    initialInput: String? = nil,
    shell: String? = nil,
    env: [String: String] = [:]
  ) {
    // Use the shared launch-time parse so init doesn't re-read config.toml
    // per pane and stays consistent with the lines sent to libghostty.
    let ui = MisttyConfig.loadedAtLaunch.config.ui
    self.configuredPaddingX = CGFloat(ui.contentPaddingX?.first ?? Int(Self.ghosttyDefaultPadding))
    self.configuredPaddingY = CGFloat(ui.contentPaddingY?.first ?? Int(Self.ghosttyDefaultPadding))
    self.configuredPaddingBalance = ui.contentPaddingBalance ?? false

    super.init(frame: frame)
    wantsLayer = true

    guard let app = GhosttyAppManager.shared.app else {
      print("[TerminalSurfaceView] No ghostty app available")
      return
    }

    var cfg = ghostty_surface_config_new()
    cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
    cfg.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(self).toOpaque()
      )
    )
    cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
    cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
    cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

    // Lifetime parking lot: every strdup'd pointer is collected here and
    // freed in the defer below. Keeps the pointers alive through
    // ghostty_surface_new — libghostty copies what it needs internally.
    var cStrings: [UnsafeMutablePointer<CChar>] = []
    defer { cStrings.forEach { free($0) } }

    func dup(_ s: String) -> UnsafePointer<CChar> {
      let p = strdup(s)!
      cStrings.append(p)
      return UnsafePointer(p)
    }

    if let dir = workingDirectory {
      cfg.working_directory = dup(dir.path)
    }

    // Command precedence: explicit shell overrides everything (used when
    // popup sets shell + closeOnExit=true). Otherwise fall back to the
    // passed command (closeOnExit=false direct-exec case). Nil means
    // ghostty picks its default shell.
    if let shell {
      cfg.command = dup(shell)
    } else if let command {
      cfg.command = dup(command)
    }

    if let input = initialInput {
      cfg.initial_input = dup("exec \(input)\n")
    }

    // Build the env_vars array. Pointers into `cStrings` stay valid for
    // the full defer scope; the array itself stays alive because we hold
    // it locally through the ghostty_surface_new call.
    var envArray: [ghostty_env_var_s] = []
    for (key, value) in env {
      envArray.append(ghostty_env_var_s(key: dup(key), value: dup(value)))
    }
    envArray.withUnsafeMutableBufferPointer { buf in
      if let base = buf.baseAddress, !envArray.isEmpty {
        cfg.env_vars = base
        cfg.env_var_count = envArray.count
      }
      surface = ghostty_surface_new(app, &cfg)
    }

    if surface == nil {
      print("[TerminalSurfaceView] ghostty_surface_new failed")
    }
  }
```

**CRITICAL:** this replaces the old behavior where `initialInput` was pre-wrapped as `"exec \(input)\n"` in the init before the nested `withCString`. The new init does the same wrapping inline (`dup("exec \(input)\n")`). The caller (`MisttyPane.surfaceView`) still passes the raw command — no change there.

Also remove the now-unused stored properties `workingDirectoryPath`, `commandString`, `initialInputString` (lines 13-19 in the original) — they were scratch-space for the old `withCString` pattern.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log`
Expected: SUCCESS. Task 4's session wiring now type-checks.

- [ ] **Step 3: Manual smoke test**

Launch Mistty from a clean build, open a popup that already exists in your config (or add a temporary `[[popup]]` block with `command = "zsh"` and a shortcut). Trigger the popup — it should open and accept input as before. If you have a popup with `closeOnExit = true`, confirm its command runs and the popup closes on exit.

Run: `swift run Mistty 2>&1 | tee /tmp/mistty-run.log` (or use Xcode)
Expected: popups still work identically to before this change.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Views/Terminal/TerminalSurfaceView.swift
git commit -m "refactor(terminal): Replace nested withCString with strdup-based lifetime handling

Flattens the C-string pointer management so TerminalSurfaceView can
accept an arbitrary-count env_vars array. No behavior change for
existing callers."
```

---

### Task 6: Extend IPC openPopup to carry `shell` and `env`

**Files:**
- Modify: `MisttyShared/MisttyServiceProtocol.swift:46`
- Modify: `Mistty/Services/IPCService.swift:483-502`
- Modify: `Mistty/Services/IPCListener.swift:302-306`

- [ ] **Step 1: Extend the protocol**

In `MisttyShared/MisttyServiceProtocol.swift:46`, replace:

```swift
    func openPopup(sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool, reply: @escaping (Data?, Error?) -> Void)
```

with:

```swift
    func openPopup(sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool, shell: String?, env: [String: String], reply: @escaping (Data?, Error?) -> Void)
```

- [ ] **Step 2: Update the service implementation**

In `Mistty/Services/IPCService.swift`, replace the `openPopup` method (lines 483-502) signature and body to accept and use the new parameters:

```swift
  func openPopup(
    sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool,
    shell: String?, env: [String: String],
    reply: @escaping (Data?, Error?) -> Void
  ) {
    let reply = Reply(handler: reply)
    Task { @MainActor in
      guard let session = self.store.session(byId: sessionId) else {
        reply(nil, MisttyIPC.error(.entityNotFound, "Session \(sessionId) not found"))
        return
      }
      let definition = PopupDefinition(
        name: name, command: exec, width: width, height: height,
        closeOnExit: closeOnExit, shell: shell, env: env)
      session.openPopup(definition: definition)
      guard let popup = session.activePopup else {
        reply(nil, MisttyIPC.error(.operationFailed, "Failed to create popup"))
        return
      }
      reply(self.encode(self.popupResponse(popup)), nil)
    }
  }
```

- [ ] **Step 3: Update the listener dispatch**

In `Mistty/Services/IPCListener.swift`, replace the `"openPopup"` case (lines 302-306):

```swift
    case "openPopup":
      let envDict = (params["env"] as? [String: String]) ?? [:]
      service.openPopup(
        sessionId: int("sessionId"), name: str("name") ?? "",
        exec: str("exec") ?? "", width: dbl("width"), height: dbl("height"),
        closeOnExit: boo("closeOnExit"),
        shell: str("shell"),
        env: envDict,
        reply: reply)
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log`
Expected: SUCCESS. Existing CLI clients that don't send `shell` or `env` still work because `str("shell")` returns nil for missing keys and the dict cast falls back to empty.

- [ ] **Step 5: Commit**

```bash
git add MisttyShared/MisttyServiceProtocol.swift Mistty/Services/IPCService.swift Mistty/Services/IPCListener.swift
git commit -m "feat(ipc): Carry shell and env through openPopup IPC"
```

---

### Task 7: Add `--shell` and `--env` flags to `mistty-cli popup open`

**Files:**
- Modify: `MisttyCLI/Commands/PopupCommand.swift:17-92`

- [ ] **Step 1: Add the flags and KEY=VAL parser**

In `MisttyCLI/Commands/PopupCommand.swift`, inside `struct Open`, add two new `@Option` declarations after the `keepOnExit` flag (around line 39):

```swift
        @Option(name: .long, help: "Shell to launch the command in (e.g. /bin/sh). Only applies when the popup closes on exit.")
        var shell: String?

        @Option(name: .long, help: "Environment variables for the popup shell, KEY=VAL. Repeat the flag for multiple entries.")
        var env: [String] = []
```

Then inside `run()`, before the `client.call("openPopup", ...)` call, parse `env` into a dictionary:

```swift
            var envDict: [String: String] = [:]
            for entry in env {
                guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else {
                    OutputFormatter.printError("Invalid --env value \"\(entry)\": expected KEY=VAL with non-empty KEY")
                    Foundation.exit(1)
                }
                let key = String(entry[..<eq])
                let value = String(entry[entry.index(after: eq)...])
                envDict[key] = value
            }
```

Update the `client.call("openPopup", ...)` payload to include the new fields:

```swift
                data = try client.call("openPopup", [
                    "sessionId": sessionId,
                    "name": popupName,
                    "exec": command,
                    "width": width,
                    "height": height,
                    "closeOnExit": shouldCloseOnExit,
                    "shell": shell as Any,
                    "env": envDict,
                ])
```

Note: `shell as Any` is needed because `shell` is `String?` and the dictionary literal wants non-optional `Any`. The IPC layer's `str("shell")` will unwrap it — a nil value arrives as NSNull and `params["shell"] as? String` yields nil, which is what we want.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log`
Expected: SUCCESS.

- [ ] **Step 3: Manual test of the CLI flags**

With Mistty running:

```bash
swift run mistty-cli popup open --exec echo --shell /bin/sh --env FOO=bar --env GREETING=hello
```

Expected: a popup opens briefly (running `echo` via `/bin/sh`). Confirm no CLI error. Malformed flag test:

```bash
swift run mistty-cli popup open --exec echo --env NOEQUALS
```

Expected: prints `Error: Invalid --env value "NOEQUALS": ...` and exits non-zero.

- [ ] **Step 4: Commit**

```bash
git add MisttyCLI/Commands/PopupCommand.swift
git commit -m "feat(cli): Add --shell and --env flags to mistty-cli popup open"
```

---

### Task 8: Add a shell field to the Settings popup editor

**Files:**
- Modify: `Mistty/Views/Settings/SettingsView.swift:60-98`

- [ ] **Step 1: Add the `TextField` row for `shell`**

In the popup editor `VStack`/`HStack` (starts around line 60, inside the `ForEach` over popups), add a new row between the existing Name/Command/Shortcut row (around line 80) and the Size sliders row (around line 82). Insert:

```swift
            HStack {
              TextField(
                "Shell (optional, e.g. /bin/sh)",
                text: Binding(
                  get: { config.popups[index].shell ?? "" },
                  set: { config.popups[index].shell = $0.isEmpty ? nil : $0 }
                )
              )
              .frame(width: 280)
            }
```

The env field is intentionally not exposed in the UI this pass (see spec §Settings UI). Existing env values on disk survive form saves because `PopupDefinition` is round-trippable and `rendered` emits env when non-empty.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tee /tmp/mistty-build.log`
Expected: SUCCESS.

- [ ] **Step 3: Manual UI verification**

Launch Mistty, open Settings → Popups, verify:
1. Each popup row shows a "Shell (optional, ...)" text field.
2. Editing the shell field updates the config (check with `mistty-cli config show` or inspect `~/.config/mistty/config.toml`).
3. A popup that previously had `env = { ... }` in the config keeps those values after editing an unrelated popup field.

- [ ] **Step 4: Commit**

```bash
git add Mistty/Views/Settings/SettingsView.swift
git commit -m "feat(settings): Add shell field to popup editor"
```

---

### Task 9: Document `shell` and `env` in the config example

**Files:**
- Modify: `docs/config-example.toml:33-44`

- [ ] **Step 1: Expand the popup section with the two new keys**

Replace the existing popup section (lines 33-44) with:

```toml
# ─── Popup windows ───────────────────────────────────────────────────────────
# Transient, floating terminal windows bound to a keyboard shortcut.
# Add one [[popup]] block per popup. No defaults ship.
#
# [[popup]]
# name = "scratch"                  # display name
# command = "zsh"                   # command to run
# shortcut = "cmd+shift+space"      # modifiers: cmd/command, shift, opt/option/alt, ctrl/control
# width = 0.8                       # fraction of screen width  (0.1–1.0)
# height = 0.8                      # fraction of screen height (0.1–1.0)
# close_on_exit = true              # close popup when command exits
# shell = "/bin/sh"                 # optional; shell used to exec `command`.
#                                   # Defaults to your login shell (slow startup on macOS).
#                                   # Use `/bin/sh` or `dash` for faster popups.
#                                   # Ignored when close_on_exit = false. If the path doesn't
#                                   # exist, the popup surface will fail to spawn.
# env = { PATH = "/usr/local/bin:/usr/bin:/bin", TERM = "xterm-256color" }
#                                   # optional; env vars for the spawned process.
#                                   # Useful when `shell = "/bin/sh"` since bare sh doesn't
#                                   # load your login-shell PATH. Stacks on top of ghostty's
#                                   # global `env` passthrough (per-popup wins on conflict).
```

- [ ] **Step 2: Commit**

```bash
git add docs/config-example.toml
git commit -m "docs(config): Document popup shell and env options"
```

---

### Task 10: Final verification

- [ ] **Step 1: Full test run**

Run: `swift test 2>&1 | tee /tmp/mistty-test-final.log`
Expected: all tests pass. If any fail, investigate and fix before declaring done.

- [ ] **Step 2: Full build**

Run: `swift build 2>&1 | tee /tmp/mistty-build-final.log`
Expected: SUCCESS, no warnings related to popup code.

- [ ] **Step 3: End-to-end manual test**

Add a test popup to `~/.config/mistty/config.toml`:

```toml
[[popup]]
name = "fast-sh"
command = "echo $PATH && read -p 'press enter: ' x"
shortcut = "cmd+shift+t"
close_on_exit = true
shell = "/bin/sh"
env = { PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", MY_POPUP = "hi" }
```

Launch Mistty, trigger `cmd+shift+t`. Expected:
- Popup opens noticeably faster than a login-shell popup.
- Output contains `/opt/homebrew/bin:...` (confirms env applied).
- `echo $MY_POPUP` (add another echo) shows `hi`.

- [ ] **Step 4: Confirm round-trip through the Settings UI**

Open Mistty Settings → Popups, edit the `fast-sh` popup's name (or any field), save. Re-read `~/.config/mistty/config.toml`. The `shell` and `env` values should still be present and intact.

---

## Self-review notes

- Spec coverage: data model (Task 1), TOML parse/render + round-trip tests (Tasks 2–3), pane/session wiring (Task 4), ghostty surface wiring (Task 5), IPC (Task 6), CLI (Task 7), Settings UI (Task 8), docs (Task 9). ✓
- Memory-lifetime design (`strdup` + `defer free`) implemented in Task 5. ✓
- Non-goals honored: no global default shell, no shell_args, no env UI editor, shell ignored when closeOnExit=false (enforced in Task 4's pane wiring). ✓
- Round-trip tests cover sorted-env rendering per spec §TOML rendering rules. ✓
- Task 4 intentionally ships a red build because the signature change to `TerminalSurfaceView` is bundled into Task 5 — they could be collapsed into one task, but the separation keeps each task's changes coherent and under ~100 lines. Documented in the task note.
