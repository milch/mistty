import Foundation

public protocol MisttyServiceProtocol {
    // MARK: - Sessions

    func createSession(name: String, directory: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void)
    func listSessions(reply: @escaping (Data?, Error?) -> Void)
    func getSession(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func closeSession(id: Int, reply: @escaping (Data?, Error?) -> Void)

    // MARK: - Tabs

    func createTab(sessionId: Int, name: String?, exec: String?, reply: @escaping (Data?, Error?) -> Void)
    func listTabs(sessionId: Int, reply: @escaping (Data?, Error?) -> Void)
    func getTab(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func closeTab(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func renameTab(id: Int, name: String, reply: @escaping (Data?, Error?) -> Void)

    // MARK: - Panes

    func createPane(tabId: Int, direction: String?, reply: @escaping (Data?, Error?) -> Void)
    func listPanes(tabId: Int, reply: @escaping (Data?, Error?) -> Void)
    func getPane(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func closePane(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func focusPane(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func focusPaneByDirection(direction: String, sessionId: Int, reply: @escaping (Data?, Error?) -> Void)
    func resizePane(id: Int, direction: String, amount: Int, reply: @escaping (Data?, Error?) -> Void)
    func activePane(reply: @escaping (Data?, Error?) -> Void)
    /// Use paneId 0 as sentinel for "active pane".
    func sendKeys(paneId: Int, keys: String, reply: @escaping (Data?, Error?) -> Void)
    /// Use paneId 0 as sentinel for "active pane".
    func runCommand(paneId: Int, command: String, reply: @escaping (Data?, Error?) -> Void)
    /// Use paneId 0 as sentinel for "active pane".
    func getText(paneId: Int, reply: @escaping (Data?, Error?) -> Void)

    // MARK: - Windows

    func createWindow(reply: @escaping (Data?, Error?) -> Void)
    func listWindows(reply: @escaping (Data?, Error?) -> Void)
    func getWindow(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func closeWindow(id: Int, reply: @escaping (Data?, Error?) -> Void)
    func focusWindow(id: Int, reply: @escaping (Data?, Error?) -> Void)

    // MARK: - Popups

    func openPopup(sessionId: Int, name: String, exec: String, width: Double, height: Double, closeOnExit: Bool, reply: @escaping (Data?, Error?) -> Void)
    func closePopup(popupId: Int, reply: @escaping (Data?, Error?) -> Void)
    func togglePopup(sessionId: Int, name: String, reply: @escaping (Data?, Error?) -> Void)
    func listPopups(sessionId: Int, reply: @escaping (Data?, Error?) -> Void)

    // MARK: - Debug

    func getStateSnapshot(reply: @escaping (Data?, Error?) -> Void)
}
