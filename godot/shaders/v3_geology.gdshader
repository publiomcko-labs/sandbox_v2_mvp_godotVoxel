shader_type spatial;
// Voxel Tools v1.7 CUSTOM0 transition contract, CUSTOM1 Single S4 data.
uniform int u_transition_mask;
uniform vec4 u_geo_mat0 : source_color = vec4(0.27,0.45,0.16,0.95);
uniform vec4 u_geo_mat1 : source_color = vec4(0.37,0.23,0.13,0.96);
uniform vec4 u_geo_mat2 : source_color = vec4(0.72,0.62,0.39,0.94);
uniform vec4 u_geo_mat3 : source_color = vec4(0.61,0.60,0.52,0.85);
uniform vec4 u_geo_mat4 : source_color = vec4(0.43,0.42,0.45,0.82);
uniform vec4 u_geo_mat5 : source_color = vec4(0.20,0.22,0.24,0.91);
varying flat vec4 v_indices;
varying vec4 v_weights;
varying vec3 v_world_pos;
varying vec3 v_world_normal;

vec4 unpack_bytes(float f) {
    uint b = floatBitsToUint(f);
    return vec4(float(b & 255u),float((b >> 8u) & 255u),float((b >> 16u) & 255u),float((b >> 24u) & 255u));
}
vec4 material_at(float slot) {
    if (slot < 0.5) {return u_geo_mat0;}
    if (slot < 1.5) {return u_geo_mat1;}
    if (slot < 2.5) {return u_geo_mat2;}
    if (slot < 3.5) {return u_geo_mat3;}
    if (slot < 4.5) {return u_geo_mat4;}
    return u_geo_mat5;
}
float planar_grain(vec2 p) {
    // Low-cost band-limited procedural detail, no external texture assets.
    return 0.94 + 0.035 * sin(p.x * 8.3 + sin(p.y * 4.7)) * sin(p.y * 9.1)
                + 0.025 * sin(p.x * 2.1 + p.y * 2.8);
}
void vertex() {
    int data = floatBitsToInt(CUSTOM0.a);
    int mask = u_transition_mask & 255;
    int cell_border = data & 63;
    int vertex_border = (data >> 8) & 63;
    float secondary = float((mask & cell_border) != 0) * float((vertex_border & ~mask) == 0);
    VERTEX = mix(VERTEX,CUSTOM0.xyz,secondary);
    int transition = (data >> 16) & 255;
    VERTEX *= float(transition == 0 || (transition & u_transition_mask) != 0);
    v_indices = unpack_bytes(CUSTOM1.x);
    v_weights = unpack_bytes(CUSTOM1.y) / 255.0;
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
    v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
    vec4 weights = v_weights / max(dot(v_weights,vec4(1.0)),0.00001);
    vec4 base = material_at(v_indices.x)*weights.x + material_at(v_indices.y)*weights.y
              + material_at(v_indices.z)*weights.z + material_at(v_indices.w)*weights.w;
    vec3 blend = abs(normalize(v_world_normal));
    blend /= max(blend.x+blend.y+blend.z,0.00001);
    float grain = planar_grain(v_world_pos.yz)*blend.x + planar_grain(v_world_pos.xz)*blend.y
                + planar_grain(v_world_pos.xy)*blend.z;
    ALBEDO = base.rgb * grain;
    ROUGHNESS = clamp(base.a,0.0,1.0);
}
