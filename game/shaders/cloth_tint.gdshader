shader_type canvas_item;
// Appearance variants without new art: re-hue the green cloth (tunic, cloak,
// sleeves) of the pre-rendered character; skin, hair, leather and metal keep
// their colours because they sit outside the green hue band.
uniform float target_hue = 0.0;
uniform float sat_scale = 1.0;
uniform float val_scale = 1.0;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec3 hsv = rgb2hsv(c.rgb);
	float green = smoothstep(0.13, 0.17, hsv.x) * (1.0 - smoothstep(0.42, 0.48, hsv.x)) * smoothstep(0.12, 0.22, hsv.y);
	vec3 tinted = hsv2rgb(vec3(target_hue, clamp(hsv.y * sat_scale, 0.0, 1.0), clamp(hsv.z * val_scale, 0.0, 1.0)));
	COLOR = vec4(mix(c.rgb, tinted, green), c.a) * COLOR;
}
