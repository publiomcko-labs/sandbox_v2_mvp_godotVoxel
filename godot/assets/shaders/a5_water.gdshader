shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

// A5 ocean: no tessellated simulation / no chunk seams. The fixed y=0
// geometry makes exposed terrain edits automatically reveal water.
uniform vec4 deep_tint : source_color = vec4(0.035, 0.23, 0.34, 0.71);
uniform vec4 light_tint : source_color = vec4(0.075, 0.39, 0.48, 0.72);
uniform float ripple_frequency = 0.21;
uniform float ripple_speed = 1.1;
varying vec3 world_pos;

void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    // Stable phase in world coordinates even when the camera-following plane moves.
    float a = sin(world_pos.x * ripple_frequency + TIME * ripple_speed);
    float b = cos(world_pos.z * ripple_frequency * 0.71 - TIME * ripple_speed * 0.8);
    float ripple = clamp(0.5 + 0.25 * a + 0.25 * b, 0.0, 1.0);
    vec4 c = mix(deep_tint, light_tint, ripple);
    ALBEDO = c.rgb;
    ALPHA = c.a;
    ROUGHNESS = 0.26;
    METALLIC = 0.0;
}
