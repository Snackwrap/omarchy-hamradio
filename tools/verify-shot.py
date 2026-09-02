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

edges = np.concatenate([img[0, :, :], img[-1, :, :], img[:, 0, :], img[:, -1, :]])
spread = edges.std(axis=0).max()
if spread > 26:
    print(f"not the popup: border varies by {spread:.1f}")
    sys.exit(1)
print(f"popup border is uniform (sigma {spread:.1f})")
