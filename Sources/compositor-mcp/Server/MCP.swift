import Foundation

// MARK: - JSON-RPC over stdio
//
// MCP's stdio transport is newline-delimited JSON-RPC 2.0: one message per line
// on stdin, one response per line on stdout. Anything Claude should not parse
// (logging, diagnostics) goes to stderr.

struct RPCError: Error {
    let code: Int
    let message: String
    static func invalidParams(_ m: String) -> RPCError { RPCError(code: -32602, message: m) }
    static func internalError(_ m: String) -> RPCError { RPCError(code: -32603, message: m) }
    static func methodNotFound(_ m: String) -> RPCError { RPCError(code: -32601, message: m) }
}

/// A tool's answer: human-readable text, plus optional rendered image.
struct ToolResult {
    var text: String
    var imagePNG: Data?
    init(_ text: String, imagePNG: Data? = nil) {
        self.text = text
        self.imagePNG = imagePNG
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(("[compositor-mcp] " + message + "\n").data(using: .utf8)!)
}

// MARK: - Parameter reading

/// Typed access to a tool call's arguments, with errors that name the argument.
struct Params {
    let raw: [String: Any]

    init(_ raw: [String: Any]?) { self.raw = raw ?? [:] }

    func string(_ key: String) throws -> String {
        guard let value = raw[key] as? String, !value.isEmpty else {
            throw RPCError.invalidParams("`\(key)` is required and must be a non-empty string.")
        }
        return value
    }
    func string(_ key: String, default fallback: String?) -> String? { raw[key] as? String ?? fallback }

    func int(_ key: String) throws -> Int {
        guard let value = raw[key] as? NSNumber else {
            throw RPCError.invalidParams("`\(key)` is required and must be a number.")
        }
        return value.intValue
    }
    func int(_ key: String, default fallback: Int?) -> Int? { (raw[key] as? NSNumber)?.intValue ?? fallback }

    func double(_ key: String) throws -> Double {
        guard let value = raw[key] as? NSNumber else {
            throw RPCError.invalidParams("`\(key)` is required and must be a number.")
        }
        return value.doubleValue
    }
    func double(_ key: String, default fallback: Double?) -> Double? { (raw[key] as? NSNumber)?.doubleValue ?? fallback }

    func bool(_ key: String, default fallback: Bool?) -> Bool? { raw[key] as? Bool ?? fallback }

    func strings(_ key: String) throws -> [String] {
        guard let value = raw[key] as? [Any] else {
            throw RPCError.invalidParams("`\(key)` is required and must be an array.")
        }
        return value.compactMap { $0 as? String }
    }

    func object(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }
    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }

    /// Expands `~` so the agent can pass the paths a person would type.
    func path(_ key: String) throws -> URL {
        URL(fileURLWithPath: (try string(key) as NSString).expandingTildeInPath)
    }
    func path(_ key: String, orNil: Bool) -> URL? {
        guard let value = raw[key] as? String, !value.isEmpty else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
}
