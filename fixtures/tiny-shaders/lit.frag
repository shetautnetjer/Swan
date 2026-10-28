#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
layout(binding = 0) uniform sampler2D albedo;

void main() {
    vec4 base = texture(albedo, uv);
    color = vec4(base.rgb * 0.5, base.a);
}
