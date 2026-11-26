shader_type spatial;
render_mode cull_disabled;
uniform vec4 liquid_color : source_color = vec4(0.045,0.30,0.43,1.0);
uniform vec3 liquid_emission = vec3(0.0);
uniform float viscosity = 1.0;
varying vec3 world_pos;
varying vec3 world_normal;
void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
    vec3 n = normalize(world_normal);
    float top = clamp(n.y,0.0,1.0);
    float speed = 1.0 / sqrt(max(viscosity,1.0));
    float t = TIME * speed;
    float wx = sin(world_pos.x*3.1 + world_pos.z*1.4 + t*1.6);
    float wz = cos(world_pos.z*2.7 - world_pos.x*1.1 - t*1.3);
    vec3 rippled = normalize(n + vec3(wx,0.0,wz)*0.075*top);
    NORMAL = normalize((VIEW_MATRIX * vec4(rippled,0.0)).xyz);
    float fresnel = pow(1.0-clamp(dot(normalize(NORMAL),normalize(VIEW)),0.0,1.0),4.0);
    float lava = clamp(length(liquid_emission),0.0,1.0);
    ALBEDO = liquid_color.rgb * (0.94 + 0.04*(wx+wz)) + vec3(0.07,0.11,0.13)*fresnel*(1.0-lava);
    ROUGHNESS = mix(0.16,0.72,lava);
    SPECULAR = mix(0.75,0.3,lava);
    EMISSION = liquid_emission*(0.75+0.18*(wx+wz));
}
