import Foundation

/// Execute and verify each drop before using slots that depend on it. Eject
/// appends are independent, so one failure must not strand all later Spaces.
enum SpaceTileBatch {
  static func run(
    drags: [SpaceTileDrag], perform: (Int, SpaceTileDrag) -> Bool,
    verify: ((Int) -> Bool)? = nil, afterEach: () -> Void = {}
  ) -> [Int] {
    var completed: [Int] = []
    for (index, drag) in drags.enumerated() {
      let landed = perform(index, drag) && (verify?(index) ?? true)
      if landed {
        completed.append(index)
      } else if let slot = drag.targetSpaceIndex, slot != Int.max {
        break
      }
      afterEach()
    }
    return completed
  }
}
