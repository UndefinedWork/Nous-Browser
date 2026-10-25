import Foundation

/// Operates on draft IDs without mutating browser tabs or loading pages.
/// The input has unique IDs and a contiguous pinned prefix, as in BrowserModel.
nonisolated enum TabReordering {
    static func destinationIndex(for id: UUID, in order: [UUID], pinnedIDs: Set<UUID>, proposedIndex: Int) -> Int? {
        guard order.contains(id) else { return nil }
        let pinnedCount = order.reduce(into: 0) { count, id in
            if pinnedIDs.contains(id) { count += 1 }
        }
        let lower = pinnedIDs.contains(id) ? 0 : pinnedCount
        let upper = pinnedIDs.contains(id) ? pinnedCount - 1 : order.count - 1
        return min(upper, max(lower, proposedIndex))
    }

    /// Destination is the final absolute index, including for downward moves.
    static func moving(_ id: UUID, in order: [UUID], pinnedIDs: Set<UUID>, to proposedIndex: Int) -> [UUID] {
        guard let source = order.firstIndex(of: id),
              let destination = destinationIndex(for: id, in: order, pinnedIDs: pinnedIDs, proposedIndex: proposedIndex),
              source != destination else { return order }
        var result = order
        result.remove(at: source)
        result.insert(id, at: destination)
        return result
    }
}
