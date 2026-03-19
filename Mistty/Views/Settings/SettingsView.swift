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

      Section("Popups") {
        ForEach(config.popups.indices, id: \.self) { index in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              TextField("Name", text: $config.popups[index].name)
                .frame(width: 120)
              TextField("Command", text: $config.popups[index].command)
                .frame(width: 150)
              TextField(
                "Shortcut",
                text: Binding(
                  get: { config.popups[index].shortcut ?? "" },
                  set: { config.popups[index].shortcut = $0.isEmpty ? nil : $0 }
                )
              )
              .frame(width: 120)
              Button(role: .destructive) {
                config.popups.remove(at: index)
                saveConfig()
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
              }
              .buttonStyle(.plain)
            }
            HStack {
              Text("Size:")
                .foregroundStyle(.secondary)
                .font(.caption)
              Slider(value: $config.popups[index].width, in: 0.3...1.0, step: 0.05) {
                Text("W: \(Int(config.popups[index].width * 100))%")
                  .font(.caption)
                  .frame(width: 45)
              }
              Slider(value: $config.popups[index].height, in: 0.3...1.0, step: 0.05) {
                Text("H: \(Int(config.popups[index].height * 100))%")
                  .font(.caption)
                  .frame(width: 45)
              }
              Toggle("Close on exit", isOn: $config.popups[index].closeOnExit)
                .font(.caption)
            }
          }
          .padding(.vertical, 2)
        }

        Button("Add Popup") {
          config.popups.append(PopupDefinition(name: "", command: ""))
          saveConfig()
        }
      }

      Section("SSH") {
        HStack {
          Text("Default Command")
          TextField("ssh", text: $config.ssh.defaultCommand)
            .frame(width: 150)
        }

        ForEach(config.ssh.hosts.indices, id: \.self) { index in
          HStack {
            Picker(
              "Match",
              selection: Binding(
                get: { config.ssh.hosts[index].hostname != nil ? "hostname" : "regex" },
                set: { type in
                  if type == "hostname" {
                    config.ssh.hosts[index].hostname = config.ssh.hosts[index].regex ?? ""
                    config.ssh.hosts[index].regex = nil
                  } else {
                    config.ssh.hosts[index].regex = config.ssh.hosts[index].hostname ?? ""
                    config.ssh.hosts[index].hostname = nil
                  }
                }
              )
            ) {
              Text("Hostname").tag("hostname")
              Text("Regex").tag("regex")
            }
            .frame(width: 120)

            if config.ssh.hosts[index].hostname != nil {
              TextField(
                "hostname",
                text: Binding(
                  get: { config.ssh.hosts[index].hostname ?? "" },
                  set: { config.ssh.hosts[index].hostname = $0 }
                )
              )
              .frame(width: 120)
            } else {
              TextField(
                "pattern",
                text: Binding(
                  get: { config.ssh.hosts[index].regex ?? "" },
                  set: { config.ssh.hosts[index].regex = $0 }
                )
              )
              .frame(width: 120)
            }

            TextField("command", text: $config.ssh.hosts[index].command)
              .frame(width: 80)

            Button(role: .destructive) {
              config.ssh.hosts.remove(at: index)
              saveConfig()
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
          }
        }

        Button("Add Host Override") {
          config.ssh.hosts.append(SSHHostOverride(hostname: "", command: "ssh"))
          saveConfig()
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 550, height: 600)
    .padding()
    .onChange(of: config.fontSize) { _, _ in saveConfig() }
    .onChange(of: config.fontFamily) { _, _ in saveConfig() }
    .onChange(of: config.cursorStyle) { _, _ in saveConfig() }
    .onChange(of: config.scrollbackLines) { _, _ in saveConfig() }
    .onChange(of: config.sidebarVisible) { _, _ in saveConfig() }
    .onChange(of: config.popups) { _, _ in saveConfig() }
    .onChange(of: config.ssh) { _, _ in saveConfig() }
  }

  private func saveConfig() {
    try? config.save()
  }
}
