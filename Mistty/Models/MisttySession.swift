import Foundation

@Observable
@MainActor
final class MisttySession: Identifiable {
    let id = UUID()
    var name: String
    let directory: URL
    private(set) var tabs: [MisttyTab] = []
    var activeTab: MisttyTab?

    init(name: String, directory: URL) {
        self.name = name
        self.directory = directory
        addTab()
    }

    func addTab() {
        let tab = MisttyTab(directory: directory)
        tabs.append(tab)
        activeTab = tab
    }

    func closeTab(_ tab: MisttyTab) {
        tabs.removeAll { $0.id == tab.id }
        if activeTab?.id == tab.id { activeTab = tabs.last }
    }
}
