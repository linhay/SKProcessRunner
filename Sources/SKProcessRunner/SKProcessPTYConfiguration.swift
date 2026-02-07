import Foundation

public struct SKProcessPTYConfiguration: Sendable, Equatable {
    public var rows: Int
    public var cols: Int
    public var term: String

    public init(rows: Int = 24, cols: Int = 80, term: String = "xterm-256color") {
        self.rows = rows
        self.cols = cols
        self.term = term
    }
}
