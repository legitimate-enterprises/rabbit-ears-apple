extension RepeatMode {
    /// What one press of Repeat moves to.
    public var cycled: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}
