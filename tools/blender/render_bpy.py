"""Blender (bpy, Cycles CPU) render of the same character through the game's
camera contract: orthographic, 30 deg elevation, 45 deg azimuth, 8 facings."""
import sys, math
import numpy as np
import bpy
from skimage import measure

g = np.load(sys.argv[1]); out = sys.argv[2]
D, mat, cols, origin, h = g["D"], g["mat"], g["cols"], g["origin"], float(g["h"])
verts, faces, normals, _ = measure.marching_cubes(D, 0.0, spacing=(h, h, h))
verts = verts + origin
idx = np.clip(np.round((verts - origin) / h).astype(int), 0, np.array(D.shape) - 1)
vcol = cols[mat[idx[:, 0], idx[:, 1], idx[:, 2]]]
bpy.ops.wm.read_factory_settings(use_empty=True)
me = bpy.data.meshes.new("char"); me.from_pydata(verts.tolist(), [], faces.tolist()); me.update()
ca = me.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
ca.data.foreach_set("color", np.concatenate([vcol ** 2.2, np.ones((len(vcol), 1))], axis=1).ravel())
for p in me.polygons: p.use_smooth = True
ob = bpy.data.objects.new("char", me); bpy.context.scene.collection.objects.link(ob)
m = bpy.data.materials.new("m"); m.use_nodes = True
nt = m.node_tree; bsdf = nt.nodes["Principled BSDF"]
attr = nt.nodes.new("ShaderNodeAttribute"); attr.attribute_name = "Col"
nt.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"]); bsdf.inputs["Roughness"].default_value = 0.75
me.materials.append(m)
sc = bpy.context.scene
sc.render.engine = "CYCLES"; sc.cycles.device = "CPU"; sc.cycles.samples = 48; sc.cycles.use_denoising = False
sc.render.film_transparent = True
sc.view_settings.view_transform = "Standard"
TW = 64; S = 4                       # supersample 4x, then reduce to the sprite's real size
k = TW / math.sqrt(2)                # px per world unit across the view
W, H = 96, 112
sc.render.resolution_x, sc.render.resolution_y = W * S, H * S
cam_d = bpy.data.cameras.new("c"); cam_d.type = "ORTHO"; cam_d.ortho_scale = W / k
cam = bpy.data.objects.new("c", cam_d); sc.collection.objects.link(cam); sc.camera = cam
sun_d = bpy.data.lights.new("s", "SUN"); sun_d.energy = 4.0; sun_d.angle = 0.05
sun = bpy.data.objects.new("s", sun_d); sc.collection.objects.link(sun)
world = bpy.data.worlds.new("w"); sc.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.56, 0.66, 1); world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
from mathutils import Vector
el = math.radians(30)
for i, name in enumerate(["S", "SW", "W", "NW", "N", "NE", "E", "SE"]):
    ob.rotation_euler = (0, 0, math.radians(45 + 45 * i))
    tc = Vector((math.cos(el) / math.sqrt(2), math.cos(el) / math.sqrt(2), math.sin(el)))
    target = Vector((0, 0, 0.92))
    cam.location = target + tc * 10
    cam.rotation_euler = (-tc).to_track_quat("-Z", "Y").to_euler()
    sd = Vector((0.32, 0.95, 1.25)).normalized()
    sun.rotation_euler = (-sd).to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = f"{out}/bl_{i}_{name}.png"
    bpy.ops.render.render(write_still=True)
print("rendered")
