public enum RebaseOutcome: Sendable, Equatable {
    case clean
    case conflicts([String])
}
