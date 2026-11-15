class_name Appearance
## Character appearance options available with the current art (cloth colour).

const CLOTH := {
	"olive": {"label": "Olive", "hue": -1.0, "swatch": Color(0.34, 0.41, 0.17)},
	"crimson": {"label": "Crimson", "hue": 0.985, "sat": 1.05, "val": 1.0, "swatch": Color(0.55, 0.12, 0.1)},
	"azure": {"label": "Azure", "hue": 0.6, "sat": 0.95, "val": 1.05, "swatch": Color(0.17, 0.3, 0.55)},
	"umber": {"label": "Umber", "hue": 0.075, "sat": 0.85, "val": 0.85, "swatch": Color(0.42, 0.28, 0.15)},
	"plum": {"label": "Plum", "hue": 0.83, "sat": 0.75, "val": 0.95, "swatch": Color(0.4, 0.18, 0.4)},
}

static var _shader: Shader


static func material_for(appearance: Dictionary) -> ShaderMaterial:
	var cfg: Dictionary = CLOTH.get(appearance.get("cloth", "olive"), CLOTH["olive"])
	if float(cfg["hue"]) < 0.0:
		return null
	if _shader == null:
		_shader = load("res://shaders/cloth_tint.gdshader")
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("target_hue", cfg["hue"])
	m.set_shader_parameter("sat_scale", cfg.get("sat", 1.0))
	m.set_shader_parameter("val_scale", cfg.get("val", 1.0))
	return m
