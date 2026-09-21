#!/usr/bin/env bash
# Prepares the build: checks out Compositor, applies the build fixes it needs on
# Xcode 26.1, and links the sources this server compiles.
#
# Run it after cloning, and again after moving the submodule to a new commit.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

vendor="vendor/Compositor"
if [ ! -f "$vendor/Compositor.xcodeproj/project.pbxproj" ]; then
    echo "==> Fetching the Compositor submodule"
    git submodule update --init --recursive
fi

echo "==> Compositor is at $(git -C "$vendor" rev-parse --short HEAD)"

# Two expressions in Compositor exceed the Swift 6.2 type checker's limit. The
# patch splits them up; it changes no behaviour. Skip it when it is already in.
patch_file="patches/0001-xcode-26.1-type-checker.patch"
if git -C "$vendor" apply --reverse --check "$root/$patch_file" 2>/dev/null; then
    echo "==> Build fixes already applied"
else
    echo "==> Applying build fixes for Xcode 26.1"
    git -C "$vendor" apply "$root/$patch_file"
fi

# Compositor's own sources, linked rather than copied, so the submodule stays
# the single source of truth. Everything here is UI-free or model-only.
upstream="Sources/compositor-mcp/Upstream"
c_target="Sources/CompositorC"
echo "==> Linking Compositor sources"
rm -rf "$upstream" "$c_target/include"
mkdir -p "$upstream" "$c_target/include"
find "$c_target" -maxdepth 1 -name '*.c' -delete

# Files that need AppKit windows, Sparkle, or a live editor session.
exclude="CompositorApplicationDelegate.swift EditorCanvas.swift BrushCursorOverlay.swift \
SampleRingOverlay.swift TransformOverlay.swift ImageFileDrop.swift ProjectController.swift \
ProjectWorkspace.swift InlineTextEditor.swift"

linked=0
for dir in Document IO Rendering; do
    for file in "$vendor/Compositor/$dir"/*.swift; do
        name="$(basename "$file")"
        case " $exclude " in *" $name "*) continue ;; esac
        ln -s "../../../$file" "$upstream/$name"
        linked=$((linked + 1))
    done
done
for file in "$vendor/Compositor/Rendering"/*.c; do
    ln -s "../../$file" "$c_target/$(basename "$file")"
done
for file in "$vendor/Compositor/Rendering"/*.h; do
    ln -s "../../../$file" "$c_target/include/$(basename "$file")"
done

echo "==> Linked $linked Swift sources and $(ls "$c_target"/*.c | wc -l | tr -d ' ') C sources"
echo "==> Ready. Build with: swift build -c release"
