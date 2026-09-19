import Foundation
import ContentMaschineKit

// MARK: - Tool catalogue
//
// One entry per tool, with the JSON Schema Claude reads to call it.

func str(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
func num(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
func int(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
func flag(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
func choice(_ description: String, _ values: [String]) -> [String: Any] {
    ["type": "string", "description": description, "enum": values]
}
func list(_ description: String, of type: String) -> [String: Any] {
    ["type": "array", "description": description, "items": ["type": type]]
}

private func tool(_ name: String, _ description: String,
                  _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
    [
        "name": name,
        "description": description,
        "inputSchema": [
            "type": "object",
            "properties": properties,
            "required": required,
        ] as [String: Any],
    ]
}

let blendModes = LayerBlendMode.allCases.map { $0.rawValue }
let adjustmentKinds = AdjustmentKind.allCases.map { $0.rawValue }

private let doc = str("Handle of an open document, from create_document or open_document.")
private let layer = str("Layer id, from describe_document.")

let toolCatalogue: [[String: Any]] = [
    tool("create_document",
         "Creates an empty Compositor document and opens it. Returns a document handle for the other tools.",
         ["width": int("Canvas width in pixels (1-30000)."),
          "height": int("Canvas height in pixels (1-30000)."),
          "resolution": num("Pixels per inch. Defaults to 72."),
          "name": str("Name used until the document is saved.")],
         required: ["width", "height"]),

    tool("open_document",
         "Opens an existing .comp project file and returns a document handle.",
         ["path": str("Path to a .comp project.")],
         required: ["path"]),

    tool("save_document",
         "Writes an open document to disk as a .comp project.",
         ["document": doc,
          "path": str("Where to save. Required the first time; afterwards defaults to the previous path.")],
         required: ["document"]),

    tool("close_document",
         "Closes an open document and frees its images. Unsaved changes are discarded.",
         ["document": doc], required: ["document"]),

    tool("list_documents",
         "Lists every open document, with its canvas size and whether it has unsaved changes."),

    tool("describe_document",
         "Describes a document: canvas size and the full layer tree, bottom to top, with every layer's id, "
         + "kind, position, size, opacity, blend mode and mask. Read this before editing layers.",
         ["document": doc], required: ["document"]),

    tool("import_image",
         "Imports a JPEG, PNG, HEIC or TIFF file as a new layer on top of the stack.",
         ["document": doc,
          "path": str("Path to the image file."),
          "name": str("Layer name. Defaults to the file name."),
          "x": num("Left edge in canvas pixels. Defaults to centring the image."),
          "y": num("Top edge in canvas pixels. Defaults to centring the image."),
          "scale_percent": num("Size as a percentage of the image's own pixels. Defaults to 100."),
          "fit": flag("Scale the image down to fit the canvas. Overrides scale_percent."),
          "opacity": num("Layer opacity, 0 to 1. Defaults to 1."),
          "blend_mode": choice("Blend mode. Defaults to Normal.", blendModes)],
         required: ["document", "path"]),

    tool("set_layer",
         "Changes a layer's name, visibility, opacity or blend mode. Omitted fields are left alone.",
         ["document": doc, "layer": layer,
          "name": str("New layer name."),
          "visible": flag("Whether the layer is drawn."),
          "opacity": num("Layer opacity, 0 to 1."),
          "blend_mode": choice("Blend mode.", blendModes)],
         required: ["document", "layer"]),

    tool("transform_layer",
         "Moves, resizes, rotates or flips a layer. Compositor keeps the layer's full resolution, so scaling "
         + "down and back up loses nothing. Omitted fields are left alone.",
         ["document": doc, "layer": layer,
          "x": num("Left edge in canvas pixels."),
          "y": num("Top edge in canvas pixels."),
          "width": num("Drawn width in canvas pixels."),
          "height": num("Drawn height in canvas pixels."),
          "scale_percent": num("Size as a percentage of the layer's own pixels, keeping its centre."),
          "rotation": num("Clockwise rotation in degrees."),
          "flip_horizontal": flag("Mirror the layer left to right."),
          "flip_vertical": flag("Mirror the layer top to bottom."),
          "sampling": choice("Scaling quality.", LayerSampling.allCases.map { $0.rawValue })],
         required: ["document", "layer"]),

    tool("reorder_layer",
         "Moves a layer to a new position in the stack. A folder carries its contents with it.",
         ["document": doc, "layer": layer,
          "to_index": int("New position, 0 = bottom of the stack."),
          "parent": str("Id of the folder to move the layer into. Omit to place it at the top level.")],
         required: ["document", "layer", "to_index"]),

    tool("delete_layer",
         "Deletes a layer. Deleting a folder also deletes everything inside it.",
         ["document": doc, "layer": layer], required: ["document", "layer"]),

    tool("duplicate_layer",
         "Copies a layer, with its pixels, mask and settings, and places the copy above the original.",
         ["document": doc, "layer": layer,
          "name": str("Name for the copy. Defaults to the original name plus ' copy'.")],
         required: ["document", "layer"]),

    tool("group_layers",
         "Puts layers into a new folder. Folders are pass-through: a folder mask or opacity applies to "
         + "everything inside.",
         ["document": doc,
          "layers": list("Layer ids to group, bottom to top.", of: "string"),
          "name": str("Folder name. Defaults to 'Group'.")],
         required: ["document", "layers"]),

    tool("add_adjustment_layer",
         "Adds an adjustment layer above a layer. It changes every visible layer below it, without touching "
         + "their pixels. Pass settings to control it; call describe_adjustment first to see the fields.",
         ["document": doc,
          "kind": choice("Which adjustment to add.", adjustmentKinds),
          "settings": ["type": "object",
                       "description": "Adjustment settings. See describe_adjustment for the shape and defaults."],
          "above": str("Id of the layer to sit above. Defaults to the top of the stack."),
          "clip_to_below": flag("Limit the adjustment to the layer directly below it (a clipping mask)."),
          "name": str("Layer name. Defaults to the adjustment's name.")],
         required: ["document", "kind"]),

    tool("describe_adjustment",
         "Returns the settings an adjustment accepts, as JSON, filled with its defaults. Use it to build the "
         + "`settings` argument for add_adjustment_layer.",
         ["kind": choice("Which adjustment to describe.", adjustmentKinds)],
         required: ["kind"]),

    tool("set_clipping_mask",
         "Clips a layer to the one below it, so it only shows where that layer has pixels, or releases the clip.",
         ["document": doc, "layer": layer,
          "enabled": flag("True to clip to the layer below, false to release.")],
         required: ["document", "layer", "enabled"]),

    tool("resize_canvas",
         "Changes the canvas size without scaling the layers, like Photoshop's Canvas Size.",
         ["document": doc,
          "width": int("New canvas width in pixels."),
          "height": int("New canvas height in pixels."),
          "anchor": choice("Where the existing image sits on the new canvas. Defaults to center.",
                           ["top-left", "top", "top-right", "left", "center", "right",
                            "bottom-left", "bottom", "bottom-right"])],
         required: ["document", "width", "height"]),

    tool("resize_image",
         "Scales the whole document, layers and all, like Photoshop's Image Size.",
         ["document": doc,
          "width": int("New width in pixels. Height follows the aspect ratio if omitted."),
          "height": int("New height in pixels. Width follows the aspect ratio if omitted."),
          "resolution": num("New resolution in pixels per inch (1-9600)."),
          "sampling": choice("Scaling quality.", LayerSampling.allCases.map { $0.rawValue })],
         required: ["document"]),

    tool("render_preview",
         "Renders the document through Compositor's own compositor and returns the result as an image, so you "
         + "can see what you built. Use it to check your work after editing.",
         ["document": doc,
          "max_size": int("Longest side of the preview in pixels. Defaults to 1024, maximum 2048.")],
         required: ["document"]),

    tool("export_image",
         "Renders the document and writes it to a PNG or JPEG file.",
         ["document": doc,
          "path": str("Where to write the file."),
          "format": choice("Output format. Defaults to the path's extension, else PNG.", ["png", "jpeg"]),
          "quality": num("JPEG quality, 0 to 1. Defaults to 0.9.")],
         required: ["document", "path"]),
] + contentMaschineTools

// MARK: - ContentMaschine
//
// Generated images arrive as ordinary layers, so every other tool applies to
// them afterwards.

private let imageModels = ImageModel.allCases.map { $0.rawValue }
private let aspectRatios = ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"]

/// Arguments every generating tool shares.
private var generationOptions: [String: Any] {
    ["model": choice("Which model to use. Defaults to pro, which is the most reliable at "
                     + "reproducing existing text and typography.", imageModels),
     "aspect_ratio": choice("Shape of the generated image. Defaults to 1:1.", aspectRatios),
     "resolution": ["type": "integer", "description":
                    "Long edge in pixels: 1024 or 2048. Defaults to 2048. 4096 is not offered, "
                    + "because the model tiles the background and corrupts type at that size.",
                    "enum": [1024, 2048]],
     "name": str("Layer name."),
     "x": num("Left edge in canvas pixels. Defaults to centring."),
     "y": num("Top edge in canvas pixels. Defaults to centring."),
     "scale_percent": num("Size as a percentage of the generated image's own pixels."),
     "fit": flag("Scale the image to fit the canvas.")]
}

private func generating(_ name: String, _ description: String,
                        _ extra: [String: Any], required: [String]) -> [String: Any] {
    var properties = generationOptions
    for (key, value) in extra { properties[key] = value }
    return ["name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties,
                            "required": required] as [String: Any]]
}

let contentMaschineTools: [[String: Any]] = [
    generating("generate_layer",
        "Generates an image from a text prompt with ContentMaschine and adds it to the document as a "
        + "layer. Costs about one credit. Follow it with render_preview to see the composition.",
        ["document": str("Handle of an open document."),
         "prompt": str("What to generate. Be specific about subject, style and lighting.")],
        required: ["document", "prompt"]),

    generating("vary_layer",
        "Sends a layer's pixels back to ContentMaschine for a variation and adds the result as a new "
        + "layer. The original layer is left alone. Costs about one credit.",
        ["document": str("Handle of an open document."),
         "layer": str("Layer to vary. It must have pixels, so not a folder or adjustment layer."),
         "prompt": str("How the variation should differ.")],
        required: ["document", "layer", "prompt"]),

    generating("fuse_layers",
        "Fuses two or more layers into one new image, for mockups and composites. Fusion re-renders "
        + "rather than pastes, so the result reproduces the sources rather than copying their pixels. "
        + "Say which image supplies the artwork and which supplies only the camera angle and lighting. "
        + "Costs about one credit.",
        ["document": str("Handle of an open document."),
         "layers": list("Layer ids to fuse, at least two, in the order the prompt refers to them.",
                        of: "string"),
         "prompt": str("How to combine them. Name image 1 and image 2 explicitly.")],
        required: ["document", "layers", "prompt"]),

    generating("restyle_composition",
        "Renders the whole document, sends that composite to ContentMaschine, and adds the restyled "
        + "result as a new layer on top. The existing layers stay below it, untouched. Use it to "
        + "restyle a finished composition. Costs about one credit.",
        ["document": str("Handle of an open document."),
         "prompt": str("The style to apply to the whole composition.")],
        required: ["document", "prompt"]),

    ["name": "remove_layer_background",
     "description": "Cuts a layer out to transparency with ContentMaschine's segmenter. Costs about "
        + "0.2 credits. It keys white from white correctly, which no colour key can do. The service "
        + "normalises to about one megapixel in 64-pixel steps: a square layer maps back exactly, so "
        + "only its alpha is carried onto the original pixels and no resolution is lost, while a shape "
        + "it cannot hit is returned slightly cropped and the cutout's own pixels are used instead, "
        + "with the layer reshaped around its centre. Send a square layer to keep full resolution.",
     "inputSchema": ["type": "object", "properties": [
        "document": str("Handle of an open document."),
        "layer": str("Layer to cut out."),
        "subject_hint": str("What the subject is, when the image is ambiguous."),
        "as_new_layer": flag("Add the cutout as a new layer instead of replacing the layer's pixels."),
        "name": str("Name for the new layer, when as_new_layer is set."),
     ], "required": ["document", "layer"]] as [String: Any]],

    ["name": "upscale_layer",
     "description": "Upscales a layer's pixels with ContentMaschine. The layer keeps its place and "
        + "size on the canvas and simply holds more detail. Takes a few minutes at higher scales.",
     "inputSchema": ["type": "object", "properties": [
        "document": str("Handle of an open document."),
        "layer": str("Layer to upscale."),
        "scale": ["type": "integer", "description": "How much to enlarge. Defaults to 2.",
                  "enum": [2, 4, 6, 8]],
     ], "required": ["document", "layer"]] as [String: Any]],

    ["name": "list_generations",
     "description": "Lists past ContentMaschine generations, newest first, with the prompt that made "
        + "each one and its stored file id. Costs nothing. Check here before generating something "
        + "again, because importing a stored file is free and returns the original bytes.",
     "inputSchema": ["type": "object", "properties": [
        "limit": int("How many to list. Defaults to 25."),
     ], "required": []] as [String: Any]],

    ["name": "import_generation",
     "description": "Imports a stored ContentMaschine generation into the document as a layer, by its "
        + "file id from list_generations. Costs no credits and returns the original file rather than "
        + "a fresh render.",
     "inputSchema": ["type": "object", "properties": [
        "document": str("Handle of an open document."),
        "file": str("The generation's file id, from list_generations."),
        "name": str("Layer name."),
        "x": num("Left edge in canvas pixels."),
        "y": num("Top edge in canvas pixels."),
        "scale_percent": num("Size as a percentage of the image's own pixels."),
        "fit": flag("Scale the image to fit the canvas."),
     ], "required": ["document", "file"]] as [String: Any]],
]
