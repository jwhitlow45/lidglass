/// Metal source compiled at runtime. The command line tools ship no offline Metal
/// compiler, and a one-file shader costs a few milliseconds to build at launch.
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float theta;
    float perspective;
    float progress;
    float strength;

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
    float hingeAtTop;
    float gloss;
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

    // Tip the pane about the hinge. Depth goes in w rather than being divided out here:
    // the GPU then divides by it itself and maps the texture perspective-correctly.
    // Dividing here leaves each of the quad's two triangles mapped flat, and the image
    // kinks along the diagonal where they meet.
    float side = u.hingeAtTop > 0.5 ? -1.0 : 1.0;
    float hinged = 1.0 + side * corner.y;
    float y = side * (hinged * cos(u.theta) - 1.0);
    float depth = hinged * sin(u.theta);
    out.position = float4(corner.x, y, 0.0, (u.perspective + depth) / u.perspective);
    return out;
}

static float3 tap(texture2d<float> src, sampler smp, float2 uv, float lod, float2 shift) {
    if (all(shift == 0.0)) {
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
        // Opaque from the first moment the glass shows. Any see-through lets the real screen,
        // menu bar and all, show as a second copy in the gap the tilting pane opens.
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // 0 along the hinge, 1 along the free edge: frost and sheen grow toward the free edge.
    float fromHinge = u.hingeAtTop > 0.5 ? in.uv.y : 1.0 - in.uv.y;
    // Full frost by about a third of the way closed, so a partly closed lid already shows
    // the material rather than a faint version of it.
    float frostAmount = u.strength * smoothstep(0.0, 0.35, u.progress) * mix(u.frostBottom, u.frostTop, fromHinge);

    float2 pixel = in.uv * float2(u.texWidth, u.texHeight);
    float2 texel = float2(1.0 / u.texWidth, 1.0 / u.texHeight);
    // Grain comes in cells of grainScale pixels, so it stays visible on a Retina display.
    float2 cell = floor(pixel / max(u.grainScale, 1.0));
    float grain = hash21(cell);
    float grainB = hash21(cell.yx + 19.37);

    // Each pixel gathers a spiral of taps, and each tap reads a prefiltered mip, so a
    // handful of taps covers a wide radius without blocky smearing. Scatter randomizes the
    // spiral's turn and reach per grain cell: none gives a smooth blur, full scatter gives
    // the sandblasted look of etched glass.
    float scatter = saturate(u.scatter);
    float radius = u.blurRadius * frostAmount * mix(1.0, grainB * 2.0, scatter);
    float lod = clamp(log2(max(radius, 1.0) / 2.0), 0.0, u.maxLod);
    // Color splits outward from the middle of the pane, like light through a prism.
    float2 shift = (in.uv - 0.5) * 2.0 * u.chroma * frostAmount * texel;
    float3 color;
    if (radius < 0.5) {
        color = tap(src, smp, in.uv, 0.0, shift);
    } else {
        const int taps = 8;
        float3 sum = float3(0.0);
        for (int i = 0; i < taps; i++) {
            float t = (float(i) + 0.5) / float(taps);
            float a = grain * 6.2831853 * scatter + float(i) * 2.3999632;
            float2 offset = float2(cos(a), sin(a)) * sqrt(t) * radius * texel;
            sum += tap(src, smp, in.uv + offset, lod, shift);
        }
        color = sum / float(taps);
    }

    color += (grain - 0.5) * u.grainStrength * frostAmount;
    color = mix(color, float3(u.tintR, u.tintG, u.tintB), u.tintStrength * frostAmount);
    color += u.strength * u.sheen * sin(u.theta) * smoothstep(0.0, 1.0, fromHinge);
    // A glossy band of reflected light, slanted across the pane, that sweeps from the free
    // edge toward the hinge as the pane tips back.
    float band = fromHinge - (1.0 - u.progress) + (in.uv.x - 0.5) * 0.3;
    color += u.strength * u.gloss * sin(u.theta) * exp(-band * band * 70.0);

    // Rounded rect mask, measured in captured pixels so the radius matches the display.
    // The pane starts as an exact copy of the screen, square corners and hard edges, and
    // takes on its rounded, softened edge over the first stretch of the fold. Otherwise
    // the corners and edges snap as the glass takes over from the real screen.
    float edgeIn = smoothstep(0.0, 0.1, u.progress);
    float2 halfSize = float2(u.texWidth, u.texHeight) * 0.5;
    float cornerRadius = min(u.cornerRadius * edgeIn, min(halfSize.x, halfSize.y));
    float2 d = abs(pixel - halfSize) - (halfSize - cornerRadius);
    float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - cornerRadius;
    float mask = saturate(0.5 - dist / max(u.edgeSoftness * edgeIn, 0.5));

    // Strength scales everything the effect adds, so at zero every effect is the bare fold.
    float alpha = mask * mix(1.0, u.paneAlpha, u.progress * u.strength);
    return float4(saturate(color) * alpha, alpha);
}
"""#
