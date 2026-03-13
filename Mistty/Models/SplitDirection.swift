enum SplitDirection: Sendable, Equatable {
    case horizontal, vertical

    var toggled: SplitDirection {
        switch self {
        case .horizontal: return .vertical
        case .vertical: return .horizontal
        }
    }
}
