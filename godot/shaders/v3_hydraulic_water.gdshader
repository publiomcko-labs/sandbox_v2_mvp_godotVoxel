shader_type spatial;
render_mode cull_disabled;
uniform vec4 liquid_color : source_color=vec4(0.045,0.3,0.43,1.0);
uniform vec3 liquid_emission=vec3(0.0);
uniform float viscosity=1.0;
varying vec3 world_pos;
void vertex(){
    world_pos=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
}
void fragment(){
    // No visible free surface inside a completely filled interval.
    if(world_pos.y>=UV.y-0.001){discard;}
    float t=TIME/sqrt(max(viscosity,1.0));
    float a=sin(world_pos.x*1.8+world_pos.z*1.2+t*1.6);
    float b=cos(world_pos.z*2.0-world_pos.x*0.9-t*1.4);
    NORMAL=normalize((VIEW_MATRIX*vec4(normalize(vec3(a*0.028,1.0,b*0.028)),0.0)).xyz);
    float fresnel=pow(1.0-clamp(abs(dot(NORMAL,normalize(VIEW))),0.0,1.0),4.0);
    float lava=clamp(length(liquid_emission),0.0,1.0);
    ALBEDO=liquid_color.rgb*(0.95+0.025*(a+b))+vec3(0.06,0.10,0.12)*fresnel*(1.0-lava);
    ROUGHNESS=mix(0.25,0.76,lava);
    SPECULAR=mix(0.45,0.3,lava);
    EMISSION=liquid_emission*(0.8+0.12*(a+b));
}
