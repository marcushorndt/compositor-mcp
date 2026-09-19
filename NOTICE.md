# Notice

This project builds on **Compositor** by Robbie Tilton (Wonder Assembly LLC).

- Upstream: https://github.com/robbietilton/Compositor
- License: MIT
- Pinned commit: `a19db9011282399785dc18efcfded904627bdcc2`

Compositor is the image editor. It holds the document model, the compositing
renderer and the `.comp` project format. This repository adds an MCP server on
top of it, so an agent can build and edit those projects.

No Compositor source is copied into this repository. The app is a git submodule
at `vendor/Compositor`, and the server compiles a subset of its files directly.
Everything under `Sources/compositor-mcp/Upstream/` is a symbolic link into that
submodule, created by `scripts/setup.sh`.

`patches/0001-xcode-26.1-type-checker.patch` splits two expressions that exceed
the Swift 6.2 type checker's limit. It changes no behaviour. The same fix is
offered upstream.
