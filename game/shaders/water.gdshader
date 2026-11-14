shader_type canvas_item;
// Subtle animated glints on open water; leaves muddy banks untouched.
varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec2 p = floor(local_pos);
	float blue = c.b - max(c.r, c.g * 0.8);
	float w1 = sin(p.x * 0.11 + p.y * 0.42 + TIME * 1.3);
	float w2 = sin(p.x * 0.043 - p.y * 0.19 - TIME * 0.8);
	float g = step(0.93, w1 * w2 + 0.1 * sin(TIME * 2.0 + p.x));
	float dark = 0.05 * sin(p.y * 0.25 - TIME * 0.6 + p.x * 0.02);
	if (blue > 0.08) {
		c.rgb += vec3(0.22, 0.28, 0.3) * g + dark;
	}
	COLOR = c;
}
