import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ContentMaschineKit

// MARK: - ContentMaschine tools
//
// Generated images land in the document as ordinary layers, so everything the
// other tools do (transform, blend, mask, adjust) applies to them too.

private let credentialsBox = CredentialsBox()

private actor CredentialsBox {
    private var client: ContentMaschineClient?
    func shared() throws -> ContentMaschineClient {
        if let client { return client }
        let made = ContentMaschineClient(credentials: try ContentMaschineCredentials.load())
        client = made
        return made
    }
}

func contentMaschine() async throws -> ContentMaschineClient {
    do { return try await credentialsBox.shared() }
    catch let error as ContentMaschineError {
        throw RPCError.invalidParams(error.errorDescription ?? "No ContentMaschine credentials.")
    }
}

// MARK: - Arguments shared by the generating tools

private func model(_ p: Params) throws -> ImageModel {
    guard let raw = p.string("model", default: nil) else { return .pro }
    guard let model = ImageModel(rawValue: raw) else {
        throw RPCError.invalidParams("`\(raw)` is not a model. Use one of: "
            + ImageModel.allCases.map { $0.rawValue }.joined(separator: ", ") + ".")
    }
    return model
}

private func resolution(_ p: Params) throws -> Resolution {
    guard let raw = p.int("resolution", default: nil) else { return .r2048 }
    guard let resolution = Resolution(rawValue: raw) else {
        throw RPCError.invalidParams(
            "`\(raw)` is not a resolution. Use 1024 or 2048. 4096 is not offered, because the "
            + "model tiles the background and corrupts type at that size.")
    }
    return resolution
}

private func aspect(_ p: Params) throws -> String {
    let ratios = ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"]
    let raw = p.string("aspect_ratio", default: "1:1")!
    guard ratios.contains(raw) else {
        throw RPCError.invalidParams("`\(raw)` is not an aspect ratio. Use one of: \(ratios.joined(separator: ", )")).")
    }
    return raw
}

// MARK: - Turning returned bytes into a layer

/// Decodes through Compositor's own importer, so a generated image is held
/// exactly like a file the person imported.
private func decode(_ data: Data, name: String) async throws -> ImportedImage {
    // Generations arrive as JPEG, cutouts as PNG. Name the file for what it is.
    let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cm-\(UUID().uuidString).\(isPNG ? "png" : "jpg")")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let imported = try await ImageImporter.shared.decode(url)
    return ImportedImage(image: imported.image, thumbnail: imported.thumbnail, name: name)
}

/// Places an image on the canvas: its own size, shrunk to fit when it would
/// overflow, centred unless the caller says otherwise.
private func place(_ imported: ImportedImage, in draft: inout Draft, name: String,
                   _ p: Params) throws -> UUID {
    let pixels = CGSize(width: imported.image.width, height: imported.image.height)
    var size = pixels
    let fits = min(Double(draft.manifest.width) / pixels.width,
                   Double(draft.manifest.height) / pixels.height, 1)
    if p.bool("fit", default: nil) == true || (p.bool("fit", default: nil) == nil && fits < 1) {
        let scale = p.bool("fit", default: nil) == true
            ? min(Double(draft.manifest.width) / pixels.width,
                  Double(draft.manifest.height) / pixels.height)
            : fits
        size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    }
    if let percent = p.double("scale_percent", default: nil) {
        guard percent > 0 else { throw RPCError.invalidParams("`scale_percent` must be greater than 0.") }
        size = CGSize(width: (pixels.width * percent / 100).rounded(),
                      height: (pixels.height * percent / 100).rounded())
    }
    let origin = CGPoint(
        x: p.double("x", default: (Double(draft.manifest.width) - Double(size.width)) / 2)!,
        y: p.double("y", default: (Double(draft.manifest.height) - Double(size.height)) / 2)!)

    let id = UUID()
    let record = ProjectLayerRecord(id: id, name: name, isVisible: true,
                                    transform: LayerTransform(origin: origin, size: size),
                                    imageFile: "\(id.uuidString).png")
    guard record.transform.isValid else { throw RPCError.invalidParams("That position or size is out of range.") }
    draft.manifest.layers.append(record)
    draft.images[id] = imported
    return id
}

/// The bytes of a layer's own pixels, ready to upload.
private func pixels(of layer: ProjectLayerRecord, in draft: Draft) throws -> Data {
    guard let image = draft.images[layer.id]?.image else {
        throw RPCError.invalidParams("\"\(layer.name)\" has no pixels to send. "
            + "Folders and adjustment layers cannot be used here.")
    }
    return try pngData(image)
}

private func credits(_ used: Double?) -> String {
    used.map { ", \($0.clean) credits" } ?? ""
}

// MARK: - Tools

func generateLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var draft = try await store.snapshot(handle).draft
    let prompt = try p.string("prompt")
    let client = try await contentMaschine()

    let result = try await client.generate(prompt: prompt, model: try model(p),
                                           aspectRatio: try aspect(p),
                                           resolution: try resolution(p))
    let name = p.string("name", default: String(prompt.prefix(40)))!
    let imported = try await decode(result.data, name: name)
    let id = try place(imported, in: &draft, name: name, p)
    try await store.update(handle, to: draft.snapshot)
    let record = try draft.layer(id.uuidString)
    return ToolResult("""
        Generated "\(name)" (\(imported.image.width)x\(imported.image.height) pixels\(credits(result.creditsUsed))) \
        and added it as a layer at \(record.transform.origin.x.clean),\(record.transform.origin.y.clean), \
        sized \(record.transform.size.width.clean)x\(record.transform.size.height.clean).
        Layer id: \(id.uuidString)
        """)
}

func varyLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var draft = try await store.snapshot(handle).draft
    let source = try draft.layer(try p.string("layer"))
    let prompt = try p.string("prompt")
    let client = try await contentMaschine()

    let uploaded = try await client.upload(try pixels(of: source, in: draft),
                                           filename: "\(source.name).png")
    let result = try await client.vary(fileUUID: uploaded.uuid, prompt: prompt,
                                       model: try model(p), aspectRatio: try aspect(p),
                                       resolution: try resolution(p))
    let name = p.string("name", default: source.name + " variation")!
    let imported = try await decode(result.data, name: name)
    let id = try place(imported, in: &draft, name: name, p)
    try await store.update(handle, to: draft.snapshot)
    return ToolResult("""
        Varied "\(source.name)" and added the result as "\(name)" \
        (\(imported.image.width)x\(imported.image.height)\(credits(result.creditsUsed))).
        Layer id: \(id.uuidString)
        """)
}

func fuseLayers(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var draft = try await store.snapshot(handle).draft
    let ids = try p.strings("layers")
    guard ids.count >= 2 else { throw RPCError.invalidParams("`layers` needs at least two layers to fuse.") }
    let sources = try ids.map { try draft.layer($0) }
    let prompt = try p.string("prompt")
    let client = try await contentMaschine()

    // Uploaded one at a time: parallel submissions trip the rate limit.
    var uuids: [String] = []
    for source in sources {
        uuids.append(try await client.upload(try pixels(of: source, in: draft),
                                             filename: "\(source.name).png").uuid)
    }
    let result = try await client.fuse(fileUUIDs: uuids, prompt: prompt, model: try model(p),
                                       aspectRatio: try aspect(p), resolution: try resolution(p))
    let name = p.string("name", default: "Fusion")!
    let imported = try await decode(result.data, name: name)
    let id = try place(imported, in: &draft, name: name, p)
    try await store.update(handle, to: draft.snapshot)
    return ToolResult("""
        Fused \(sources.count) layers (\(sources.map(\.name).joined(separator: ", "))) into "\(name)" \
        (\(imported.image.width)x\(imported.image.height)\(credits(result.creditsUsed))).
        Fusion re-renders rather than pastes, so the result reproduces the sources rather than copying their pixels.
        Layer id: \(id.uuidString)
        """)
}

func removeLayerBackground(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var draft = try await store.snapshot(handle).draft
    let index = try draft.layerIndex(try p.string("layer"))
    let source = draft.manifest.layers[index]
    guard let original = draft.images[source.id]?.image else {
        throw RPCError.invalidParams("\"\(source.name)\" has no pixels to cut out.")
    }
    let client = try await contentMaschine()

    let uploaded = try await client.upload(try pngData(original), filename: "\(source.name).png")
    let cutData = try await client.removeBackground(fileUUID: uploaded.uuid,
                                                    subjectHint: p.string("subject_hint", default: nil))
    guard let provider = CGDataProvider(data: cutData as CFData),
          let cut = CGImage(pngDataProviderSource: provider, decode: nil,
                            shouldInterpolate: true, intent: .defaultIntent) else {
        throw RPCError.internalError("The cutout could not be read as a PNG.")
    }

    // The service normalises to about one megapixel in 64-pixel steps, so the
    // cutout rarely matches the input pixel for pixel. Its alpha can only be
    // carried back onto the original when the shape survived that snapping;
    // otherwise the image was cropped and stretching the alpha misaligns it.
    let originalAspect = Double(original.width) / Double(original.height)
    let cutAspect = Double(cut.width) / Double(cut.height)
    let sameShape = abs(originalAspect - cutAspect) < 0.005

    var finished = cut
    var reshaped: LayerTransform?
    var note = ""
    if sameShape {
        if original.width > cut.width {
            finished = try applyAlpha(of: cut, to: original)
            note = " The cutout came back at \(cut.width)x\(cut.height); its shape matched, so its alpha "
                 + "was carried onto the original \(original.width)x\(original.height) pixels and no "
                 + "resolution was lost."
        }
    } else {
        // Its own pixels and alpha agree with each other, so they are used as
        // they are, and the layer is reshaped so nothing is stretched.
        var transform = source.transform
        let centre = transform.center
        transform.size = CGSize(width: (transform.size.height * cutAspect).rounded(),
                                height: transform.size.height.rounded())
        transform.origin = CGPoint(x: centre.x - transform.size.width / 2,
                                   y: centre.y - transform.size.height / 2)
        reshaped = transform
        note = " The service returned \(cut.width)x\(cut.height) for a \(original.width)x"
             + "\(original.height) layer, a different shape, so its own pixels were kept rather than "
             + "mapping a mismatched alpha onto the original. The layer was reshaped to "
             + "\(transform.size.width.clean)x\(transform.size.height.clean) around its centre so "
             + "nothing is stretched. Send a square layer to keep full resolution."
    }

    let imported = try await decode(try pngData(finished), name: source.name)
    if p.bool("as_new_layer", default: false)! {
        let name = p.string("name", default: source.name + " cutout")!
        let id = try place(imported, in: &draft, name: name, p)
        try await store.update(handle, to: draft.snapshot)
        return ToolResult("Cut \"\(source.name)\" out and added it as \"\(name)\".\(note)\nLayer id: \(id.uuidString)")
    }
    draft.images[source.id] = imported
    if let reshaped { draft.manifest.layers[index] = try source.withTransform(reshaped) }
    try await store.update(handle, to: draft.snapshot)
    let placement = reshaped == nil ? " Its transform is unchanged." : ""
    return ToolResult("Removed the background from \"\(source.name)\".\(placement)\(note)")
}

/// Draws the original, then keeps only what the cutout's alpha covers.
private func applyAlpha(of cut: CGImage, to original: CGImage) throws -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: original.width, height: original.height,
                                  bitsPerComponent: 8, bytesPerRow: original.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw RPCError.internalError("Could not combine the cutout with the original.")
    }
    let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
    context.interpolationQuality = .high
    context.draw(original, in: bounds)
    context.setBlendMode(.destinationIn)
    context.draw(cut, in: bounds)
    guard let image = context.makeImage() else {
        throw RPCError.internalError("Could not combine the cutout with the original.")
    }
    return image
}

func upscaleLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var draft = try await store.snapshot(handle).draft
    let index = try draft.layerIndex(try p.string("layer"))
    let source = draft.manifest.layers[index]
    let scale = p.int("scale", default: 2)!
    guard [2, 4, 6, 8].contains(scale) else {
        throw RPCError.invalidParams("`scale` must be 2, 4, 6 or 8.")
    }
    let client = try await contentMaschine()
    let uploaded = try await client.upload(try pixels(of: source, in: draft),
                                           filename: "\(source.name).png")
    let result = try await client.upscale(fileUUID: uploaded.uuid, scale: scale)
    let imported = try await decode(result.data, name: source.name)
    let before = draft.images[source.id]?.image
    draft.images[source.id] = imported
    try await store.update(handle, to: draft.snapshot)
    let was = before.map { "\($0.width)x\($0.height)" } ?? "?"
    return ToolResult("""
        Upscaled "\(source.name)" \(scale)x, from \(was) to \
        \(imported.image.width)x\(imported.image.height)\(credits(result.creditsUsed)). \
        Its transform is unchanged, so it occupies the same place on the canvas at higher quality.
        """)
}

func restyleComposition(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var draft = try await store.snapshot(handle).draft
    let prompt = try p.string("prompt")
    let client = try await contentMaschine()

    // The flattened composition becomes the input, so the model restyles what
    // the canvas actually shows.
    let raster = try await ImageExporter.shared.render(draft.snapshot)
    let uploaded = try await client.upload(try pngData(raster.image), filename: "composition.png")
    let result = try await client.vary(fileUUID: uploaded.uuid, prompt: prompt, model: try model(p),
                                       aspectRatio: try aspect(p), resolution: try resolution(p))
    let name = p.string("name", default: "Restyled")!
    let imported = try await decode(result.data, name: name)

    var placement = Params(p.raw.merging(["fit": true]) { current, _ in current })
    if p.bool("fit", default: nil) == nil {
        placement = Params(p.raw.merging(["fit": true]) { _, new in new })
    }
    let id = try place(imported, in: &draft, name: name, placement)
    try await store.update(handle, to: draft.snapshot)
    return ToolResult("""
        Restyled the whole composition and added the result as "\(name)" \
        (\(imported.image.width)x\(imported.image.height)\(credits(result.creditsUsed))). \
        The original layers are untouched below it; hide or delete them if you only want the restyled version.
        Layer id: \(id.uuidString)
        """)
}

func listGenerations(_ p: Params) async throws -> ToolResult {
    let client = try await contentMaschine()
    let entries = try await client.gallery(limit: min(100, max(1, p.int("limit", default: 25)!)))
    guard !entries.isEmpty else { return ToolResult("The ContentMaschine gallery is empty.") }
    let rows = entries.map { entry -> String in
        let cost = entry.creditsUsed.map { " \($0.clean)cr" } ?? ""
        let file = entry.fileUUID ?? "(no file)"
        return "\(entry.createdAt.prefix(10))\(cost)  \(entry.title.prefix(60))\n    file: \(file)"
    }
    return ToolResult("""
        \(entries.count) past generations. Importing one costs no credits and returns the original file.

        \(rows.joined(separator: "\n"))
        """)
}

func importGeneration(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var draft = try await store.snapshot(handle).draft
    let fileUUID = try p.string("file")
    let client = try await contentMaschine()
    let data = try await client.download(fileUUID: fileUUID)
    let name = p.string("name", default: "Generation")!
    let imported = try await decode(data, name: name)
    let id = try place(imported, in: &draft, name: name, p)
    try await store.update(handle, to: draft.snapshot)
    return ToolResult("""
        Imported the stored generation as "\(name)" \
        (\(imported.image.width)x\(imported.image.height)). No credits were used.
        Layer id: \(id.uuidString)
        """)
}
