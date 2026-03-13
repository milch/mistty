import SwiftUI

struct SettingsView: View {
  @State private var config = MisttyConfig.load()

  var body: some View {
    Form {
      Section("Font") {
        TextField("Font Family", text: $config.fontFamily)
        Stepper("Font Size: \(config.fontSize)", value: $config.fontSize, in: 8...36)
      }

      Section("Terminal") {
        Picker("Cursor Style", selection: $config.cursorStyle) {
          Text("Block").tag("block")
          Text("Beam").tag("bar")
          Text("Underline").tag("underline")
        }
        Stepper(
          "Scrollback Lines: \(config.scrollbackLines)",
          value: $config.scrollbackLines, in: 0...100000, step: 1000)
      }

      Section("Appearance") {
        Toggle("Show Sidebar by Default", isOn: $config.sidebarVisible)
      }
    }
    .formStyle(.grouped)
    .frame(width: 400)
    .padding()
    .onChange(of: config.fontSize) { _, _ in saveConfig() }
    .onChange(of: config.fontFamily) { _, _ in saveConfig() }
    .onChange(of: config.cursorStyle) { _, _ in saveConfig() }
    .onChange(of: config.scrollbackLines) { _, _ in saveConfig() }
    .onChange(of: config.sidebarVisible) { _, _ in saveConfig() }
  }

  private func saveConfig() {
    try? config.save()
  }
}
