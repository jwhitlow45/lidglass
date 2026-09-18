/// Metal source compiled at runtime. The command line tools ship no offline Metal
/// compiler, and a one-file shader costs a few milliseconds to build at launch.
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float theta;
    float perspective;
    float progress;
    float frost;

    float frostTop;
    float frostBottom;
    float grainScale;
    float grainStrength;

    float scatter;
    float sheen;
    float chroma;
    float cornerRadius;

    float edgeSoftness;
    float paneAlpha;
    float blurRadius;
    float texWidth;

    float texHeight;
    float tintR;
    float tintG;
    float tintB;

    float tintStrength;
    float maxLod;
    float isBackground;
    float pad;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

static float hash21(float2 p) {
    p = fract(p * float2(127.319, 311.703));
    p += dot(p, p + 42.137);
    return fract(p.x * p.y);
}

vertex VertexOut glassVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    // Triangle strip over the pane in local space, hinge along the bottom edge (y = -1).
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    VertexOut out;
    out.uv = float2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5);

    if (u.isBackground > 0.5) {
        out.position = float4(corner, 0.0, 1.0);
        return out;
    }

    // Tip the pane about the hinge, then divide by depth so the far edge narrows.
    float hinged = corner.y + 1.0;
    float y = -1.0 + hinged * cos(u.theta);
    float depth = hinged * sin(u.theta);
    float scale = u.perspective / (u.perspective + depth);
    out.position = float4(corner.x * scale, y * scale, 0.0, 1.0);
    return out;
}

static float3 tap(texture2d<float> src, sampler smp, float2 uv, float lod, float2 shift) {
    if (shift.x == 0.0) {
        return src.sample(smp, uv, level(lod)).rgb;
    }
    return float3(src.sample(smp, uv + shift, level(lod)).r,
                  src.sample(smp, uv, level(lod)).g,
                  src.sample(smp, uv - shift, level(lod)).b);
}

fragment float4 glassFragment(VertexOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);

    if (u.isBackground > 0.5) {
        // Opaque early so the real desktop never shows as a second image behind the pane.
        return float4(0.0, 0.0, 0.0, smoothstep(0.0, 0.15, u.progress));
    }

    float fromTop = 1.0 - in.uv.y;
    float frostAmount = saturate(u.frost * u.progress) * mix(u.frostBottom, u.frostTop, fromTop);

    float2 pixel = in.uv * float2(u.texWidth, u.texHeight);
    float2 texel = float2(1.0 / u.texWidth, 1.0 / u.texHeight);
    float grain = hash21(pixel / max(u.grainScale, 0.5));
    float grainB = hash21(pixel.yx / max(u.grainScale, 0.5) + 19.37);

    // Etched glass scatters light: each pixel gathers a spiral of taps whose rotation
    // and reach are randomised by the grain, and each tap reads a prefiltered mip so a
    // handful of taps covers a wide radius without blocky smearing.
    float radius = u.blurRadius * frostAmount * mix(1.0, grainB * 2.0, saturate(u.scatter));
    float lod = min(max(log2(max(radius, 1.0) / 3.0), 0.0), u.maxLod);
    float2 shift = float2(u.chroma * frostAmount * texel.x * (1.0 + lod * 2.0), 0.0);
    float3 color;
    if (radius < 0.5) {
        color = tap(src, smp, in.uv, 0.0, shift);
    } else {
        const int taps = 8;
        float3 sum = float3(0.0);
        for (int i = 0; i < taps; i++) {
            float t = (float(i) + 0.5) / float(taps);
            float a = grain * 6.2831853 + float(i) * 2.3999632;
            float2 offset = float2(cos(a), sin(a)) * sqrt(t) * radius * texel;
            sum += tap(src, smp, in.uv + offset, lod, shift);
        }
        color = sum / float(taps);
    }

    color += (grain - 0.5) * u.grainStrength * frostAmount;
    color = mix(color, float3(u.tintR, u.tintG, u.tintB), u.tintStrength * frostAmount);
    color += u.sheen * sin(u.theta) * smoothstep(0.0, 1.0, fromTop);

    // Rounded rect mask, measured in captured pixels so the radius matches the display.
    float2 halfSize = float2(u.texWidth, u.texHeight) * 0.5;
    float cornerRadius = min(u.cornerRadius, min(halfSize.x, halfSize.y));
    float2 d = abs(pixel - halfSize) - (halfSize - cornerRadius);
    float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - cornerRadius;
    float mask = saturate(0.5 - dist / max(u.edgeSoftness, 0.5));

    float alpha = mask * mix(1.0, u.paneAlpha, u.progress);
    return float4(saturate(color) * alpha, alpha);
}
"""#
