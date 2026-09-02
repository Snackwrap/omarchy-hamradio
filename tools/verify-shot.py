#!/usr/bin/env python3
"""Exit 0 if the image looks like the plugin popup, non-zero otherwise.

The popup can lose focus and close between reporting its geometry and the
screenshot, and grim will happily photograph whatever is underneath it — so the
failure mode looks exactly like a successful capture of the wrong window. The
crop is taken to include the popup's one-pixel border on all four sides, so a
genuine capture has a near-uniform ring around the outside; an accidental
photograph of a browser does not.
"""
import subprocess, sys
import numpy as np

path = sys.argv[1]
out = subprocess.run(["magick", path, "-depth", "8", "ppm:-"],
                     check=True, capture_output=True).stdout
fields, pos = [], 2
while len(fields) < 3:
    while out[pos:pos + 1].isspace():
        pos += 1
    start = pos
    while not out[pos:pos + 1].isspace():
        pos += 1
    fields.append(int(out[start:pos]))
w, h, _ = fields
img = np.frombuffer(out[pos + 1:], dtype=np.uint8).reshape(h, w, 3).astype(int)

# Look for a uniform ring anywhere in the first few pixels rather than at one
# fixed inset. The popup's border is one logical pixel, which lands on a
# different device row depending on the output scale, and the very edge is a
# blend of border and background — so the test is "is any of these rings
# essentially one colour", which a window underneath never satisfies.
best = None
for inset in range(0, 6):
    if img.shape[0] <= inset * 2 + 4 or img.shape[1] <= inset * 2 + 4:
        break
    end = -inset or None
    ring = np.concatenate([img[inset, inset:end, :], img[-1 - inset, inset:end, :],
                           img[inset:end, inset, :], img[inset:end, -1 - inset, :]])
    spread = ring.std(axis=0).max()
    if best is None or spread < best:
        best = spread

if best is None or best > 12:
    print(f"not the popup: no uniform border (best ring varies by {best})")
    sys.exit(1)
print(f"popup border found (ring sigma {best:.1f})")
