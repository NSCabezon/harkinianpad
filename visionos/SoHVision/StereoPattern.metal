// S0 stereo spike: test pattern written by the background producer, one
// dispatch per eye. Left = red, right = blue; a white bar sweeps across with
// crossed disparity (left image shifted right, right image shifted left), so on
// device the bar floats in front of the window plane while the grid sits on it.
#include <metal_stdlib>
using namespace metal;

struct StereoPatternParams {
    float time;
    float disparity; // fraction of the image width between the two bar copies
    uint eye;        // 0 = left, 1 = right
};

kernel void stereoPattern(texture2d<float, access::write> out [[texture(0)]],
                          constant StereoPatternParams &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());

    float3 c = p.eye == 0 ? float3(0.80, 0.08, 0.08) : float3(0.08, 0.18, 0.85);

    // Zero-disparity grid (identical in both eyes -> on the window plane).
    float2 g = fract(uv * float2(16.0, 9.0));
    if (g.x < 0.04 || g.y < 0.06) c *= 0.55;

    // Moving bar with per-eye offset.
    float side = p.eye == 0 ? 1.0 : -1.0;
    float center = 0.5 + 0.3 * sin(p.time * 1.5) + side * p.disparity * 0.5;
    if (abs(uv.x - center) < 0.025 && uv.y > 0.15 && uv.y < 0.85) c = float3(1.0);

    // Orientation marker: yellow square in the texture's top-left (row 0).
    if (uv.x < 0.06 && uv.y < 0.1) c = float3(1.0, 0.9, 0.0);
    // Eye marker: 1 dot for left, 2 dots for right, top-right corner.
    for (uint i = 0; i <= p.eye; i++) {
        float2 d = uv - float2(0.94 - 0.05 * float(i), 0.07);
        if (length(d * float2(16.0, 9.0)) < 0.35) c = float3(1.0);
    }
    out.write(float4(c, 1.0), gid);
}
