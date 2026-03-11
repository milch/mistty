import SwiftUI

struct SessionManagerView: View {
    @Bindable var vm: SessionManagerViewModel
    @Binding var isPresented: Bool
    @State private var queryText = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search sessions, directories, hosts...", text: $queryText)
                .textFieldStyle(.plain)
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
        .onKeyPress(.upArrow) { vm.moveUp(); return .handled }
        .onKeyPress(.downArrow) { vm.moveDown(); return .handled }
        .onKeyPress(.return) { vm.confirmSelection(); isPresented = false; return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .task { await vm.load() }
    }
}
