#!/usr/bin/env python3
"""Génère Assets.xcassets avec les Brand Assets tvOS (App Icon + Top Shelf).

Crée des PNG unis (sans dépendance externe : PNG fabriqué via zlib) et toute
l'arborescence Contents.json attendue par Xcode pour une cible tvOS.
"""
import os
import json
import struct
import zlib

ROOT = os.path.join(os.path.dirname(__file__), "..", "Sources", "Assets.xcassets")
BRAND = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")

# Palette « Stremio » : violet profond -> violet clair pour un léger parallaxe.
BACK = (43, 18, 59, 255)     # #2b123b
FRONT = (124, 58, 173, 255)  # #7c3aad


def write_png(path, w, h, rgba):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # RGBA 8 bits
    row = b"\x00" + bytes(rgba) * w
    raw = row * h
    idat = zlib.compress(raw, 9)
    with open(path, "wb") as f:
        f.write(sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def imageset(dir_path, filename, w, h, rgba):
    os.makedirs(dir_path, exist_ok=True)
    write_png(os.path.join(dir_path, filename), w, h, rgba)
    write_json(os.path.join(dir_path, "Contents.json"), {
        "images": [{"idiom": "tv", "filename": filename, "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
    })


def imagestack(stack_path, w, h):
    """Crée un imagestack à 2 couches (Back + Front)."""
    os.makedirs(stack_path, exist_ok=True)
    layers = [("Front", FRONT), ("Back", BACK)]
    for name, color in layers:
        layer_dir = os.path.join(stack_path, f"{name}.imagestacklayer")
        os.makedirs(layer_dir, exist_ok=True)
        write_json(os.path.join(layer_dir, "Contents.json"),
                   {"info": {"author": "xcode", "version": 1}})
        content = os.path.join(layer_dir, "Content.imageset")
        imageset(content, f"{name.lower()}.png", w, h, color)
    write_json(os.path.join(stack_path, "Contents.json"), {
        "info": {"author": "xcode", "version": 1},
        "layers": [{"filename": f"{name}.imagestacklayer"} for name, _ in layers],
    })


def main():
    os.makedirs(BRAND, exist_ok=True)

    # Racine du catalogue
    write_json(os.path.join(ROOT, "Contents.json"),
               {"info": {"author": "xcode", "version": 1}})

    # App icons (home screen 400x240, App Store 1280x768) — imagestacks
    imagestack(os.path.join(BRAND, "App Icon.imagestack"), 400, 240)
    imagestack(os.path.join(BRAND, "App Icon - App Store.imagestack"), 1280, 768)

    # Top shelf (plats, non layered)
    imageset(os.path.join(BRAND, "Top Shelf Image.imageset"),
             "top_shelf.png", 1920, 720, BACK)
    imageset(os.path.join(BRAND, "Top Shelf Image Wide.imageset"),
             "top_shelf_wide.png", 2320, 720, BACK)

    # Manifeste du brand asset
    write_json(os.path.join(BRAND, "Contents.json"), {
        "assets": [
            {"filename": "App Icon.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "400x240"},
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv",
             "role": "top-shelf-image", "size": "1920x720"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv",
             "role": "top-shelf-image-wide", "size": "2320x720"},
        ],
        "info": {"author": "xcode", "version": 1},
    })
    print("Assets.xcassets généré :", os.path.normpath(ROOT))


if __name__ == "__main__":
    main()
