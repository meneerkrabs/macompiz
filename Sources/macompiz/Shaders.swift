import simd

// Shared CPU/GPU uniform layouts. Field order & padding must match the
// Metal structs in `metalSource` below exactly.

struct WindowUniforms {
    var grabPoint: SIMD2<Float> = .zero   // uv 0..1 of the grab/drag anchor
    var grabVel:   SIMD2<Float> = .zero   // uv/sec, clamped
    var grabActive: Float = 0
    var time: Float = 0                    // seconds since the effect started
    var burn: Float = 0                    // 0 = intact, 1 = fully burned away
    var aspect: Float = 1                  // width / height
    var rippleCount: Float = 0
    var _pad0: Float = 0
    var ripples: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                  SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
}

struct CubeUniforms {
    var mvp: float4x4 = matrix_identity_float4x4
    var dim: Float = 1          // dimming for side faces
    var _pad: SIMD3<Float> = .zero
}

// Compiled at runtime via device.makeLibrary(source:), so no `metal`
// command-line tool / full Xcode install is required.
let metalSource = """
#include <metal_stdlib>
using namespace metal;

struct WindowUniforms {
    float2 grabPoint;
    float2 grabVel;
    float  grabActive;
    float  time;
    float  burn;
    float  aspect;
    float  rippleCount;
    float  _pad0;
    float4 ripples[8];
};

struct CubeUniforms {
    float4x4 mvp;
    float    dim;
    float3   _pad;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

// ---- value noise / fbm for the burn front ----------------------------------
static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 34.56);
    return fract(p.x * p.y);
}
static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash(i);
    float b = hash(i + float2(1,0));
    float c = hash(i + float2(0,1));
    float d = hash(i + float2(1,1));
    float2 u = f*f*(3.0-2.0*f);
    return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
}
static float fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i=0;i<5;i++){ v += amp*vnoise(p); p*=2.0; amp*=0.5; }
    return v;
}

// ===== window effects: deformable grid + burn/water =========================
vertex VOut window_vertex(const device float2* grid [[buffer(0)]],
                          constant WindowUniforms& u [[buffer(1)]],
                          uint vid [[vertex_id]]) {
    float2 uv = grid[vid];
    float2 p = uv;

    if (u.grabActive > 0.5) {
        // Body lags behind the cursor -> jelly "wobbly windows".
        float d = distance(uv, u.grabPoint);
        float w = smoothstep(0.0, 1.3, d);
        float wob = sin(u.time * 16.0 - d * 7.0);
        float2 lag = -u.grabVel * (0.5 * w);
        float2 osc =  u.grabVel * (0.18 * w * wob);
        p += lag + osc;
    }

    VOut o;
    o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
    o.uv = uv;
    return o;
}

fragment float4 window_fragment(VOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                constant WindowUniforms& u [[buffer(1)]]) {
    float2 uv = in.uv;

    // water ripples displace the sample coordinate
    int n = int(u.rippleCount);
    for (int i = 0; i < n && i < 8; i++) {
        float4 r = u.ripples[i];
        if (r.w < 0.5) continue;
        float age = u.time - r.z;
        if (age < 0.0) continue;
        float2 d = (uv - r.xy); d.x *= u.aspect;
        float dist = length(d);
        float wave = sin(dist * 42.0 - age * 11.0)
                   * exp(-age * 2.4) * exp(-dist * 4.5);
        uv += normalize(uv - r.xy + 1e-5) * wave * 0.022;
    }

    float4 col = tex.sample(smp, uv);

    // burn: a noisy front sweeps bottom -> top, charring then clearing
    if (u.burn > 0.001) {
        float n2 = fbm(in.uv * float2(9.0, 14.0));
        float threshold = (1.0 - in.uv.y) * 0.72 + n2 * 0.30;
        float front = u.burn * 1.35;
        if (threshold < front - 0.06) {
            col.a = 0.0;                                   // burned away
        } else if (threshold < front) {
            float g = (front - threshold) / 0.06;          // 0..1 edge
            float3 fire = mix(float3(1.0,0.85,0.2),
                              float3(0.9,0.15,0.02), g);
            col.rgb = mix(col.rgb, fire, 0.85);
            col.a = 1.0;
        }
    }
    return col;
}

// ===== cube: textured quads with an MVP ====================================
vertex VOut cube_vertex(const device float4* verts [[buffer(0)]],
                        constant CubeUniforms& u [[buffer(1)]],
                        uint vid [[vertex_id]]) {
    float4 v = verts[vid];               // xyz in face-local [-0.5,0.5], w unused
    VOut o;
    o.pos = u.mvp * float4(v.xyz, 1.0);
    o.uv  = float2(v.x + 0.5, 0.5 - v.y);
    return o;
}

fragment float4 cube_fragment(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              constant CubeUniforms& u [[buffer(1)]]) {
    float4 c = tex.sample(smp, in.uv);
    c.rgb *= u.dim;
    return c;
}
"""
