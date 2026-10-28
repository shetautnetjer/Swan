Texture2D albedo : register(t0);
SamplerState linearSampler : register(s0);

float4 main(float2 uv : TEXCOORD0) : SV_Target
{
    float4 base = albedo.Sample(linearSampler, uv);
    return float4(base.rgb * 0.5, base.a);
}
