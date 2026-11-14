import CoreGraphics
import Foundation
import Testing

@testable import SpaceballsCore

private func orderedDesktop(_ uuid: String, display: String, id: UInt64 = 1) -> SpaceInfo {
  SpaceInfo(id: id, uuid: uuid, type: .desktop, displayUUID: display, isCurrent: false)
}

@Suite("Desktop order restoration")
struct SpaceRestoreOrderTests {
  private func store() -> EjectStore {
    EjectStore(defaults: UserDefaults(suiteName: "restore-order-\(UUID().uuidString)")!)
  }

  @Test("Restore the observed reversed parking order after the staying spare")
  func officeRegression() {
    let spaces = [
      orderedDesktop("personal", display: "laptop", id: 1),
      orderedDesktop("coding", display: "laptop", id: 6),
      orderedDesktop("mail", display: "laptop", id: 5),
      orderedDesktop("parking", display: "laptop", id: 2),
      orderedDesktop("spare", display: "office", id: 3),
    ]
    let plan = RestorePlanner.plan(
      spaces: spaces, pending: ["mail": ["office"], "coding": ["office"]],
      recordedOrders: ["office": ["spare", "mail", "coding"]])
    #expect(plan.moves.map(\.spaceUUID) == ["mail", "coding"])
    #expect(plan.moves.map(\.sourceIndex) == [2, 1])
    #expect(plan.moves.map(\.targetIndex) == [1, 2])
    #expect(plan.desktopOrders == ["office": ["spare", "mail", "coding"]])
  }

  @Test("Every parked permutation and anchor position restores the saved order")
  func permutations() {
    let permutations = [
      ["spare", "mail", "coding"], ["spare", "coding", "mail"],
      ["mail", "spare", "coding"], ["mail", "coding", "spare"],
      ["coding", "spare", "mail"], ["coding", "mail", "spare"],
    ]
    for saved in permutations {
      for parked in [["mail", "coding"], ["coding", "mail"]] {
        let spaces =
          [orderedDesktop("personal", display: "laptop", id: 1)]
          + parked.enumerated().map {
            orderedDesktop($0.element, display: "laptop", id: UInt64($0.offset + 2))
          }
          + [orderedDesktop("spare", display: "office", id: 4)]
        let plan = RestorePlanner.plan(
          spaces: spaces, pending: ["mail": ["office"], "coding": ["office"]],
          recordedOrders: ["office": saved])
        var target = ["spare"]
        var source = ["personal"] + parked
        for move in plan.moves {
          #expect(source[move.sourceIndex] == move.spaceUUID)
          source.remove(at: move.sourceIndex)
          target.insert(move.spaceUUID, at: move.targetIndex!)
        }
        #expect(target == saved)
        #expect(source == ["personal"])
      }
    }
  }

  @Test("An already returned successor anchors a partially restored desktop")
  func partialRestore() {
    #expect(
      SpaceRestoreOrder.insertionIndex(
        spaceUUID: "mail", recordedOrder: ["spare", "mail", "coding"],
        currentOrder: ["new", "spare", "coding"]) == 2)
    #expect(
      SpaceRestoreOrder.insertionIndex(
        spaceUUID: "coding", recordedOrder: ["spare", "mail", "coding"],
        currentOrder: ["new", "spare", "mail"]) == 3)
  }

  @Test("Legacy records without order retain their existing restore path")
  func legacyRecords() {
    let plan = RestorePlanner.plan(
      spaces: [
        orderedDesktop("mail", display: "laptop"),
        orderedDesktop("spare", display: "office", id: 2),
      ],
      pending: ["mail": ["office"]])
    #expect(plan.moves.count == 1)
    #expect(plan.moves[0].targetIndex == nil)
    #expect(plan.desktopOrders.isEmpty)
  }

  @Test("Separate home and office orders survive a site round trip")
  func perSiteOrders() {
    let store = store()
    for uuid in ["mail", "coding"] {
      store.recordEjection(spaceUUID: uuid, originalDisplayUUID: "office")
      store.recordEjection(spaceUUID: uuid, originalDisplayUUID: "home")
    }
    store.recordDesktopOrder(displayUUID: "office", spaceUUIDs: ["office-spare", "mail", "coding"])
    store.recordDesktopOrder(displayUUID: "home", spaceUUIDs: ["mail", "home-spare", "coding"])
    for (display, spare) in [("office", "office-spare"), ("home", "home-spare")] {
      let plan = RestorePlanner.plan(
        spaces: [
          orderedDesktop("mail", display: "laptop", id: 5),
          orderedDesktop("coding", display: "laptop", id: 6),
          orderedDesktop(spare, display: display, id: 7),
        ],
        pending: store.pendingEjections(), recordedOrders: store.desktopOrders())
      #expect(plan.desktopOrders == [display: store.desktopOrders()[display]!])
      #expect(plan.restoredOrigins == ["mail": display, "coding": display])
    }
    store.clearEjection(spaceUUID: "mail", displayUUID: "office")
    #expect(store.desktopOrders()["office"] != nil)
    store.clearEjection(spaceUUID: "coding", displayUUID: "office")
    #expect(store.desktopOrders()["office"] == nil)
    #expect(store.desktopOrders()["home"] == ["mail", "home-spare", "coding"])
  }

  @Test("A partial eject retry cannot overwrite the full original order")
  func partialEjectRetry() {
    let store = store()
    store.recordEjection(spaceUUID: "coding", originalDisplayUUID: "office")
    store.recordDesktopOrder(displayUUID: "office", spaceUUIDs: ["spare", "mail", "coding"])
    store.recordDesktopOrder(displayUUID: "office", spaceUUIDs: ["spare", "mail", "new"])
    #expect(store.desktopOrders()["office"] == ["spare", "mail", "coding", "new"])
  }

  @Test("Desktop order persists across store instances")
  func persistence() {
    let defaults = UserDefaults(suiteName: "restore-persistence-\(UUID().uuidString)")!
    let first = EjectStore(defaults: defaults)
    first.recordDesktopOrder(displayUUID: "office", spaceUUIDs: ["spare", "mail", "coding"])
    #expect(EjectStore(defaults: defaults).desktopOrders() == first.desktopOrders())
  }

  @Test("A failed or misordered restore never clears origins or the saved order")
  func failedRestoreRetainsRecords() throws {
    let store = store()
    for uuid in ["mail", "coding"] {
      store.recordEjection(spaceUUID: uuid, originalDisplayUUID: "office")
    }
    store.recordDesktopOrder(displayUUID: "office", spaceUUIDs: ["spare", "mail", "coding"])
    let before = store.pendingEjections()
    let parked = [
      orderedDesktop("mail", display: "laptop", id: 5),
      orderedDesktop("coding", display: "laptop", id: 6),
      orderedDesktop("spare", display: "office", id: 7),
    ]
    let plan = RestorePlanner.plan(
      spaces: parked, pending: before, recordedOrders: store.desktopOrders())
    #expect(throws: SpaceRestoreError.self) {
      try SpaceRestoreOrder.completeRestore(plan: plan, spaces: parked, store: store)
    }
    let wrong = [
      orderedDesktop("coding", display: "office", id: 6),
      orderedDesktop("mail", display: "office", id: 5),
      orderedDesktop("spare", display: "office", id: 7),
    ]
    #expect(throws: SpaceRestoreError.self) {
      try SpaceRestoreOrder.completeRestore(plan: plan, spaces: wrong, store: store)
    }
    #expect(store.pendingEjections() == before)
    // Retry planning sees those Spaces already on their monitor. It must
    // still reject the wrong order rather than silently consuming records.
    let retry = RestorePlanner.plan(
      spaces: wrong, pending: before, recordedOrders: store.desktopOrders())
    #expect(throws: SpaceRestoreError.self) {
      try SpaceRestoreOrder.completeRestore(plan: retry, spaces: wrong, store: store)
    }
    #expect(store.pendingEjections() == before)
    #expect(store.desktopOrders()["office"] != nil)
    let correct = [wrong[2], wrong[1], wrong[0]]
    _ = try SpaceRestoreOrder.completeRestore(plan: retry, spaces: correct, store: store)
    #expect(store.pendingEjections().isEmpty)
    #expect(store.desktopOrders().isEmpty)
  }

  @Test("New and removed desktops do not invalidate relative order")
  func changedInventory() {
    let spaces = [
      orderedDesktop("spare", display: "office"), orderedDesktop("new", display: "office"),
      orderedDesktop("coding", display: "office"),
    ]
    #expect(
      SpaceRestoreOrder.mismatchedDisplays(
        spaces: spaces, recordedOrders: ["office": ["spare", "removed", "coding"]]
      ).isEmpty)
  }

  @Test("Insertion gaps use expanded frames, never stale collapsed coordinates")
  func insertionGeometry() {
    let bar = CGRect(x: 1728, y: -100, width: 2560, height: 180)
    let tiles = [
      CGRect(x: 2700, y: -80, width: 160, height: 100),
      CGRect(x: 2900, y: -80, width: 160, height: 100),
    ]
    #expect(SpaceRestoreOrder.dropPoint(bar: bar, tiles: tiles, insertionIndex: 0)?.x == 2692)
    #expect(SpaceRestoreOrder.dropPoint(bar: bar, tiles: tiles, insertionIndex: 1)?.x == 2880)
    #expect(SpaceRestoreOrder.dropPoint(bar: bar, tiles: tiles, insertionIndex: Int.max)?.x == 3068)
    #expect(
      SpaceRestoreOrder.dropPoint(bar: bar, tiles: tiles.reversed(), insertionIndex: 1)?.x == 2880)
    #expect(SpaceRestoreOrder.dropPoint(bar: bar, tiles: [], insertionIndex: 0) == nil)
    #expect(SpaceRestoreOrder.dropPoint(bar: bar, tiles: tiles, insertionIndex: 3) == nil)
    #expect(SpaceRestoreOrder.dropPoint(bar: bar, tiles: tiles, insertionIndex: -1) == nil)
    #expect(
      SpaceRestoreOrder.dropPoint(
        bar: CGRect(x: 1728, y: 0, width: 2560, height: 20), tiles: tiles, insertionIndex: 1) == nil
    )
  }
}
