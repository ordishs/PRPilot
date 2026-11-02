import Foundation

/// One `AskUserQuestion` the agent put to the user, kept so the app can show it again after
/// the process that asked it has gone.
public struct AskedQuestion: Sendable, Equatable, Hashable, Identifiable {
    public struct Option: Sendable, Equatable, Hashable {
        public let label: String
        public let detail: String

        public init(label: String, detail: String) {
            self.label = label
            self.detail = detail
        }
    }

    public let question: String
    public let header: String
    public let multiSelect: Bool
    public let options: [Option]

    public var id: String { question }

    public init(question: String, header: String, multiSelect: Bool, options: [Option]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    /// The message that carries a choice back to the agent. It names the question, because a
    /// resumed agent has already been told the call was interrupted and needs to know which
    /// one the answer belongs to.
    public static func answerMessage(question: String, choices: [String]) -> String {
        let joined = choices.joined(separator: ", ")
        return "My answer to your question \"\(question)\": \(joined)"
    }
}
