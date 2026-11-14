class_name Iso
## Isometric projection shared with the Sprite Forge (tools/forge/render.py).
##
## World space: 1 unit = 1 ground tile edge. +x runs screen down-right,
## +y runs screen down-left, z is height. Orthographic camera at 30 deg
## elevation / 45 deg azimuth gives an exact 2:1 diamond.

const DIRECTIONS: PackedStringArray = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]


static func to_screen(w: Vector2, tile_w: float) -> Vector2:
	return Vector2((w.x - w.y) * tile_w * 0.5, (w.x + w.y) * tile_w * 0.25)


static func to_world(s: Vector2, tile_w: float) -> Vector2:
	var a := s.x * 2.0 / tile_w
	var b := s.y * 4.0 / tile_w
	return Vector2((a + b) * 0.5, (b - a) * 0.5)


## Facing index for a world-space direction. Facing k looks along yaw 45+45k deg.
static func dir_index(world_dir: Vector2) -> int:
	var ang := rad_to_deg(atan2(world_dir.y, world_dir.x))
	return posmod(roundi((ang - 45.0) / 45.0), 8)


static func dir_vector(k: int) -> Vector2:
	var a := deg_to_rad(45.0 + 45.0 * k)
	return Vector2(cos(a), sin(a))
