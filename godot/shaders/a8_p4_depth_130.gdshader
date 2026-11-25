shader_type spatial;
// A8-P4 diagnostic ONLY. Fullscreen quad samples the actual camera depth
// attachment after opaque world geometry. Never apply to baseline terrain.
// Godot Compatibility uses OpenGL NDC z = depth*2-1.
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;

void vertex() {
    POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
    float z = texture(scene_depth, SCREEN_UV).r;
    vec3 color = vec3(0.0, 0.0, 0.0); // BLACK = unprojection error
    if (z <= 0.000001) {
        color = vec3(0.0, 0.0, 1.0); // BLUE = no opaque depth (sky)
    } else {
        #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
        vec3 ndc = vec3(SCREEN_UV, z) * 2.0 - 1.0;
        #else
        vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, z);
        #endif
        vec4 w = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
        if (abs(w.w) >= 0.00000001) {
            vec3 wp = w.xyz / w.w;
            float horizontal_m = length(wp.xz - CAMERA_POSITION_WORLD.xz);
            if (horizontal_m < 129.0) {
                color = vec3(0.0, 1.0, 0.0); // GREEN = opaque <=129 m
            } else if (horizontal_m <= 131.0) {
                color = vec3(1.0, 1.0, 0.0); // YELLOW = boundary ±1 m
            } else {
                color = vec3(1.0, 0.0, 0.0); // RED = opaque >131 m
            }
        }
    }
    ALBEDO = color;
}
