#include <metal_stdlib>
using namespace metal;

// Presents the engine's eye texture into the window drawable (HPVisionHost.m).
// The viewport does the letterboxing; this is a plain textured quad.

struct HPPresentUniforms {
    uint encodeSRGB; // source is sRGB (sampled as linear), target is not
};

struct HPPresentVaryings {
    float4 position [[position]];
    float2 uv;
};

vertex HPPresentVaryings hp_present_vertex(uint vid [[vertex_id]]) {
    // Triangle strip: (-1,-1) (1,-1) (-1,1) (1,1). Texture origin is top-left.
    float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    HPPresentVaryings out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

static float3 linear_to_srgb(float3 c) {
    c = saturate(c);
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    return select(hi, lo, c <= 0.0031308);
}

fragment float4 hp_present_fragment(HPPresentVaryings in [[stage_in]],
                                    constant HPPresentUniforms& uniforms [[buffer(0)]],
                                    texture2d<float> source [[texture(0)]],
                                    sampler smp [[sampler(0)]]) {
    float4 c = source.sample(smp, in.uv);
    if (uniforms.encodeSRGB != 0) {
        c.rgb = linear_to_srgb(c.rgb);
    }
    return float4(c.rgb, 1.0);
}
