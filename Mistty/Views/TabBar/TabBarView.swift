import SwiftUI

struct TabBarView: View {
    @Bindable var session: MisttySession

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.tabs) { tab in
                        TabBarItem(
                            tab: tab,
                            isActive: session.activeTab?.id == tab.id,
                            onSelect: { session.activeTab = tab },
                            onClose: { session.closeTab(tab) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Button(action: { session.addTab() }) {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 36)
        .background(.bar)
    }
}

struct TabBarItem: View {
    @Bindable var tab: MisttyTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        .onTapGesture { onSelect() }
    }
}
