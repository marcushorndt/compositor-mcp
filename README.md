# compositor-mcp

An [MCP](https://modelcontextprotocol.io) server that lets an agent build and edit
[Compositor](https://github.com/robbietilton/Compositor) image projects.

Compositor is a free, open-source image editor for macOS by
[Robbie Tilton](https://github.com/robbietilton). This server drives its document
model headlessly: it opens and writes real `.comp` projects, composites them with
Compositor's own renderer, and exports PNG and JPEG. What the agent builds, the app
opens.

The app does not need to be running. The server never automates the UI.

## What it does

Claude can lay out a composition, adjust it, look at the result, and save a project
you then open and finish by hand.

```
You:    Build me a 1200x800 poster from photo.png, put badge.png on top
        at 130%, rotate it slightly, and warm the whole thing up.

Claude: [create_document] [import_image] [transform_layer]
        [add_adjustment_layer Gradient Map] [render_preview]
        -> shows you the rendered image
        [save_document ~/Desktop/poster.comp]
```

`render_preview` returns the composite as an image, so the agent sees its own work
and can correct it before saving.

## Coverage

It works on the document: structure, placement, non-destructive adjustments and
output. It does not paint pixels.

**Covered**

| Area | Tools |
| --- | --- |
| Documents | `create_document`, `open_document`, `save_document`, `close_document`, `list_documents`, `describe_document` |
| Layers | `import_image`, `set_layer`, `delete_layer`, `duplicate_layer`, `reorder_layer`, `group_layers` |
| Transform | `transform_layer` (move, scale, rotate, flip, sampling) |
| Compositing | opacity and all 13 blend modes, folders, `set_clipping_mask` |
| Adjustments | `add_adjustment_layer`, `describe_adjustment` (Levels, Curves, Hue/Saturation, Exposure, Gradient Map, Grain) |
| Canvas | `resize_canvas`, `resize_image` |
| Output | `render_preview`, `export_image` |

**Not covered.** Compositor's interactive tools need a live editing session:
brush, eraser, clone stamp, spot healing, smear and liquify, the gradient and
shape tools, marquee, lasso and magic wand selections, crop, content-aware fill,
painting layer masks, merging layers, and the destructive filters (Gaussian Blur,
Motion Blur, Add Noise, Lens Correction, Remove Background).

Those live on Compositor's `EditorSession`, which is bound to UI state. Their pixel
engines are UI-free C, so a headless driver is possible. See
[ROADMAP](#roadmap).

## Requirements

- macOS 26 or newer
- Xcode 26 or newer (for the Swift 6.2 toolchain)

## Install

```bash
git clone --recursive https://github.com/marcushorndt/compositor-mcp.git
cd compositor-mcp
./scripts/setup.sh
swift build -c release
```

`setup.sh` checks out the pinned Compositor commit, applies the two build fixes it
needs on Xcode 26.1, and links the sources this server compiles.

The binary lands at `.build/release/compositor-mcp`.

## Use it with Claude Code

```bash
claude mcp add compositor -- /absolute/path/to/compositor-mcp/.build/release/compositor-mcp
```

Or add it to `.mcp.json` by hand:

```json
{
  "mcpServers": {
    "compositor": {
      "command": "/absolute/path/to/compositor-mcp/.build/release/compositor-mcp"
    }
  }
}
```

The server speaks MCP over stdio, so any MCP client can run it.

## How it works

Compositor already separates its document from its interface. `ProjectSnapshot` is
an immutable value holding the manifest and the decoded images, and
`ImageExporter.render` turns one into a finished composite: folders, folder masks,
clipping masks, adjustment layers, blend modes and opacity. None of that needs a
window.

So this server compiles 54 of Compositor's own source files and drives them
directly:

```
MCP client  ->  compositor-mcp  ->  ProjectSnapshot  ->  ImageExporter.render
                                          |
                                    ProjectStore  ->  .comp on disk
```

A tool call loads the document once, edits it in memory as a mutable draft, and
validates the layer tree before accepting the change. Nothing is written until you
call `save_document` or `export_image`.

Because the rendering, the validation and the file format are Compositor's own, a
project this server writes is the same thing the app writes.

## Relationship to Compositor

Compositor is a git submodule, pinned to a commit. No upstream source is copied
here. Everything in `Sources/compositor-mcp/Upstream/` is a symbolic link into the
submodule. See [NOTICE.md](NOTICE.md).

To move to a newer Compositor:

```bash
git -C vendor/Compositor fetch origin && git -C vendor/Compositor checkout <commit>
./scripts/setup.sh && swift build -c release
```

## Roadmap

- Destructive filters (blur, noise, lens correction) over the existing C engines
- Painting and importing layer masks
- Merge and flatten
- Text layers, which Compositor does not have yet

## License

This project is MIT, Copyright (c) 2026 Marcus Horndt. See [LICENSE](LICENSE).

Compositor is MIT, Copyright (c) 2026 Wonder Assembly LLC. Its notice is kept
verbatim at [`licenses/Compositor-LICENSE.txt`](licenses/Compositor-LICENSE.txt).
No Compositor source is copied into this repository, and a binary you build from
it should ship both notices. [NOTICE.md](NOTICE.md) explains the attribution and
why the terms permit this.

Not affiliated with or endorsed by Robbie Tilton or Wonder Assembly LLC.
