shader_type spatial;
// Diagnostic water plane retains original two-sided visibility.
render_mode unshaded, fog_disabled, cull_disabled;
uniform vec4 tag_color : source_color = vec4(0.0, 1.0, 0.0, 1.0);
void fragment() {
    ALBEDO = tag_color.rgb;
}
