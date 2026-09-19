import Foundation

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
]
