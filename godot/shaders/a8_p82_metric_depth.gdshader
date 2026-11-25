shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled;
uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform float range_start_m = 9.0;
void vertex() { POSITION = vec4(VERTEX.xy, 1.0, 1.0); }
void fragment() {
    float z = texture(scene_depth, SCREEN_UV).r;
    float code = 1.0;
    if (z > 0.000001) {
        vec3 ndc = vec3(SCREEN_UV, z) * 2.0 - 1.0;
        vec4 p = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
        if (abs(p.w) > 0.00000001) {
            float local_m = length(p.xyz / p.w) - range_start_m;
            // Never clamp out-of-range depth into a plausible measurement.
            if (local_m >= 0.0 && local_m <= 8.0) {
                code = 0.05 + 0.90 * local_m / 8.0;
            }
        }
    }
    ALBEDO = vec3(code);
}
