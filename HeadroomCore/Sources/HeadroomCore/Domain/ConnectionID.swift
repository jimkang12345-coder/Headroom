import Foundation

public struct ConnectionID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String {
        rawValue.uuidString
    }

    public var uuidString: String {
        rawValue.uuidString
    }
}

public struct ConnectionGenerationID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String {
        rawValue.uuidString
    }

    public var uuidString: String {
        rawValue.uuidString
    }
}
