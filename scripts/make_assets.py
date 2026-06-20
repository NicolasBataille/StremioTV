#!/usr/bin/env python3
"""Génère Assets.xcassets avec les Brand Assets tvOS (App Icon + Top Shelf).

Dessine une vraie icône (dégradé violet + triangle « play » blanc), sans
dépendance externe : PNG fabriqué via zlib. Arborescence Contents.json complète.
"""
import os
import json
import struct
import zlib

ROOT = os.path.join(os.path.dirname(__file__), "..", "Sources", "Assets.xcassets")
BRAND = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")

# Palette « Stremio » : violet clair -> violet profond (dégradé vertical).
TOP = (138, 92, 246)     # #8a5cf6
BOTTOM = (43, 18, 59)     # #2b123b


def write_png(path, w, h, row_func):
    """row_func(y) -> bytes de longueur w*4 (RGBA)."""
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # RGBA 8 bits
    raw = bytearray()
    for y in range(h):
        raw.append(0)            # filtre "none"
        raw += row_func(y)
    idat = zlib.compress(bytes(raw), 6)
    with open(path, "wb") as f:
        f.write(sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


def gradient_row(y, w, h):
    t = y / max(1, h - 1)
    r = round(TOP[0] * (1 - t) + BOTTOM[0] * t)
    g = round(TOP[1] * (1 - t) + BOTTOM[1] * t)
    b = round(TOP[2] * (1 - t) + BOTTOM[2] * t)
    return bytes((r, g, b, 255)) * w


def play_span(y, w, h):
    """Retourne (x_start, x_end) du triangle « play » sur la ligne y, ou None."""
    cx, cy = w / 2.0, h / 2.0
    half = min(w, h) * 0.26          # demi-hauteur du triangle
    depth = min(w, h) * 0.42          # largeur (pointe à droite)
    x0 = cx - depth * 0.45
    dy = abs(y - cy)
    if dy > half:
        return None
    x_end = x0 + depth * (1 - dy / half)
    return int(round(x0)), int(round(x_end))


def triangle_row(y, w, h, opaque_bg):
    span = play_span(y, w, h)
    base = gradient_row(y, w, h) if opaque_bg else (b"\x00\x00\x00\x00" * w)
    if span is None:
        return base
    row = bytearray(base)
    x_start, x_end = span
    for x in range(max(0, x_start), min(w, x_end)):
        row[x * 4:x * 4 + 4] = b"\xff\xff\xff\xff"   # blanc
    return bytes(row)


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def imageset(dir_path, filename, w, h, opaque_bg):
    os.makedirs(dir_path, exist_ok=True)
    write_png(os.path.join(dir_path, filename), w, h, lambda y: triangle_row(y, w, h, opaque_bg))
    write_json(os.path.join(dir_path, "Contents.json"), {
        "images": [{"idiom": "tv", "filename": filename, "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
    })


def imagestack(stack_path, w, h):
    """imagestack à 2 couches : fond dégradé (Back) + triangle blanc (Front)."""
    os.makedirs(stack_path, exist_ok=True)
    # Back = dégradé plein
    back = os.path.join(stack_path, "Back.imagestacklayer")
    os.makedirs(back, exist_ok=True)
    write_json(os.path.join(back, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    back_set = os.path.join(back, "Content.imageset")
    os.makedirs(back_set, exist_ok=True)
    write_png(os.path.join(back_set, "back.png"), w, h, lambda y: gradient_row(y, w, h))
    write_json(os.path.join(back_set, "Contents.json"), {
        "images": [{"idiom": "tv", "filename": "back.png", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
    })
    # Front = triangle blanc sur transparent
    front = os.path.join(stack_path, "Front.imagestacklayer")
    os.makedirs(front, exist_ok=True)
    write_json(os.path.join(front, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    front_set = os.path.join(front, "Content.imageset")
    os.makedirs(front_set, exist_ok=True)
    write_png(os.path.join(front_set, "front.png"), w, h, lambda y: triangle_row(y, w, h, False))
    write_json(os.path.join(front_set, "Contents.json"), {
        "images": [{"idiom": "tv", "filename": "front.png", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
    })
    write_json(os.path.join(stack_path, "Contents.json"), {
        "info": {"author": "xcode", "version": 1},
        "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}],
    })


def main():
    os.makedirs(BRAND, exist_ok=True)
    write_json(os.path.join(ROOT, "Contents.json"), {"info": {"author": "xcode", "version": 1}})

    imagestack(os.path.join(BRAND, "App Icon.imagestack"), 400, 240)
    imagestack(os.path.join(BRAND, "App Icon - App Store.imagestack"), 1280, 768)
    imageset(os.path.join(BRAND, "Top Shelf Image.imageset"), "top_shelf.png", 1920, 720, True)
    imageset(os.path.join(BRAND, "Top Shelf Image Wide.imageset"), "top_shelf_wide.png", 2320, 720, True)

    write_json(os.path.join(BRAND, "Contents.json"), {
        "assets": [
            {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        ],
        "info": {"author": "xcode", "version": 1},
    })
    print("Assets.xcassets généré :", os.path.normpath(ROOT))


if __name__ == "__main__":
    main()
