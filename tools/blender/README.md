# Blender comparison (experiment)

Used once to answer "would a Blender 3D-to-2D pipeline look substantially
better?" for the benchmark character. Result and conclusions:
`docs/CHARACTER_PIPELINE.md`, section 3.

```bash
python3 tools/blender/export_grid.py /tmp/grid.npz        # forge python (numba): samples the kit character
python3 -m venv /tmp/bvenv && /tmp/bvenv/bin/pip install bpy scikit-image pillow
/tmp/bvenv/bin/python tools/blender/render_bpy.py /tmp/grid.npz /tmp/out    # Cycles CPU, 8 facings
```

`render_bpy.py` meshes the grid (marching cubes), colours it per material and
renders it with Cycles through the game's camera contract (orthographic, 30°
elevation, 45° azimuth, the forge's sun direction). Tested with bpy 5.3 on
Python 3.13, CPU only: 8 facings in about 42 s.

This is not part of the asset build. It has no animation, no material passes
and no finishing step.
