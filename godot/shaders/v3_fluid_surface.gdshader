shader_type spatial;
render_mode cull_disabled;
uniform vec4 liquid_color : source_color = vec4(0.045,0.30,0.43,1.0);
uniform vec3 liquid_emission = vec3(0.0);
uniform float viscosity = 1.0;
uniform bool flow_surface = false;
varying vec3 world_pos;
varying vec3 world_normal;
void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
    vec3 n = normalize(world_normal);
    float speed = 1.0 / sqrt(max(viscosity,1.0));
    float t = TIME * speed;
    float wx = sin(world_pos.x*1.7 + world_pos.z*1.1 + t*1.9);
    float wz = cos(world_pos.z*2.3 - world_pos.x*0.9 - t*1.6);
    float flow = flow_surface ? 1.0 : 0.0;
    float streak = sin(world_pos.y*9.0 + t*10.0 + world_pos.x*2.6);
    vec3 rippled = normalize(n + vec3(wx,0.0,wz)*mix(0.024,0.05,flow));
    NORMAL = normalize((VIEW_MATRIX * vec4(rippled,0.0)).xyz);
    float fresnel = pow(1.0-clamp(abs(dot(normalize(NORMAL),normalize(VIEW))),0.0,1.0),4.0);
    float lava = clamp(length(liquid_emission),0.0,1.0);
    vec3 water = mix(liquid_color.rgb,vec3(0.19,0.37,0.44),0.24+0.35*fresnel);
    water += vec3(0.05,0.10,0.12)*flow*(0.5+0.5*streak);
    ALBEDO = mix(water,liquid_color.rgb*(0.95+0.035*(wx+wz)),lava);
    ROUGHNESS = mix(0.27,0.76,lava);
    SPECULAR = mix(0.38,0.3,lava);
    EMISSION = liquid_emission*(0.75+0.18*(wx+wz));
}
