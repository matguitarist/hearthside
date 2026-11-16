#!/usr/bin/env python3
"""Lets the 5.4.8 Mac client (`World of Warcraft-64`, x86_64) log on to a private server: the
Mach-O x64 patches of Arctium's connection patcher (GPL v3, in LoA-Pandaria-Playerbots under
`contrib/SkyFire Patcher/548`), with its matching: a 0x00 in a pattern matches any byte, the first
match wins; plus one of ours for Apple silicon (GPU). `mac-client-setup` runs it.

    mac-client-patch.py check <binary>     what is patched already
    mac-client-patch.py patch <binary>     patch in place (keeps <binary>.orig)
"""

import shutil
import sys

PATCHES = {  # name: (pattern, bytes)
    "Send": ([0x8B, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00, 0x89, 0x00, 0x25, 0x00, 0x00, 0x00, 0x00, 0x3D,
              0x00, 0x00, 0x00, 0x00, 0x75, 0x36], [0x31, 0xC9, 0x90]),
    "Email": ([0x74, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48,
               0x00, 0x00, 0x74, 0x00, 0x48, 0x00, 0x00, 0xFF, 0x90], [0xEB]),
    "User": ([0x40, 0x00, 0x00, 0x00, 0xE8, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x0F, 0x84, 0x00,
              0x00, 0x00, 0x00, 0xC7, 0x05, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF], [0x00]),
    "RaF": ([0x48, 0x8D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48,
             0x8D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x48, 0x00, 0x00, 0x31],
            [0x31, 0xC0, 0xE9, 0xE5, 0x02, 0x00, 0x00]),
    "Rcv": ([0x02, 0x0F, 0x85, 0x00, 0x00, 0x00, 0x00, 0x49, 0x00, 0x00, 0x80, 0x85, 0x00, 0x00, 0xBE,
             0x00, 0x00, 0x00, 0x00, 0x4C, 0x00, 0x00], [0xFF, 0x0F, 0x84]),
    # Ours: the client names its GPU from the PCI vendor and device IDs in IOKit and stops at
    # INVALID_VIDEO_DEVICE without them; Apple silicon's GPU is no PCI device, though OpenGL works
    # through Rosetta. The `jne` past that alert becomes a `jmp`.
    "GPU": ([0x0F, 0x85, 0xFD, 0x00, 0x00, 0x00, 0x48, 0x8D, 0x7D, 0xD0, 0xE8], [0x90, 0xE9]),
}


def find(data, pattern):
    first = pattern[0]
    i = data.find(bytes([first]))
    while i != -1 and i + len(pattern) <= len(data):
        if all(p == 0 or data[i + j] == p for j, p in enumerate(pattern)):
            return i
        i = data.find(bytes([first]), i + 1)
    return None


def main():
    mode, path = sys.argv[1], sys.argv[2]
    data = bytearray(open(path, "rb").read())
    assert data[:4] == b"\xcf\xfa\xed\xfe", "not a 64-bit Mach-O"
    todo, missing = [], []
    for name, (pattern, patch) in PATCHES.items():
        at = find(data, pattern)
        if at is not None:
            print(f"{name}: at {at:#x}, unpatched")
            todo.append((at, patch))
            continue
        # A patch overwrites the start of its pattern: look for it with the patch in place.
        done = find(data, list(patch) + pattern[len(patch):])
        if done is not None and data[done:done + len(patch)] == bytes(patch):
            print(f"{name}: at {done:#x}, patched")
        else:
            print(f"{name}: not found (another build?)")
            missing.append(name)
    if mode != "patch":
        return
    if missing:
        sys.exit(f"not patching: {', '.join(missing)} not found")
    if not todo:
        print("nothing to do")
        return
    for at, patch in todo:
        data[at:at + len(patch)] = bytes(patch)
    shutil.copy2(path, path + ".orig")
    open(path, "wb").write(data)
    print("patched")


if __name__ == "__main__":
    main()
