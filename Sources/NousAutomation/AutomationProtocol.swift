import Foundation

/// A deliberately small, SDK-independent wire format shared by the GUI and its
/// stdio MCP helper. Browser state never needs to be sent to a web server.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var doubleValue: Double? { if case .number(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

public struct AutomationRequest: Codable, Sendable, Equatable {
    public let tool: String
    public let arguments: [String: JSONValue]
    public init(tool: String, arguments: [String: JSONValue] = [:]) {
        self.tool = tool
        self.arguments = arguments
    }
}

public struct AutomationResponse: Codable, Sendable, Equatable {
    public let result: JSONValue?
    public let error: String?
    public let imageBase64: String?
    public init(result: JSONValue? = nil, error: String? = nil, imageBase64: String? = nil) {
        self.result = result
        self.error = error
        self.imageBase64 = imageBase64
    }
}

public enum AutomationEndpoint {
    public static let maxRequestBytes = 1_048_576
    public static let maxResponseBytes = 16_777_216
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/NousBrowser/automation/bridge.sock").path
    }
}

public struct AutomationError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
