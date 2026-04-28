import Testing
import Foundation
@testable import MisttyShared

struct WorkspaceSnapshotMigrationTests {
  @Test
  func decodesV2Directly() throws {
    let json = #"""
    {
      "version": 2,
      "windows": [
        {
          "id": 1,
          "sessions": [],
          "activeSessionID": null
        }
      ],
      "activeWindowID": 1
    }
    """#
    let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
    #expect(snap.version == 2)
    #expect(snap.windows.count == 1)
    #expect(snap.windows[0].id == 1)
    #expect(snap.activeWindowID == 1)
  }

  @Test
  func migratesV1IntoSingleWindow() throws {
    let json = #"""
    {
      "version": 1,
      "sessions": [
        {
          "id": 7,
          "name": "demo",
          "customName": null,
          "directory": "/Users/manu",
          "sshCommand": null,
          "lastActivatedAt": 1745337600,
          "tabs": [],
          "activeTabID": null
        }
      ],
      "activeSessionID": 7
    }
    """#
    let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
    #expect(snap.version == 2)
    #expect(snap.windows.count == 1)
    let win = snap.windows[0]
    #expect(win.id == 1)
    #expect(win.sessions.count == 1)
    #expect(win.sessions[0].id == 7)
    #expect(win.activeSessionID == 7)
    #expect(snap.activeWindowID == 1)
  }

  @Test
  func unsupportedVersionRecorded() throws {
    let json = #"""
    {
      "version": 99,
      "windows": []
    }
    """#
    let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
    #expect(snap.unsupportedVersion == 99)
  }

  @Test
  func roundTripsV2EncodeDecode() throws {
    let original = WorkspaceSnapshot(
      version: 2,
      windows: [
        WindowSnapshot(
          id: 3,
          sessions: [],
          activeSessionID: nil
        )
      ],
      activeWindowID: 3
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    #expect(decoded.version == 2)
    #expect(decoded.windows.count == 1)
    #expect(decoded.windows[0].id == 3)
    #expect(decoded.activeWindowID == 3)
  }
}
