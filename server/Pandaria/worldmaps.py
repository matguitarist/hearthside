"""The dashboard's world maps for Pandaria: each continent's map from the 5.4.8 client's MPQs
(read with StormLib, decoded with Pillow) as a PNG, and `maps.json` with where each sits in the
world, from the extracted `WorldMapArea.dbc`. Run by the `worldmaps` service (`compose.yaml`):
the client's Data at /client, the server's data at /data, the output to /out. No map art ships
with the app or the repository.

Each map is twelve 256² tiles, four across and three down, of which the game's frame shows the
top left 1002×668, as in 1.12 (`crates/warcraft-survivors/src/world_maps.rs`)."""

import ctypes
import io
import json
import os
import struct
import sys

from PIL import Image

# The continents a player reaches, by the WorldMapArea name of the continent's map.
CONTINENTS = [("Azeroth", 0, "Eastern Kingdoms"), ("Kalimdor", 1, "Kalimdor"),
              ("Expansion01", 530, "Outland"), ("Northrend", 571, "Northrend"), ("Pandaria", 870, "Pandaria")]

storm = ctypes.CDLL("libstorm.so.9")
storm.SFileOpenArchive.argtypes = [ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p)]
storm.SFileHasFile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
storm.SFileOpenFileEx.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p)]
storm.SFileGetFileSize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
storm.SFileGetFileSize.restype = ctypes.c_uint
storm.SFileReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_uint), ctypes.c_void_p]
storm.SFileCloseFile.argtypes = [ctypes.c_void_p]


def archives(data):
    """Every archive, the newest first: the updates (whole files there win; patches against an
    older file, `PTCH`, are passed over in `read`), then the locale's (the maps carry printed
    names, so their tiles are there), the expansions and the base."""
    found = []
    for root in [data] + [os.path.join(data, d) for d in sorted(os.listdir(data)) if os.path.isdir(os.path.join(data, d))]:
        found += [os.path.join(root, n) for n in os.listdir(root) if n.lower().endswith(".mpq")]

    def rank(path):
        name, locale = os.path.basename(path).lower(), os.path.dirname(path) != data
        build = int("".join(c for c in name if c.isdigit()) or 0) if name.startswith("wow-update") else 0
        return (not name.startswith("wow-update"), -build, not locale, not name.startswith("expansion"), name)

    opened = []
    for path in sorted(found, key=rank):
        handle = ctypes.c_void_p()
        # STREAM_FLAG_READ_ONLY
        if storm.SFileOpenArchive(path.encode(), 0, 0x100, ctypes.byref(handle)):
            opened.append((os.path.basename(path), handle))
    return opened


def read(opened, path):
    for name, archive in opened:
        if not storm.SFileHasFile(archive, path.encode()):
            continue
        handle = ctypes.c_void_p()
        if not storm.SFileOpenFileEx(archive, path.encode(), 0, ctypes.byref(handle)):
            continue
        size = storm.SFileGetFileSize(handle, None)
        buf = ctypes.create_string_buffer(size)
        got = ctypes.c_uint()
        storm.SFileReadFile(handle, buf, size, ctypes.byref(got), None)
        storm.SFileCloseFile(handle)
        data = buf.raw[:got.value]
        if data[:4] != b"PTCH":
            return data
    raise FileNotFoundError(path)


def bounds(dbc):
    """WorldMapArea rows with no area, the continents: name → (map, left, right, top, bottom)."""
    raw = open(dbc, "rb").read()
    magic, records, fields, size, strings = struct.unpack_from("<4s4I", raw)
    assert magic == b"WDBC", magic
    table = raw[20 + records * size:]
    out = {}
    for i in range(records):
        row = 20 + i * size
        _, map_id, area, name_at = struct.unpack_from("<4I", raw, row)
        left, right, top, bottom = struct.unpack_from("<4f", raw, row + 16)
        name = table[name_at:table.index(b"\0", name_at)].decode()
        if area == 0:
            out[name] = (map_id, left, right, top, bottom)
    return out


def main():
    client, data, out = "/client", "/data", "/out"
    opened = archives(client)
    if not opened:
        sys.exit(f"no MPQ archives in {client}")
    areas = bounds(os.path.join(data, "dbc", "WorldMapArea.dbc"))
    maps = []
    for name, map_id, title in CONTINENTS:
        if name not in areas:
            print(f"{name}: not in WorldMapArea.dbc", file=sys.stderr)
            continue
        picture = Image.new("RGB", (1024, 768))
        try:
            for i in range(12):
                tile = Image.open(io.BytesIO(read(opened, f"Interface\\WorldMap\\{name}\\{name}{i + 1}.blp"))).convert("RGB")
                picture.paste(tile.resize((256, 256)), (i % 4 * 256, i // 4 * 256))
        except FileNotFoundError as e:
            print(f"{name}: {e} missing", file=sys.stderr)
            continue
        file = f"{name.lower()}.png"
        picture.crop((0, 0, 1002, 668)).save(os.path.join(out, file), optimize=True)
        _, left, right, top, bottom = areas[name]
        maps.append({"map": map_id, "name": title, "file": file, "left": left, "right": right, "top": top, "bottom": bottom})
        print(f"{title}: {file}")
    with open(os.path.join(out, "maps.json.part"), "w") as f:
        json.dump(maps, f)
    os.replace(os.path.join(out, "maps.json.part"), os.path.join(out, "maps.json"))
    if not maps:
        sys.exit("no map read")


main()
