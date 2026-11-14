import Foundation
import Testing

@testable import SpaceballsCore

@Suite("Ordered restore display identity")
struct SpaceRestoreFingerprintTests {
  @Test("Saved order follows fingerprint remapping instead of a stale display UUID")
  func remappedOrder() {
    let fingerprint = DisplayFingerprint(
      vendorNumber: 1, modelNumber: 2, serialNumber: 3, originX: 1728, originY: 0)
    let spaces = [
      SpaceInfo(id: 5, uuid: "mail", type: .desktop, displayUUID: "laptop", isCurrent: false),
      SpaceInfo(id: 6, uuid: "coding", type: .desktop, displayUUID: "laptop", isCurrent: false),
      SpaceInfo(
        id: 7, uuid: "spare", type: .desktop, displayUUID: "new-office-id", isCurrent: true),
    ]
    let plan = RestorePlanner.plan(
      spaces: spaces, pending: ["mail": ["old-office-id"], "coding": ["old-office-id"]],
      recordedFingerprints: ["old-office-id": fingerprint],
      connectedFingerprints: ["new-office-id": fingerprint],
      recordedOrders: ["old-office-id": ["spare", "mail", "coding"]])
    #expect(plan.desktopOrders == ["new-office-id": ["spare", "mail", "coding"]])
    #expect(plan.moves.map(\.spaceUUID) == ["coding", "mail"])
    #expect(plan.moves.map(\.targetIndex) == [1, 1])
    #expect(plan.restoredOrigins == ["mail": "old-office-id", "coding": "old-office-id"])
  }

  @Test("Successful verified restore consumes only this site's origins and order")
  func successfulRestore() throws {
    let store = EjectStore(
      defaults: UserDefaults(suiteName: "ordered-roundtrip-\(UUID().uuidString)")!)
    for uuid in ["mail", "coding"] {
      store.recordEjection(spaceUUID: uuid, originalDisplayUUID: "office")
      store.recordEjection(spaceUUID: uuid, originalDisplayUUID: "home")
    }
    store.recordDesktopOrder(displayUUID: "office", spaceUUIDs: ["office-spare", "mail", "coding"])
    store.recordDesktopOrder(displayUUID: "home", spaceUUIDs: ["mail", "home-spare", "coding"])
    let parked = [
      SpaceInfo(id: 5, uuid: "mail", type: .desktop, displayUUID: "laptop", isCurrent: false),
      SpaceInfo(id: 6, uuid: "coding", type: .desktop, displayUUID: "laptop", isCurrent: false),
      SpaceInfo(
        id: 7, uuid: "office-spare", type: .desktop, displayUUID: "office", isCurrent: true),
    ]
    let plan = RestorePlanner.plan(
      spaces: parked, pending: store.pendingEjections(), recordedOrders: store.desktopOrders())
    let returned =
      [parked[2]]
      + parked.prefix(2).map {
        SpaceInfo(id: $0.id, uuid: $0.uuid, type: .desktop, displayUUID: "office", isCurrent: false)
      }
    #expect(
      try SpaceRestoreOrder.completeRestore(plan: plan, spaces: returned, store: store).count == 2)
    #expect(store.pendingEjections() == ["mail": ["home"], "coding": ["home"]])
    #expect(store.desktopOrders() == ["home": ["mail", "home-spare", "coding"]])
  }
}
