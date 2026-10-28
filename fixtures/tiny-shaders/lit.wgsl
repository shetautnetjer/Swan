@group(0) @binding(0) var albedo: texture_2d<f32>;
@group(0) @binding(1) var linear_sampler: sampler;

@fragment
fn main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let base = textureSample(albedo, linear_sampler, uv);
    return vec4<f32>(base.rgb * 0.5, base.a);
}
