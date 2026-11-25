shader_type spatial;
// Opaque scene tags and depth sampled at the SAME pixel in one diagnostic draw.
// Water is deliberately opaque in this arm (nearest geometric surface only).
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled;
uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D scene_tags : hint_screen_texture, repeat_disable, filter_nearest;
uniform float range_start_m = 9.0;
void vertex() { POSITION = vec4(VERTEX.xy, 1.0, 1.0); }
void fragment() {
    float z = texture(scene_depth, SCREEN_UV).r;
    vec3 tag = texture(scene_tags, SCREEN_UV).rgb;
    vec3 code = vec3(1.0, 0.0, 1.0); // UNKNOWN
    if (z <= 0.000001) {
        code = vec3(0.0, 1.0, 1.0); // NO HIT
    } else if (tag.r > 0.75 && tag.g < 0.15 && tag.b < 0.15) {
        code = vec3(1.0, 0.0, 0.0); // ROCK
    } else if (tag.b > 0.75 && tag.r < 0.15 && tag.g < 0.15) {
        code = vec3(0.0, 0.0, 1.0); // WATER GEOMETRIC PLANE
    } else if (tag.g > 0.75 && tag.r < 0.15 && tag.b < 0.15) {
        vec3 ndc = vec3(SCREEN_UV, z) * 2.0 - 1.0;
        vec4 p = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
        if (abs(p.w) > 0.00000001) {
            float local_m = length(p.xyz / p.w) - range_start_m;
            if (local_m >= 0.0 && local_m <= 5.0) {
                code = vec3(0.04 + 0.92 * local_m / 5.0);
            } else {
                code = vec3(1.0, 1.0, 0.0); // TERRAIN OUTSIDE RANGE
            }
        }
    }
    ALBEDO = code;
}
