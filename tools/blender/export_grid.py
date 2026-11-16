"""Sample the kit character's signed-distance field on a grid (for meshing)."""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "forge"))
import numpy as np, numba as nb
import sdf
from models import characters as C

@nb.njit(parallel=True, cache=False)
def grid(recs, xs, ys, zs):
    D = np.empty((xs.size, ys.size, zs.size)); M = np.empty((xs.size, ys.size, zs.size), np.int64)
    for i in nb.prange(xs.size):
        for j in range(ys.size):
            for k in range(zs.size):
                d, bi = sdf.scene_eval(recs, xs[i], ys[j], zs[k])
                D[i, j, k] = d; M[i, j, k] = bi
    return D, M

sc, _ = C.adventurer_pose(walk=0.0, weapon="iron_sword")
recs = sc.array()
h = 0.006
xs = np.arange(-0.75, 0.95, h); ys = np.arange(-0.6, 0.6, h); zs = np.arange(-0.02, 1.95, h)
D, M = grid(recs, xs, ys, zs)
mat = recs[np.maximum(M, 0), 1].astype(int)
cols = []
for m in sc.materials:
    r = getattr(m, "ramp", None)
    cols.append(r[len(r) - 2] if r is not None else np.array([0.75, 0.78, 0.85]))
np.savez_compressed(sys.argv[1], D=D.astype(np.float32), mat=mat.astype(np.int16), cols=np.array(cols), origin=np.array([xs[0], ys[0], zs[0]]), h=h)
print(D.shape, len(cols))
