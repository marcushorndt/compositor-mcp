import Foundation

// compositor-mcp: an MCP server for Compositor projects.
//
// It edits .comp documents headlessly, using Compositor's own document model,
// renderer and project store, so what it produces is what the app opens.

let serverVersion = "0.1.0"
let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

let store = DocumentStore()
let out = FileHandle.standardOutput

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
        log("could not encode a response")
        return
    }
    out.write(data)
    out.write("\n".data(using: .utf8)!)
}

func respond(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func respond(id: Any, error: RPCError) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
}

func handle(_ message: [String: Any]) async {
    guard let method = message["method"] as? String else { return }
    let id = message["id"]

    switch method {
    case "initialize":
        let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
        let version = supportedProtocols.contains(requested ?? "") ? requested! : supportedProtocols[0]
        respond(id: id ?? NSNull(), result: [
            "protocolVersion": version,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "compositor-mcp", "version": serverVersion],
            "instructions": """
                Edits Compositor (.comp) image projects: layers, transforms, blend modes, masks, \
                adjustment layers, canvas size, and PNG/JPEG export. Open or create a document first, \
                then use its handle. Call describe_document before editing layers, and render_preview \
                to see the result.
                """,
        ])

    case "notifications/initialized", "notifications/cancelled":
        return  // Notifications carry no id and take no reply.

    case "ping":
        respond(id: id ?? NSNull(), result: [:])

    case "tools/list":
        respond(id: id ?? NSNull(), result: ["tools": toolCatalogue])

    case "tools/call":
        guard let id else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let name = params["name"] as? String else {
            respond(id: id, error: .invalidParams("A tool call needs a `name`."))
            return
        }
        let arguments = Params(params["arguments"] as? [String: Any])
        do {
            let result = try await callTool(name, arguments, store)
            var content: [[String: Any]] = [["type": "text", "text": result.text]]
            if let png = result.imagePNG {
                content.append(["type": "image",
                                "data": png.base64EncodedString(),
                                "mimeType": "image/png"])
            }
            respond(id: id, result: ["content": content, "isError": false])
        } catch let error as RPCError {
            // A tool failure is reported in the result, not as a protocol error,
            // so the model can read it and correct itself.
            respond(id: id, result: ["content": [["type": "text", "text": error.message]], "isError": true])
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            respond(id: id, result: ["content": [["type": "text", "text": text]], "isError": true])
        }

    default:
        if let id { respond(id: id, error: .methodNotFound("Unsupported method `\(method)`.")) }
    }
}

log("compositor-mcp \(serverVersion) ready")

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
    guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        log("ignored a line that was not JSON-RPC")
        continue
    }
    await handle(message)
}
