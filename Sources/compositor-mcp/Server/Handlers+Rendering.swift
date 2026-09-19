import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Adjustments

/// `LayerAdjustment` is Codable, so the agent can send the same JSON the
/// project file stores. Settings are merged over the kind's defaults, which
/// keeps a partial `{"exposure": 0.5}` valid.
func describeAdjustment(_ p: Params) throws -> ToolResult {
    let kind = try adjustmentKind(p)
    let defaults = try encodeAdjustment(materialised(kind))
    let relevant = trimAdjustment(defaults, to: kind)
    let json = try prettyJSON(relevant)
    return ToolResult("""
        Settings for a \(kind.rawValue) adjustment, with defaults. Pass any subset as `settings`.

        \(json)
        """)
}

private func adjustmentKind(_ p: Params) throws -> AdjustmentKind {
    let raw = try p.string("kind")
    guard let kind = AdjustmentKind(rawValue: raw) else {
        throw RPCError.invalidParams("`\(raw)` is not an adjustment. Use one of: \(adjustmentKinds.joined(separator: ", ")).")
    }
    return kind
}

/// The per-kind settings stay nil until something uses them, and a Codable
/// round trip needs every field present, so fill in that kind's own defaults
/// before showing or merging them.
private func materialised(_ kind: AdjustmentKind) -> LayerAdjustment {
    var adjustment = LayerAdjustment(kind: kind)
    switch kind {
    case .hsv: adjustment.hsvSettings = adjustment.resolvedHSV
    case .exposure: adjustment.exposureSettings = adjustment.exposure
    case .gradientMap: adjustment.gradientMapSettings = adjustment.gradientMap
    case .grain: adjustment.grainSettings = adjustment.grain
    case .levels, .curves: break
    }
    return adjustment
}

private func encodeAdjustment(_ adjustment: LayerAdjustment) throws -> [String: Any] {
    let data = try JSONEncoder().encode(adjustment)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RPCError.internalError("Could not read the adjustment's settings.")
    }
    return object
}

/// Every kind decodes from the same record, so only the fields that kind
/// actually uses are worth showing.
private func trimAdjustment(_ object: [String: Any], to kind: AdjustmentKind) -> [String: Any] {
    let keep: Set<String>
    switch kind {
    case .hsv: keep = ["kind", "hue", "saturation", "lightness", "colorize", "hsvSettings"]
    case .levels: keep = ["kind", "levels"]
    case .curves: keep = ["kind", "curves"]
    case .exposure: keep = ["kind", "exposureSettings"]
    case .gradientMap: keep = ["kind", "gradientMapSettings"]
    case .grain: keep = ["kind", "grainSettings"]
    }
    return object.filter { keep.contains($0.key) }
}

private func deepMerged(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
    var result = base
    for (key, value) in patch {
        if let nested = value as? [String: Any], let existing = result[key] as? [String: Any] {
            result[key] = deepMerged(existing, nested)
        } else {
            result[key] = value
        }
    }
    return result
}

func addAdjustmentLayer(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    var snapshot = try await store.snapshot(handle).draft
    let kind = try adjustmentKind(p)

    var object = try encodeAdjustment(materialised(kind))
    if let settings = p.object("settings") {
        object = deepMerged(object, settings)
        object["kind"] = kind.rawValue  // The kind argument wins over any stray value in settings.
    }
    let adjustment: LayerAdjustment
    do {
        let data = try JSONSerialization.data(withJSONObject: object)
        adjustment = try JSONDecoder().decode(LayerAdjustment.self, from: data)
    } catch {
        throw RPCError.invalidParams(
            "Those settings did not fit a \(kind.rawValue) adjustment. Call describe_adjustment to see the shape.")
    }
    guard adjustment.isValid else {
        throw RPCError.invalidParams("Those \(kind.rawValue) settings are out of range.")
    }

    let id = UUID()
    var record = ProjectLayerRecord(
        id: id, name: p.string("name", default: kind.rawValue)!, isVisible: true,
        transform: snapshot.canvasTransform, imageFile: nil)
    record.adjustment = adjustment

    var insertAt = snapshot.manifest.layers.count
    if let above = p.string("above", default: nil) {
        let base = try snapshot.layer(above)
        record.parentID = base.parentID
        insertAt = try snapshot.layerIndex(above) + 1
        if p.bool("clip_to_below", default: false)! {
            guard !base.isGroupLayer else { throw RPCError.invalidParams("An adjustment cannot clip to a folder.") }
            record.maskSourceID = base.id
        }
    } else if p.bool("clip_to_below", default: false)! {
        guard let below = snapshot.manifest.layers.last, !below.isGroupLayer else {
            throw RPCError.invalidParams("There is no layer below to clip to.")
        }
        record.maskSourceID = below.id
    }
    snapshot.manifest.layers.insert(record, at: insertAt)

    try await store.update(handle, to: snapshot.snapshot)
    let clipped = record.maskSourceID == nil ? "every visible layer below it" : "the layer directly below it"
    return ToolResult("""
        Added a \(kind.rawValue) adjustment layer, affecting \(clipped).
        Layer id: \(id.uuidString)
        """)
}

// MARK: - Canvas

func resizeCanvas(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let snapshot = try await store.snapshot(handle)
    let width = try p.int("width"), height = try p.int("height")
    let anchors = ["top-left", "top", "top-right", "left", "center", "right",
                   "bottom-left", "bottom", "bottom-right"]
    let name = p.string("anchor", default: "center")!
    guard let anchor = anchors.firstIndex(of: name) else {
        throw RPCError.invalidParams("`\(name)` is not an anchor. Use one of: \(anchors.joined(separator: ", ")).")
    }
    var options = CanvasSizeOptions(width: width, height: height)
    options.anchor = anchor
    let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
    try await store.update(handle, to: resized)
    return ToolResult("Canvas is now \(width)x\(height), anchored \(name). Layers kept their size.")
}

func resizeImage(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let snapshot = try await store.snapshot(handle)
    let old = snapshot.manifest
    let ratio = Double(old.height) / Double(old.width)

    var width = p.int("width", default: nil)
    var height = p.int("height", default: nil)
    if width == nil, height == nil, !p.has("resolution") {
        throw RPCError.invalidParams("Pass width, height or resolution.")
    }
    if width == nil { width = height.map { Int((Double($0) / ratio).rounded()) } ?? old.width }
    if height == nil { height = Int((Double(width!) * ratio).rounded()) }

    var options = ImageSizeOptions(width: width!, height: height!,
                                   resolution: p.double("resolution", default: old.resolution ?? 72)!)
    if let raw = p.string("sampling", default: nil) {
        guard let sampling = LayerSampling(rawValue: raw) else {
            throw RPCError.invalidParams("`\(raw)` is not a sampling mode.")
        }
        options.sampling = sampling
    }
    let resized = try await ImageResizer.shared.resize(snapshot, to: options)
    try await store.update(handle, to: resized)
    return ToolResult("""
        Document is now \(options.width)x\(options.height) at \(Int(options.resolution)) ppi \
        (was \(old.width)x\(old.height)).
        """)
}

// MARK: - Rendering

func renderPreview(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let document = try await store.get(handle)
    let raster = try await ImageExporter.shared.render(document.snapshot)
    let limit = min(2048, max(64, p.int("max_size", default: 1024)!))
    let preview = try downscale(raster.image, longestSide: limit)
    let data = try pngData(preview)
    return ToolResult("""
        \(document.name) rendered at \(raster.image.width)x\(raster.image.height); \
        preview shown at \(preview.width)x\(preview.height).
        """, imagePNG: data)
}

func exportImage(_ p: Params, _ store: DocumentStore) async throws -> ToolResult {
    let handle = try p.string("document")
    let snapshot = try await store.snapshot(handle)
    let url = try p.path("path")
    let extensionFormat = url.pathExtension.lowercased()
    let format = p.string("format", default: nil)?.lowercased()
        ?? (["jpg", "jpeg"].contains(extensionFormat) ? "jpeg" : "png")

    if format == "jpeg" {
        let raster = try await ImageExporter.shared.render(snapshot)
        var options = JPEGOptions()
        options.quality = p.double("quality", default: 0.9)!
        let result = try await ImageExporter.shared.jpeg(raster, options: options)
        try await ImageExporter.shared.write(result.data, to: url)
        return ToolResult("""
            Exported JPEG to \(url.path) — \(raster.image.width)x\(raster.image.height), \
            \(byteLabel(result.data.count)), quality \(options.quality.clean).
            """)
    }
    try await ImageExporter.shared.exportPNG(snapshot, to: url)
    let size = (try? Data(contentsOf: url).count) ?? 0
    return ToolResult("Exported PNG to \(url.path) — \(byteLabel(size)).")
}

// MARK: - Small helpers

func downscale(_ image: CGImage, longestSide: Int) throws -> CGImage {
    let longest = max(image.width, image.height)
    guard longest > longestSide else { return image }
    let scale = Double(longestSide) / Double(longest)
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw RPCError.internalError("Could not build the preview.")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw RPCError.internalError("Could not build the preview.") }
    return result
}

func pngData(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw RPCError.internalError("Could not encode the preview.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RPCError.internalError("Could not encode the preview.")
    }
    return data as Data
}

func prettyJSON(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(data: data, encoding: .utf8) ?? "{}"
}

func byteLabel(_ bytes: Int) -> String {
    bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
        : bytes >= 1024 ? String(format: "%.0f KB", Double(bytes) / 1024) : "\(bytes) bytes"
}

extension Double {
    /// Whole numbers read better without a trailing .0 in tool output.
    var clean: String { self == rounded() ? String(Int(self)) : String(format: "%.2f", self) }
}
extension CGFloat {
    var clean: String { Double(self).clean }
}

// MARK: - Record edits
//
// ProjectLayerRecord stores id, name, transform and imageFile as `let`, so
// changing them rebuilds the record.

extension ProjectLayerRecord {
    private func rebuilt(id newID: UUID? = nil, name newName: String? = nil,
                         transform newTransform: LayerTransform? = nil,
                         imageFile newImageFile: String?? = nil,
                         maskFile newMaskFile: String?? = nil) -> ProjectLayerRecord {
        ProjectLayerRecord(
            id: newID ?? id, name: newName ?? name, isVisible: isVisible,
            transform: newTransform ?? transform,
            imageFile: newImageFile ?? imageFile,
            parentID: parentID, isGroup: isGroup, opacity: opacity, blendMode: blendMode,
            maskFile: newMaskFile ?? maskFile, maskEnabled: maskEnabled, maskSourceID: maskSourceID,
            adjustment: adjustment, maskPlacement: maskPlacement, maskLinked: maskLinked, shape: shape)
    }

    func renamed(_ newName: String) -> ProjectLayerRecord { rebuilt(name: newName) }
    func withTransform(_ newTransform: LayerTransform) -> ProjectLayerRecord { rebuilt(transform: newTransform) }

    /// A copy under a new id, pointing at its own asset files.
    func copied(as newID: UUID, named newName: String) -> ProjectLayerRecord {
        rebuilt(id: newID, name: newName,
                imageFile: imageFile == nil ? .some(nil) : .some("\(newID.uuidString).png"),
                maskFile: maskFile == nil ? .some(nil) : .some("\(newID.uuidString).mask.png"))
    }
}
