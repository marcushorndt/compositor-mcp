# Notice and attribution

This project builds on **Compositor**, a free and open-source image editor for
macOS by Robbie Tilton (Wonder Assembly LLC).

- Upstream: https://github.com/robbietilton/Compositor
- Upstream license: MIT, Copyright (c) 2026 Wonder Assembly LLC
- Full upstream license text: [`licenses/Compositor-LICENSE.txt`](licenses/Compositor-LICENSE.txt)
- Pinned commit: `a19db9011282399785dc18efcfded904627bdcc2`

Compositor holds the document model, the compositing renderer and the `.comp`
project format. This repository adds an MCP server on top of them.

## What this repository distributes

No Compositor source code is copied into this repository. The app is a git
submodule at `vendor/Compositor`, and every file under
`Sources/compositor-mcp/Upstream/` is a symbolic link into that submodule,
created by `scripts/setup.sh`. Cloning this repository without its submodule
gets you none of Compositor's code.

The original work in this repository is `Sources/compositor-mcp/Server/`,
`Package.swift`, `Bridging/`, `scripts/` and the documentation. It is MIT
licensed, Copyright (c) 2026 Marcus Horndt. See [`LICENSE`](LICENSE).

## Why this is permitted

Compositor's MIT license grants permission "to deal in the Software without
restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies". Its single
condition is that "the above copyright notice and this permission notice shall
be included in all copies or substantial portions of the Software". The license
carries no copyleft, no contributor agreement and no patent or trademark terms.

This project meets that condition by shipping the upstream notice verbatim at
`licenses/Compositor-LICENSE.txt` and naming the author and upstream here.

MIT is also compatible with the MIT license this project uses, so the combined
work carries no conflicting obligations.

## If you redistribute a build

A binary built from this repository **does** contain substantial portions of
Compositor, because the server compiles 54 of its source files. If you
distribute that binary, include both notices with it:

- `LICENSE` (this project)
- `licenses/Compositor-LICENSE.txt` (Compositor)

## Modifications to Compositor

`patches/0001-xcode-26.1-type-checker.patch` splits two expressions that exceed
the Swift 6.2 type checker's limit. It changes no behaviour, and it is applied
to the submodule at build time rather than committed as modified source. The
same fix is offered upstream.

## No affiliation

This project is not affiliated with, sponsored by, or endorsed by Robbie Tilton
or Wonder Assembly LLC. "Compositor" is used only to say which software this
server works with.
