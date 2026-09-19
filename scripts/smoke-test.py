#!/usr/bin/env python3
"""Drives the server over MCP stdio and checks a real composition round-trips.

    swift build -c release && python3 scripts/smoke-test.py
"""
import base64, json, os, struct, subprocess, sys, tempfile, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, ".build", "release", "compositor-mcp")


def write_png(path, width, height, pixel):
    rows = b"".join(b"\x00" + b"".join(bytes(pixel(x, y, width, height)) for x in range(width))
                    for y in range(height))
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows))
                     + chunk(b"IEND", b""))


class Server:
    def __init__(self):
        self.process = subprocess.Popen(
            [BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 0

    def send(self, method, params=None, notify=False):
        message = {"jsonrpc": "2.0", "method": method}
        if not notify:
            self.next_id += 1
            message["id"] = self.next_id
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        return None if notify else json.loads(self.process.stdout.readline())

    def call(self, name, arguments=None):
        result = self.send("tools/call", {"name": name, "arguments": arguments or {}})["result"]
        text = "\n".join(c["text"] for c in result["content"] if c["type"] == "text")
        image = next((c for c in result["content"] if c["type"] == "image"), None)
        return text, result.get("isError", False), image


failures = []


def check(label, condition, detail=""):
    print(("  ok   " if condition else "  FAIL ") + label + (f"  {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(label)


def main():
    if not os.path.exists(BINARY):
        sys.exit("Build first: swift build -c release")

    work = tempfile.mkdtemp(prefix="compositor-mcp-")
    photo = os.path.join(work, "photo.png")
    badge = os.path.join(work, "badge.png")
    write_png(photo, 400, 300, lambda x, y, w, h: (30 + 200 * x // w, 60 + 150 * y // h, 180, 255))
    write_png(badge, 200, 200, lambda x, y, w, h: (250, 200, 40, 255)
              if (x - w / 2) ** 2 + (y - h / 2) ** 2 < (w * 0.4) ** 2 else (0, 0, 0, 0))

    server = Server()
    init = server.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "smoke-test", "version": "1"}})
    check("initialize", init["result"]["serverInfo"]["name"] == "compositor-mcp")
    server.send("notifications/initialized", notify=True)

    tools = server.send("tools/list")["result"]["tools"]
    check("tools/list", len(tools) == 20, f"got {len(tools)}")

    text, failed, _ = server.call("create_document", {"width": 900, "height": 600, "name": "Smoke"})
    check("create_document", not failed)
    document = text.split("handle: ")[1].strip()

    text, failed, _ = server.call("import_image", {"document": document, "path": photo,
                                                   "name": "Backdrop", "fit": True})
    check("import_image", not failed)
    backdrop = text.split("Layer id: ")[1].strip()

    text, failed, _ = server.call("import_image", {"document": document, "path": badge, "name": "Badge"})
    check("import_image (alpha)", not failed)
    mark = text.split("Layer id: ")[1].strip()

    _, failed, _ = server.call("transform_layer", {"document": document, "layer": mark,
                                                   "rotation": 12, "scale_percent": 140})
    check("transform_layer", not failed)

    _, failed, _ = server.call("set_layer", {"document": document, "layer": mark,
                                             "opacity": 0.8, "blend_mode": "Screen"})
    check("set_layer", not failed)

    text, failed, _ = server.call("duplicate_layer", {"document": document, "layer": mark})
    check("duplicate_layer", not failed)
    copy = text.split("Layer id: ")[1].strip()

    _, failed, _ = server.call("group_layers", {"document": document, "layers": [mark, copy],
                                                "name": "Marks"})
    check("group_layers", not failed)

    _, failed, _ = server.call("add_adjustment_layer", {
        "document": document, "kind": "Exposure",
        "settings": {"exposureSettings": {"exposure": 0.7}}})
    check("add_adjustment_layer", not failed)

    _, failed, _ = server.call("add_adjustment_layer", {
        "document": document, "kind": "Gradient Map", "above": backdrop, "clip_to_below": True})
    check("add_adjustment_layer (clipped)", not failed)

    _, failed, _ = server.call("resize_canvas", {"document": document, "width": 1000,
                                                 "height": 700, "anchor": "center"})
    check("resize_canvas", not failed)

    text, failed, image = server.call("render_preview", {"document": document, "max_size": 400})
    check("render_preview", not failed and image is not None)
    if image:
        check("preview is a PNG", base64.b64decode(image["data"])[:8] == b"\x89PNG\r\n\x1a\n")

    export = os.path.join(work, "out.png")
    _, failed, _ = server.call("export_image", {"document": document, "path": export})
    check("export_image", not failed and os.path.getsize(export) > 0)

    project = os.path.join(work, "smoke.comp")
    _, failed, _ = server.call("save_document", {"document": document, "path": project})
    check("save_document", not failed and os.path.isdir(project))

    text, failed, _ = server.call("open_document", {"path": project})
    check("open_document", not failed)
    reopened = text.split("handle: ")[1].strip()
    described, failed, _ = server.call("describe_document", {"document": reopened})
    check("round-trip keeps layers", "Marks" in described and "Backdrop" in described)
    check("round-trip keeps blend mode", "Screen" in described)

    _, failed, _ = server.call("set_layer", {"document": document, "layer": "nope", "name": "x"})
    check("bad layer id is reported", failed)
    _, failed, _ = server.call("create_document", {"width": 0, "height": 10})
    check("bad canvas is reported", failed)

    server.process.stdin.close()
    server.process.wait(timeout=10)

    print()
    if failures:
        sys.exit(f"{len(failures)} check(s) failed: {', '.join(failures)}")
    print("All checks passed.")


if __name__ == "__main__":
    main()
