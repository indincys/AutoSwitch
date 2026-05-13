import Foundation

struct VisibilityDiff: Equatable {
    let appeared: Set<String>
    let disappeared: Set<String>

    var hasChanges: Bool {
        !appeared.isEmpty || !disappeared.isEmpty
    }

    static func resolve(previous: Set<String>, current: Set<String>) -> VisibilityDiff {
        VisibilityDiff(
            appeared: current.subtracting(previous),
            disappeared: previous.subtracting(current)
        )
    }
}
