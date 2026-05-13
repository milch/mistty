import AppKit
import SwiftUI

struct DirectoryPickerView: View {
  @Bindable var vm: DirectoryPickerViewModel
  let title: String
  @Binding var isPresented: Bool
  let onConfirm: (URL) -> Void

  private var queryBinding: Binding<String> {
    Binding(
      get: { vm.query },
      set: { vm.updateQuery($0) }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.top, 12)
        FocusableTextField(
          text: queryBinding,
          placeholder: "Search directories…",
          onComplete: {
            if let value = vm.completionValue() {
              vm.updateQuery(value)
            }
          }
        )
        .font(.title3)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
      }

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
                if let url = vm.confirmSelection() {
                  onConfirm(url)
                }
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
