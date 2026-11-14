// Draws the guest's display, scaled, and the CRT effect: a Metal version of the
// egui frontend's CRT Lottes shader (frontend_egui/shaders/crt-lottes-fast.glsl).
// ScreenRenderer runs them.
//
// They render at the size of the screen's area in the window, in its pixels, which
// is the size the shader was made for: scanlines and masks come out at the window's
// resolution. The egui frontend renders it at the display's size instead.
//
// Texture coordinates run from the top left, so v grows with the display's rows, as
// it does in the egui frontend's OpenGL textures.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

/// A triangle that covers the whole target
vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    const float2 positions[3] = {float2(-1, 1), float2(3, 1), float2(-1, -3)};
    const float2 uvs[3] = {float2(0, 0), float2(2, 0), float2(0, 2)};
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

/// Sizes in pixels: of the texture the pass samples, and of what it renders
struct Sizes {
    float2 source;
    float2 output;
};

/// No effects: the display, scaled with the sampler's filter
fragment float4 plainCopy(
    VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    return float4(source.sample(s, in.uv).rgb, 1.0);
}

// MARK: - CRT Lottes (crt-lottes-fast.glsl)
//
// Its parameters are in the order of the `#pragma parameter` lines in the GLSL,
// which is the order snow_ffi gives them in.
//
// As the egui frontend builds it: CRTS_2_TAP, CRTS_WARP and CRTS_TONE, with
// CRTS_CONTRAST and CRTS_SATURATION defined (to 0, which still turns them on).

struct LottesParameters {
    float MASK;
    float MASK_INTENSITY;
    float SCANLINE_THINNESS;
    float SCAN_BLUR;
    float CURVATURE;
    float TRINITRON_CURVE;
    float CORNER;
    float CRT_GAMMA;
};

static float fromSrgb1(float c, float gamma) {
    return c <= 0.04045 ? c * (1.0 / 12.92) : pow(c * (1.0 / 1.055) + (0.055 / 1.055), gamma);
}

static float3 fromSrgb(float3 c, float gamma) {
    return float3(fromSrgb1(c.r, gamma), fromSrgb1(c.g, gamma), fromSrgb1(c.b, gamma));
}

static float toSrgb1(float c) {
    return c < 0.0031308 ? c * 12.92 : 1.055 * pow(c, 0.41666) - 0.055;
}

static float3 toSrgb(float3 c) {
    return float3(toSrgb1(c.r), toSrgb1(c.g), toSrgb1(c.b));
}

static float4 crtsTone(float contrast, float saturation, float thin, float mask, float maskType) {
    if (maskType == 0.0) mask = 1.0;
    if (maskType == 1.0) mask = 0.5 + mask * 0.5;
    float midOut = 0.18 / ((1.5 - thin) * (0.5 * mask + 0.5));
    float pMidIn = pow(0.18, contrast);
    float4 ret;
    ret.x = contrast;
    ret.y = ((-pMidIn) + midOut) / ((1.0 - pMidIn) * midOut);
    ret.z = ((-pMidIn) * midOut + pMidIn) / (midOut * (-pMidIn) + midOut);
    ret.w = contrast + saturation;
    return ret;
}

static float3 crtsMask(float2 pos, float dark, float maskType) {
    if (maskType == 2.0) {
        float3 m = float3(dark);
        float x = fract(pos.x * (1.0 / 3.0));
        if (x < (1.0 / 3.0)) m.r = 1.0;
        else if (x < (2.0 / 3.0)) m.g = 1.0;
        else m.b = 1.0;
        return m;
    }
    if (maskType == 1.0) {
        float3 m = float3(1.0);
        float x = fract(pos.x * (1.0 / 3.0));
        if (x < (1.0 / 3.0)) m.r = dark;
        else if (x < (2.0 / 3.0)) m.g = dark;
        else m.b = dark;
        return m;
    }
    if (maskType == 3.0) {
        pos.x += pos.y * 2.9999;
        float3 m = float3(dark);
        float x = fract(pos.x * (1.0 / 6.0));
        if (x < (1.0 / 3.0)) m.r = 1.0;
        else if (x < (2.0 / 3.0)) m.g = 1.0;
        else m.b = 1.0;
        return m;
    }
    return float3(1.0);
}

fragment float4 crtLottes(
    VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
    sampler s [[sampler(0)]], constant Sizes &sizes [[buffer(0)]],
    constant LottesParameters &p [[buffer(1)]]
) {
    float2 warp;
    warp.x = p.CURVATURE;
    warp.y = (3.0 / 4.0) * warp.x;  // assumes 4:3
    warp.x *= (1.0 - p.TRINITRON_CURVE);

    float thin = 0.5 + (0.5 * p.SCANLINE_THINNESS);
    float mask = 1.0 - p.MASK_INTENSITY;
    float4 tone = crtsTone(1.0, 0.0, thin, mask, p.MASK);

    // The texture is the input's size
    float2 ipos = in.uv * sizes.output;
    float2 halfInputSize = sizes.source * 0.5;
    float2 rcpInputSize = 1.0 / sizes.source;
    float2 twoDivOutputSize = 2.0 / sizes.output;
    float inputHeight = sizes.source.y;

    float2 pos = ipos * twoDivOutputSize - float2(1.0, 1.0);
    pos *= float2(1.0 + (pos.y * pos.y) * warp.x, 1.0 + (pos.x * pos.x) * warp.y);
    float vin = (1.0 - ((1.0 - saturate(pos.x * pos.x)) * (1.0 - saturate(pos.y * pos.y))))
        * (0.998 + (0.001 * p.CORNER));
    vin = saturate((-vin) * inputHeight + inputHeight);
    pos = pos * halfInputSize + halfInputSize;

    float y0 = floor(pos.y - 0.5) + 0.5;
    pos.x += 0.5;
    float xi = floor(pos.x);
    float xf = pos.x - xi;
    xf = xf * xf * xf * (xf * (xf * 6.0 - 15.0) + 10.0);
    float x0 = xi + xf - 0.5;
    float2 q = float2(x0 * rcpInputSize.x, y0 * rcpInputSize.y);
    float3 colA = fromSrgb(source.sample(s, q, level(0)).rgb, p.CRT_GAMMA);
    q.y += rcpInputSize.y;
    float3 colB = fromSrgb(source.sample(s, q, level(0)).rgb, p.CRT_GAMMA);

    float off = pos.y - y0;
    const float pi2 = 6.28318530717958;
    float scanA = cos(min(0.5, off * thin) * pi2) * 0.5 + 0.5;
    float scanB = cos(min(0.5, (-off) * thin + thin) * pi2) * 0.5 + 0.5;
    scanA *= vin;
    scanB *= vin;
    float3 color = (colA * scanA) + (colB * scanB);
    color *= crtsMask(ipos, mask, p.MASK);

    float peak = max(1.0 / (256.0 * 65536.0), max(color.r, max(color.g, color.b)));
    float3 ratio = color * (1.0 / peak);
    peak = pow(peak, tone.x);
    peak = peak * (1.0 / (peak * tone.y + tone.z));
    ratio = pow(ratio, float3(tone.w));

    return float4(toSrgb(ratio * peak), 1.0);
}
