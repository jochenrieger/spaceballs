import CoreGraphics
import Testing

@testable import SpaceballsCore

@Suite("Verified Space tile batches")
struct SpaceTileBatchTests {
  private func drag(_ slot: Int?) -> SpaceTileDrag {
    SpaceTileDrag(
      sourceSpaceIndex: 1, sourceScreenNumber: 1, targetScreenNumber: 2,
      targetSpaceIndex: slot)
  }

  @Test("A silently rejected finite drop stops dependent insertions")
  func silentFailureStops() {
    var events: [String] = []
    let completed = SpaceTileBatch.run(
      drags: [drag(0), drag(1)],
      perform: { index, _ in
        events.append("drop\(index)")
        return true  // mouse-up succeeded, but the Space snapped back
      },
      verify: { index in
        events.append("verify\(index)")
        return false
      })
    #expect(completed.isEmpty)
    #expect(events == ["drop0", "verify0"])
  }

  @Test("Append drags continue after either a grab failure or a silent snap-back")
  func independentAppendsContinue() {
    for silent in [false, true] {
      var attempted: [Int] = []
      let completed = SpaceTileBatch.run(
        drags: [drag(Int.max), drag(Int.max)],
        perform: { index, _ in
          attempted.append(index)
          return index == 1 || silent
        }, verify: { $0 == 1 })
      #expect(attempted == [0, 1])
      #expect(completed == [1])
    }
  }

  @Test("Verification happens before the next drag reads its source or target")
  func verificationIsSequential() {
    var events: [String] = []
    let completed = SpaceTileBatch.run(
      drags: [drag(1), drag(2)],
      perform: { index, _ in
        events.append("drop\(index)")
        return true
      },
      verify: { index in
        events.append("verify\(index)")
        return true
      })
    #expect(events == ["drop0", "verify0", "drop1", "verify1"])
    #expect(completed == [0, 1])
  }

  @Test("A legacy failed drop still permits later independent work")
  func legacyContinuation() {
    var attempted: [Int] = []
    let completed = SpaceTileBatch.run(
      drags: [drag(nil), drag(0)],
      perform: { index, _ in
        attempted.append(index)
        return index == 1
      })
    #expect(attempted == [0, 1])
    #expect(completed == [1])
  }

  @Test("Snap-back with a right-hand spare remains recoverable on retry")
  func rightHandSpareRetry() {
    let spaces = [
      SpaceInfo(id: 1, uuid: "personal", type: .desktop, displayUUID: "laptop", isCurrent: true),
      SpaceInfo(id: 6, uuid: "coding", type: .desktop, displayUUID: "laptop", isCurrent: false),
      SpaceInfo(id: 5, uuid: "mail", type: .desktop, displayUUID: "laptop", isCurrent: false),
      SpaceInfo(id: 7, uuid: "spare", type: .desktop, displayUUID: "external", isCurrent: true),
    ]
    let pending = ["mail": ["external"], "coding": ["external"]]
    let orders = ["external": ["mail", "coding", "spare"]]
    let plan = RestorePlanner.plan(spaces: spaces, pending: pending, recordedOrders: orders)
    #expect(plan.moves.map(\.spaceUUID) == ["mail", "coding"])
    #expect(plan.moves.map(\.targetIndex) == [0, 1])
    let drags = plan.moves.map { drag($0.targetIndex) }
    var target = ["spare"]
    let failed = SpaceTileBatch.run(drags: drags, perform: { _, _ in true }, verify: { _ in false })
    #expect(failed.isEmpty)
    #expect(target == ["spare"])
    // Since the dependent coding drop never ran, a fresh retry can still
    // insert both Spaces before the spare, rather than locking it on the left.
    let retry = RestorePlanner.plan(spaces: spaces, pending: pending, recordedOrders: orders)
    _ = SpaceTileBatch.run(
      drags: retry.moves.map { drag($0.targetIndex) },
      perform: { index, item in
        target.insert(retry.moves[index].spaceUUID, at: item.targetSpaceIndex!)
        return true
      }, verify: { _ in true })
    #expect(target == orders["external"])
  }

  @Test("A moving insertion gap is re-read after every glide")
  func followMovingGap() {
    var points = [CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 0)]
    var moves: [CGPoint] = []
    let result = SpaceRestoreOrder.followInsertionGap(
      from: .zero,
      read: {
        (points.removeFirst(), true)
      }, move: { _, target in moves.append(target) })
    #expect(result == CGPoint(x: 20, y: 0))
    #expect(moves == [CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0)])
    #expect(points.isEmpty)
  }

  @Test("Unstable or unreadable gap readings cannot authorize a release")
  func refuseUnstableGap() {
    var moves = 0
    #expect(
      SpaceRestoreOrder.followInsertionGap(
        from: .zero,
        read: {
          (CGPoint(x: 10, y: 0), false)
        }, move: { _, _ in moves += 1 }) == nil)
    #expect(
      SpaceRestoreOrder.followInsertionGap(from: .zero, read: { nil }, move: { _, _ in moves += 1 })
        == nil)
    #expect(moves == 0)
  }

  @Test("A gap that keeps moving cancels instead of accepting the last sample")
  func movingGapDeadline() {
    var position: CGFloat = 0
    var moves = 0
    let result = SpaceRestoreOrder.followInsertionGap(
      from: .zero,
      read: {
        position += 10
        return (CGPoint(x: position, y: 0), true)
      }, move: { _, _ in moves += 1 })
    #expect(result == nil)
    #expect(moves == 3)
  }
}
