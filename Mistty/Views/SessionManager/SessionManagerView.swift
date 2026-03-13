import AppKit
import SwiftUI

struct SessionManagerView: View {
    @Bindable var vm: SessionManagerViewModel
    @Binding var isPresented: Bool
    @State private var queryText = ""

    var body: some View {
        VStack(spacing: 0) {
            FocusableTextField(
                text: $queryText,
                placeholder: "Search sessions, directories, hosts..."
            )
            .font(.title3)
            .padding(14)
            .onChange(of: queryText) { _, newValue in
                vm.updateQuery(newValue)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(vm.filteredItems.enumerated()), id: \.element.id) { index, item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    if let subtitle = item.subtitle {
                                        Text(subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(index == vm.selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.selectedIndex = index
                                vm.confirmSelection()
                                isPresented = false
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: vm.selectedIndex) { _, newValue in
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20)
        .task { await vm.load() }
    }
}

/// An NSTextField wrapper that steals first responder on appear,
/// ensuring it gets keyboard input even when an NSView (like the terminal) has focus.
struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 17)

        // Steal focus from the terminal on next run loop tick
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
