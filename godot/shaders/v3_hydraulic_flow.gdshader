shader_type spatial;
render_mode cull_disabled;
uniform vec4 liquid_color : source_color=vec4(0.045,0.3,0.43,1.0);
uniform vec3 liquid_emission=vec3(0.0);
uniform float viscosity=1.0;
varying vec3 world_pos;
void vertex() {
    world_pos=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
}
void fragment() {
    float t=TIME/sqrt(max(viscosity,1.0));
    float ripple=0.5+0.5*sin(world_pos.y*12.0+t*11.0+sin(world_pos.x*7.0+world_pos.z*6.0));
    float lava=clamp(length(liquid_emission),0.0,1.0);
    ALBEDO=liquid_color.rgb*(1.05+0.16*ripple)+vec3(0.025,0.055,0.07)*(1.0-lava)*ripple;
    ROUGHNESS=mix(0.42,0.76,lava);
    SPECULAR=0.25;
    EMISSION=liquid_emission*(0.8+0.15*ripple);
}
