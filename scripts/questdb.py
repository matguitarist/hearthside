#!/usr/bin/env python3
"""Builds AzerothPlus's quest map data (`addons/AzerothPlus/questdb.lua`) from a 1.12 world database
and the client's `WorldMapArea.dbc`.

    ssh root@server bash -s < scripts/questdb-dump.sh > world.tsv   # read-only SELECTs
    cargo run -q --release -p benilla-mpq --example mpqcat -- \\
        wow-data/Data/patch.MPQ 'DBFilesClient\\WorldMapArea.dbc' > WorldMapArea.dbc
    scripts/questdb.py world.tsv WorldMapArea.dbc > addons/AzerothPlus/questdb.lua

The output: each quest by title (1.12 gives the interface no quest ids), its level and races, its
objectives with the creatures and objects where they are found (an item's, the ones that drop or
hold it), and who takes it in; the spawns of each, clustered, in world yards; the zone maps' bounds.
"""

import struct
import sys
from collections import defaultdict

# The spawns kept per creature or object: enough to show where they are, not each one.
MAX_POINTS = 24
# The droppers kept per item, the likeliest first, and the least chance worth showing (percent).
MAX_SOURCES = 10
MIN_CHANCE = 1.0


def read_tables(path):
    tables, rows = {}, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#"):
                rows = tables.setdefault(line[1:], [])
            elif line:
                rows.append(line.split("\t"))
    return tables


def read_zones(path):
    data = open(path, "rb").read()
    magic, n, _, size, _ = struct.unpack("<4s4I", data[:20])
    assert magic == b"WDBC", "not a DBC file"
    strings = data[20 + n * size :]
    zones = {}
    for i in range(n):
        row = data[20 + i * size : 20 + (i + 1) * size]
        _, map_id, _, name = struct.unpack("<4I", row[:16])
        left, right, top, bottom = struct.unpack("<4f", row[16:32])
        if map_id in (0, 1):
            zones[strings[name : strings.index(b"\0", name)].decode()] = (
                map_id, round(left), round(right), round(top), round(bottom))
    return zones


def cluster(points):
    """At most MAX_POINTS points: cells twice as wide each round, each cell its spawns' middle."""
    cell = 20
    while True:
        cells = defaultdict(list)
        for m, x, y in points:
            cells[(m, x // cell, y // cell)].append((x, y))
        if len(cells) <= MAX_POINTS:
            break
        cell *= 2
    # The biggest groups first: they are the likeliest spots.
    out = []
    for (m, _, _), group in sorted(cells.items(), key=lambda kv: -len(kv[1])):
        out.append((m, sum(p[0] for p in group) // len(group), sum(p[1] for p in group) // len(group)))
    return out


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "") + '"'


def lua_list(items):
    return "{" + ",".join(str(i) for i in items) + "}"


def main():
    tables = read_tables(sys.argv[1])
    zones = read_zones(sys.argv[2])

    creature_name, creature_loot = {}, {}
    for entry, name, loot in tables["ctpl"]:
        creature_name[int(entry)] = name
        if int(loot):
            creature_loot[int(entry)] = int(loot)
    object_name, chest_loot = {}, {}
    for entry, kind, name, data1 in tables["gtpl"]:
        object_name[int(entry)] = name
        if kind == "3" and int(data1):  # a chest: data1 is its loot
            chest_loot[int(entry)] = int(data1)
    item_name = {int(e): n for e, n in tables["item"]}

    spawns = {"c": defaultdict(list), "g": defaultdict(list)}
    for key, table in (("c", "cspawn"), ("g", "gspawn")):
        for entry, m, x, y in tables[table]:
            spawns[key][int(entry)].append((int(m), int(x), int(y)))

    # item -> [(chance, creature)], [(chance, object)]
    loot_creatures = defaultdict(list)
    for entry, item, chance in tables["cloot"]:
        loot_creatures[(int(entry), int(item))] = abs(float(chance))
    by_loot = defaultdict(list)
    for creature, loot in creature_loot.items():
        by_loot[loot].append(creature)
    item_creatures = defaultdict(list)
    for (loot, item), chance in loot_creatures.items():
        for creature in by_loot.get(loot, ()):
            if spawns["c"].get(creature):
                item_creatures[item].append((chance, creature))
    chests_by_loot = defaultdict(list)
    for obj, loot in chest_loot.items():
        chests_by_loot[loot].append(obj)
    item_objects = defaultdict(list)
    for entry, item, chance in tables["gloot"]:
        for obj in chests_by_loot.get(int(entry), ()):
            if spawns["g"].get(obj):
                item_objects[int(item)].append((abs(float(chance)), obj))

    def sources(pairs):
        pairs = sorted((p for p in pairs if p[0] >= MIN_CHANCE or p[0] == 0), key=lambda p: -p[0])
        return sorted({entry for _, entry in pairs[:MAX_SOURCES]})

    enders = defaultdict(lambda: ([], []))
    for creature, quest in tables["cend"]:
        enders[int(quest)][0].append(int(creature))
    for obj, quest in tables["gend"]:
        enders[int(quest)][1].append(int(obj))

    used = {"c": set(), "g": set()}
    quests = defaultdict(list)
    for row in tables["quest"]:
        quest, title, level, min_level, races, _zone = row[:6]
        texts, items, targets = row[6:10], row[10:14], row[14:18]
        if not title or title.startswith("<"):
            continue
        objectives = []
        for i in range(4):
            target = int(targets[i])
            if target > 0 and spawns["c"].get(target):
                objectives.append((texts[i] or creature_name.get(target, ""), [target], []))
            elif target < 0 and spawns["g"].get(-target):
                objectives.append((texts[i] or object_name.get(-target, ""), [], [-target]))
        for i in range(4):
            item = int(items[i])
            if item:
                units = sources(item_creatures.get(item, ()))
                objects = sources(item_objects.get(item, ()))
                if units or objects:
                    objectives.append((item_name.get(item, ""), units, objects))
        end_units = [c for c in enders[int(quest)][0] if spawns["c"].get(c)]
        end_objects = [g for g in enders[int(quest)][1] if spawns["g"].get(g)]
        if not objectives and not end_units and not end_objects:
            continue
        for _, units, objects in objectives:
            used["c"].update(units)
            used["g"].update(objects)
        used["c"].update(end_units)
        used["g"].update(end_objects)
        level = int(level) if int(level) > 0 else int(min_level)
        quests[title].append((level, int(races), objectives, end_units, end_objects))

    out = sys.stdout
    out.write("-- Generated by scripts/questdb.py from a CMaNGOS Classic world database; do not edit.\n")
    out.write("-- zones: name = {map, left, right, top, bottom} in world yards (`WorldMapArea.dbc`).\n")
    out.write("-- units, objects: their spawns clustered, \"map x y map x y ...\".\n")
    out.write("-- quests: title = {{level, races, {{objective, {units}, {objects}}, ...}, {enders}, {ender objects}}, ...}.\n")
    out.write("-- names: unit id = its name, for the tooltips' quest lines.\n")
    out.write("AzerothPlusQuestDB = {\nzones = {\n")
    for name, bounds in sorted(zones.items()):
        out.write(f"{name} = {lua_list(bounds)},\n")
    for key, label in (("c", "units"), ("g", "objects")):
        out.write(f"}},\n{label} = {{\n")
        for entry in sorted(used[key]):
            points = " ".join(f"{m} {x} {y}" for m, x, y in cluster(spawns[key][entry]))
            out.write(f'[{entry}] = "{points}",\n')
    out.write("},\nnames = {\n")
    for entry in sorted(used["c"]):
        out.write(f"[{entry}] = {lua_string(creature_name.get(entry, ''))},\n")
    out.write("},\nquests = {\n")
    for title in sorted(quests):
        variants = []
        for level, races, objectives, end_units, end_objects in quests[title]:
            objs = ",".join(
                "{" + lua_string(name) + "," + lua_list(units) + "," + lua_list(objects) + "}"
                for name, units, objects in objectives)
            variants.append(
                f"{{{level},{races},{{{objs}}},{lua_list(end_units)},{lua_list(end_objects)}}}")
        out.write(f"[{lua_string(title)}] = {{{','.join(variants)}}},\n")
    out.write("},\n}\n")
    print(f"questdb: {sum(len(v) for v in quests.values())} quests, "
          f"{len(used['c'])} creatures, {len(used['g'])} objects", file=sys.stderr)


if __name__ == "__main__":
    main()
