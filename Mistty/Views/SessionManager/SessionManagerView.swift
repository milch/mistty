import AppKit
import SwiftUI

struct HighlightedText: View {
  let text: String
  let indices: Set<Int>

  var body: some View {
    if indices.isEmpty {
      Text(text)
    } else {
      text.enumerated().reduce(Text("")) { result, pair in
        let char = String(pair.element)
        return result
          + Text(char)
          .foregroundColor(indices.contains(pair.offset) ? .accentColor : .primary)
      }
    }
  }
}

struct SessionManagerView: View {
  @Bindable var vm: SessionManagerViewModel
  @Binding var isPresented: Bool

  private var queryBinding: Binding<String> {
    Binding(
      get: { vm.query },
      set: { vm.updateQuery($0) }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      FocusableTextField(
        text: queryBinding,
        placeholder: "Search sessions, directories, hosts...",
        onComplete: {
          if let value = vm.completionValue() {
            vm.updateQuery(value)
          }
        }
      )
      .font(.title3)
      .padding(14)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(vm.filteredItems.enumerated()), id: \.element.id) { index, item in
              HStack(spacing: 8) {
                Image(systemName: item.symbolName)
                  .font(.system(size: 13))
                  .frame(width: 16, height: 16)
                  .foregroundStyle(index == vm.selectedIndex ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                  let matchResult = vm.matchResults[item.id]
                  HighlightedText(
                    text: item.displayName,
                    indices: Set(matchResult?.displayNameIndices ?? [])
                  )
                  .font(.system(size: 13))
                  .lineLimit(1)
                  if let subtitle = item.subtitle {
                    HighlightedText(
                      text: subtitle,
                      indices: Set(matchResult?.subtitleIndices ?? [])
                    )
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
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                vm.confirmSelection(modifierFlags: flags)
                isPresented = false
              }
            }
          }
        }
        .frame(maxHeight: 360)
        .id(vm.query)
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
  var onComplete: (() -> Void)?

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
    Coordinator(text: $text, onComplete: onComplete)
  }

  class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    var onComplete: (() -> Void)?

    init(text: Binding<String>, onComplete: (() -> Void)?) {
      self.text = text
      self.onComplete = onComplete
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      text.wrappedValue = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
      -> Bool
    {
      if commandSelector == #selector(NSResponder.insertTab(_:)) {
        onComplete?()
        return true
      }
      if commandSelector == #selector(NSResponder.moveRight(_:)) {
        // Only complete if cursor is at the end
        if textView.selectedRange().location == textView.string.count {
          onComplete?()
          return true
        }
        return false
      }
      return false
    }
  }
}
