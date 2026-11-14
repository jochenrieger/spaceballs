import CoreGraphics
import Foundation

/// UUID-based order planning, independent of Mission Control and desktop labels.
public enum SpaceRestoreOrder {
  public static func insertionIndex(
    spaceUUID: String, recordedOrder: [String], currentOrder: [String]
  ) -> Int {
    guard let index = recordedOrder.firstIndex(of: spaceUUID) else { return currentOrder.count }
    // A surviving successor is the strongest anchor, including a Default
    // Space that originally sat to the right of the returning desktops.
    for uuid in recordedOrder.dropFirst(index + 1) {
      if let slot = currentOrder.firstIndex(of: uuid) { return slot }
    }
    for uuid in recordedOrder.prefix(index).reversed() {
      if let slot = currentOrder.firstIndex(of: uuid) { return slot + 1 }
    }
    return currentOrder.count
  }

  public static func mismatchedDisplays(
    spaces: [SpaceInfo], recordedOrders: [String: [String]]
  ) -> [String] {
    recordedOrders.compactMap { display, saved in
      let savedSet = Set(saved)
      let actual = spaces.filter { $0.type == .desktop && $0.displayUUID == display }
        .map(\.uuid).filter { savedSet.contains($0) }
      let present = Set(actual)
      return actual == saved.filter { present.contains($0) } ? nil : display
    }.sorted()
  }

  /// Commit only a verified restore. No origin is consumed on a partial
  /// move or an order mismatch, including records already on their monitor.
  public static func completeRestore(
    plan: RestorePlanner.Plan, spaces: [SpaceInfo], store: EjectRecordStoring
  ) throws -> [String] {
    let missing = plan.moves.filter { move in
      !spaces.contains { $0.uuid == move.spaceUUID && $0.displayUUID == move.targetDisplayUUID }
    }.map(\.spaceID)
    let misordered = mismatchedDisplays(spaces: spaces, recordedOrders: plan.desktopOrders)
    guard missing.isEmpty && misordered.isEmpty else {
      throw SpaceRestoreError.verificationFailed(
        missingSpaces: missing, misorderedDisplays: misordered)
    }
    for record in plan.stale + plan.completed {
      store.clearEjection(spaceUUID: record.spaceUUID, displayUUID: record.displayUUID)
    }
    for move in plan.moves {
      guard let origin = plan.restoredOrigins[move.spaceUUID] else { continue }
      store.clearEjection(spaceUUID: move.spaceUUID, displayUUID: origin)
    }
    return plan.moves.map(\.spaceUUID)
  }

  /// Resolve a slot only from expanded, readable tile frames. Collapsed
  /// Mission Control bars can report stale frames outside the bar entirely.
  public static func dropPoint(
    bar: CGRect, tiles: [CGRect], insertionIndex: Int
  ) -> CGPoint? {
    guard bar.width > 4, bar.height > 0, !tiles.isEmpty, insertionIndex >= 0,
      insertionIndex == Int.max || insertionIndex <= tiles.count,
      tiles.allSatisfy({ $0.width > 0 && $0.height > 0 && bar.contains($0) })
    else { return nil }
    let sorted = tiles.sorted { $0.minX < $1.minX }
    let slot = min(max(insertionIndex, 0), sorted.count)
    let x: CGFloat
    if slot == 0 {
      x = sorted[0].minX - 8
    } else if slot == sorted.count {
      x = sorted[slot - 1].maxX + 8
    } else {
      x = (sorted[slot - 1].maxX + sorted[slot].minX) / 2
    }
    return CGPoint(x: min(max(x, bar.minX + 2), bar.maxX - 2), y: bar.midY)
  }
}

public enum SpaceRestoreError: Error, LocalizedError {
  case verificationFailed(missingSpaces: [UInt64], misorderedDisplays: [String])

  public var errorDescription: String? {
    switch self {
    case .verificationFailed(let missing, let displays):
      return "Restore verification failed: \(missing.count) Space(s) not returned, "
        + "\(displays.count) display(s) out of order. Eject records retained; "
        + "check Mission Control before retrying."
    }
  }
}
