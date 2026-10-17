//  VisualizerNCS.metal
//  NCS Spectrum（Roonil/NCS_Spectrum_GLava）の反応炉。本人の ncs_gl.py（GLava の 3 つの描きの 1 対 1 の移植）を
//  Metal に写したもので、定数・ノイズ・描きの順・色は ncs_gl.py のまま。
//
//  1 回目: 粒の格子を 4 次元 Perlin の fbm でずらし、羽毛つきの球に射影して、密度に足し込む（加算ブレンド）。
//  2 回目: 密度 → 色（ncs/2.frag）。
//  3 回目: 放射状の光彩とトーンカーブ（ncs/3.frag）。
//
//  音は CPU で作った finalAudio と audioRadius を渡す（ETNCSAudio）。時刻は CPU 側で 289 の余りにした
//  flow·uTime を渡す（cnoise は mod289(floor(P)) と fract(P) だけで決まるので 289 を足し引きしても同じ）。

#include <metal_stdlib>
using namespace metal;

// Swift の NCSUniforms と同じ並び（96 バイト）。
struct NCSUniforms {
    float4 flow0, flow1, flow2;   // ETNCSGeometry.flowOffsets
    float4 color;                 // rgb 0..1
    float2 screen;                // (renderSide, renderSide)
    float finalAudio, audioRadius, scale, spacing, densityScale;
    uint gridN;
};

// ncs_gl.py の _CONSTS（そのまま）。flow の定数は CPU 側だけが持つ。
constant int   complexity   = 3;
constant float octaveMultiplier = 0.25;
constant float octaveScale  = 1.0;
constant float fScale       = 4.6;
constant float gamma        = 1.0;
constant float minVal       = -5.0;
constant float maxVal       = 5.0;
constant float noiseOffset  = 0.0;
constant float noiseMultiplier = 1.0;
constant float sphereRadius = 275.0;
constant float feather      = 0.45;
constant float antiAlias    = 5.0;
constant float particleSize = 3.0;
constant float displaceX    = 110.0;
constant float displaceY    = 95.0;
constant float displaceZ    = 115.0;
constant float radiusAudioMultiplier = 200.0;

// --- 4 次元 Perlin（ncs/1.frag の cnoise。mod289 の非周期の形） ----------------------

float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 permute(float4 x) { return mod289(((x * 34.0) + 1.0) * x); }
float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
float4 fade(float4 t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

float cnoise(float4 P) {
    float4 Pi0 = mod289(floor(P));
    float4 Pi1 = mod289(Pi0 + 1.0);
    float4 Pf0 = fract(P);
    float4 Pf1 = Pf0 - 1.0;
    float4 ix = float4(Pi0.x, Pi1.x, Pi0.x, Pi1.x);
    float4 iy = float4(Pi0.yy, Pi1.yy);
    float4 iz0 = float4(Pi0.zzzz);
    float4 iz1 = float4(Pi1.zzzz);
    float4 iw0 = float4(Pi0.wwww);
    float4 iw1 = float4(Pi1.wwww);

    float4 ixy = permute(permute(ix) + iy);
    float4 ixy0 = permute(ixy + iz0);
    float4 ixy1 = permute(ixy + iz1);
    float4 ixy00 = permute(ixy0 + iw0);
    float4 ixy01 = permute(ixy0 + iw1);
    float4 ixy10 = permute(ixy1 + iw0);
    float4 ixy11 = permute(ixy1 + iw1);

    float4 gx00 = ixy00 / 7.0;
    float4 gy00 = floor(gx00) / 7.0;
    float4 gz00 = floor(gy00) / 6.0;
    gx00 = fract(gx00) - 0.5; gy00 = fract(gy00) - 0.5; gz00 = fract(gz00) - 0.5;
    float4 gw00 = float4(0.75) - abs(gx00) - abs(gy00) - abs(gz00);
    float4 sw00 = step(gw00, float4(0.0));
    gx00 -= sw00 * (step(float4(0.0), gx00) - 0.5);
    gy00 -= sw00 * (step(float4(0.0), gy00) - 0.5);

    float4 gx01 = ixy01 / 7.0;
    float4 gy01 = floor(gx01) / 7.0;
    float4 gz01 = floor(gy01) / 6.0;
    gx01 = fract(gx01) - 0.5; gy01 = fract(gy01) - 0.5; gz01 = fract(gz01) - 0.5;
    float4 gw01 = float4(0.75) - abs(gx01) - abs(gy01) - abs(gz01);
    float4 sw01 = step(gw01, float4(0.0));
    gx01 -= sw01 * (step(float4(0.0), gx01) - 0.5);
    gy01 -= sw01 * (step(float4(0.0), gy01) - 0.5);

    float4 gx10 = ixy10 / 7.0;
    float4 gy10 = floor(gx10) / 7.0;
    float4 gz10 = floor(gy10) / 6.0;
    gx10 = fract(gx10) - 0.5; gy10 = fract(gy10) - 0.5; gz10 = fract(gz10) - 0.5;
    float4 gw10 = float4(0.75) - abs(gx10) - abs(gy10) - abs(gz10);
    float4 sw10 = step(gw10, float4(0.0));
    gx10 -= sw10 * (step(float4(0.0), gx10) - 0.5);
    gy10 -= sw10 * (step(float4(0.0), gy10) - 0.5);

    float4 gx11 = ixy11 / 7.0;
    float4 gy11 = floor(gx11) / 7.0;
    float4 gz11 = floor(gy11) / 6.0;
    gx11 = fract(gx11) - 0.5; gy11 = fract(gy11) - 0.5; gz11 = fract(gz11) - 0.5;
    float4 gw11 = float4(0.75) - abs(gx11) - abs(gy11) - abs(gz11);
    float4 sw11 = step(gw11, float4(0.0));
    gx11 -= sw11 * (step(float4(0.0), gx11) - 0.5);
    gy11 -= sw11 * (step(float4(0.0), gy11) - 0.5);

    float4 g0000 = float4(gx00.x, gy00.x, gz00.x, gw00.x);
    float4 g1000 = float4(gx00.y, gy00.y, gz00.y, gw00.y);
    float4 g0100 = float4(gx00.z, gy00.z, gz00.z, gw00.z);
    float4 g1100 = float4(gx00.w, gy00.w, gz00.w, gw00.w);
    float4 g0010 = float4(gx10.x, gy10.x, gz10.x, gw10.x);
    float4 g1010 = float4(gx10.y, gy10.y, gz10.y, gw10.y);
    float4 g0110 = float4(gx10.z, gy10.z, gz10.z, gw10.z);
    float4 g1110 = float4(gx10.w, gy10.w, gz10.w, gw10.w);
    float4 g0001 = float4(gx01.x, gy01.x, gz01.x, gw01.x);
    float4 g1001 = float4(gx01.y, gy01.y, gz01.y, gw01.y);
    float4 g0101 = float4(gx01.z, gy01.z, gz01.z, gw01.z);
    float4 g1101 = float4(gx01.w, gy01.w, gz01.w, gw01.w);
    float4 g0011 = float4(gx11.x, gy11.x, gz11.x, gw11.x);
    float4 g1011 = float4(gx11.y, gy11.y, gz11.y, gw11.y);
    float4 g0111 = float4(gx11.z, gy11.z, gz11.z, gw11.z);
    float4 g1111 = float4(gx11.w, gy11.w, gz11.w, gw11.w);

    float4 norm00 = taylorInvSqrt(float4(dot(g0000, g0000), dot(g0100, g0100), dot(g1000, g1000), dot(g1100, g1100)));
    g0000 *= norm00.x; g0100 *= norm00.y; g1000 *= norm00.z; g1100 *= norm00.w;
    float4 norm01 = taylorInvSqrt(float4(dot(g0001, g0001), dot(g0101, g0101), dot(g1001, g1001), dot(g1101, g1101)));
    g0001 *= norm01.x; g0101 *= norm01.y; g1001 *= norm01.z; g1101 *= norm01.w;
    float4 norm10 = taylorInvSqrt(float4(dot(g0010, g0010), dot(g0110, g0110), dot(g1010, g1010), dot(g1110, g1110)));
    g0010 *= norm10.x; g0110 *= norm10.y; g1010 *= norm10.z; g1110 *= norm10.w;
    float4 norm11 = taylorInvSqrt(float4(dot(g0011, g0011), dot(g0111, g0111), dot(g1011, g1011), dot(g1111, g1111)));
    g0011 *= norm11.x; g0111 *= norm11.y; g1011 *= norm11.z; g1111 *= norm11.w;

    float n0000 = dot(g0000, Pf0);
    float n1000 = dot(g1000, float4(Pf1.x, Pf0.yzw));
    float n0100 = dot(g0100, float4(Pf0.x, Pf1.y, Pf0.zw));
    float n1100 = dot(g1100, float4(Pf1.xy, Pf0.zw));
    float n0010 = dot(g0010, float4(Pf0.xy, Pf1.z, Pf0.w));
    float n1010 = dot(g1010, float4(Pf1.x, Pf0.y, Pf1.z, Pf0.w));
    float n0110 = dot(g0110, float4(Pf0.x, Pf1.yz, Pf0.w));
    float n1110 = dot(g1110, float4(Pf1.xyz, Pf0.w));
    float n0001 = dot(g0001, float4(Pf0.xyz, Pf1.w));
    float n1001 = dot(g1001, float4(Pf1.x, Pf0.yz, Pf1.w));
    float n0101 = dot(g0101, float4(Pf0.x, Pf1.y, Pf0.z, Pf1.w));
    float n1101 = dot(g1101, float4(Pf1.xy, Pf0.z, Pf1.w));
    float n0011 = dot(g0011, float4(Pf0.xy, Pf1.zw));
    float n1011 = dot(g1011, float4(Pf1.x, Pf0.y, Pf1.zw));
    float n0111 = dot(g0111, float4(Pf0.x, Pf1.yzw));
    float n1111 = dot(g1111, Pf1);

    float4 fade_xyzw = fade(Pf0);
    float4 n_0w = mix(float4(n0000, n1000, n0100, n1100), float4(n0001, n1001, n0101, n1101), float4(fade_xyzw.w));
    float4 n_1w = mix(float4(n0010, n1010, n0110, n1110), float4(n0011, n1011, n0111, n1111), float4(fade_xyzw.w));
    float4 n_zw = mix(n_0w, n_1w, float4(fade_xyzw.z));
    float2 n_yzw = mix(n_zw.xy, n_zw.zw, float2(fade_xyzw.y));
    float n_xyzw = mix(n_yzw.x, n_yzw.y, fade_xyzw.x);
    return 2.2 * n_xyzw;
}

// octaveScale == 1 なので 3 つのオクターブとも同じ点を引く。GLSL の value/total は
// cnoise(p + flow·t)·(1 + 0.25 + 0.0625) / (1 + 0.25 + 0.0625) = cnoise(p + flow·t) と等しいので 1 回で済ませる。
// flow·t は CPU 側で 289 の余りにして足し済み（off）。
float octaveNoise(float4 p, float4 off) {
    return cnoise(p + off);
}

float fbm3(float4 p, float disp, float4 off, constant NCSUniforms& u) {
    float oN = u.finalAudio * octaveNoise(fScale * (p - float4(u.screen * 0.5, 0.0, 0.0)) / u.screen.x, off);
    oN = clamp(oN, minVal, maxVal);
    if (oN >= 0.0) oN = pow(oN, gamma); else oN = -pow(-oN, gamma);
    return disp * (noiseOffset + noiseMultiplier * oN);
}

// --- 1 回目: 粒 → 密度 --------------------------------------------------------------

struct P1Out {
    float4 position [[position]];
    float pointSize [[point_size]];
    float bright;
};

vertex P1Out ncsParticles(uint vid [[vertex_id]], constant NCSUniforms& u [[buffer(0)]]) {
    // arange(0.5, res, spacing) の格子
    float2 grid = float2(float(vid % u.gridN), float(vid / u.gridN)) * u.spacing + 0.5;
    float3 particleCoords = float3(grid, 0.0);
    float4 old = float4(particleCoords, 0.0);

    particleCoords += u.scale * float3(
        fbm3(old.xyzw, displaceX, u.flow0, u),
        fbm3(old.yzxw, displaceY, u.flow1, u),
        fbm3(old.zxyw, displaceZ, u.flow2, u));

    float radius = (sphereRadius + radiusAudioMultiplier * abs(u.audioRadius)) * u.scale;
    float blurSize = antiAlias / u.screen.y;
    // 羽毛の外の薄い霞（radius·1.10 + 24）と点の大きさまで、この正方形の中に収める
    radius = min(radius, (u.screen.y * 0.5 - 30.0) / 1.10);

    float3 center = float3(u.screen * 0.5, 0.0);
    float3 dvec = particleCoords - center;
    float dlen = length(dvec);
    if (dlen <= radius && dlen > 1e-5) {
        float3 dir = dvec / dlen;
        float3 newPos = center + radius * dir;
        float diff = length(newPos - particleCoords);
        diff *= clamp(smoothstep(0.0, feather * radius, diff) + blurSize, blurSize, 1.0 + blurSize);
        particleCoords += diff * dir;
    }

    // 画面いっぱいの格子（外の霞）だけを遠くで薄くする。殻と殻の近くの筋は触らない
    float bright = 1.0 - smoothstep(radius, radius * 1.10 + 24.0, dlen);

    P1Out out;
    out.position = float4((particleCoords.xy / u.screen) * 2.0 - 1.0, 0.0, 1.0);
    out.pointSize = particleSize * 2.0 + 1.0;
    out.bright = bright;
    return out;
}

// 重みは中心について対称なので、point_coord の y の向きは効かない
fragment float ncsDensity(P1Out in [[stage_in]], float2 pointCoord [[point_coord]]) {
    float2 ij = (pointCoord - float2(0.5)) * (particleSize * 2.0 + 1.0);
    float dist = length(ij);
    float weight = (1.0 - smoothstep(0.0, particleSize, dist)) * particleSize;
    return floor(weight + 1e-4) * in.bright;
}

// --- 全画面の三角形 -----------------------------------------------------------------

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

// Metal のテクスチャは左上が原点。uv は GL の vUV と同じ向きの絵になる
// （ncs_gl.py が最後に [::-1] で返す向きと同じ）。
vertex QuadOut ncsQuad(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
    QuadOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x + 1.0, 1.0 - p.y) * 0.5;
    return out;
}

// --- 2 回目: 密度 → 色 --------------------------------------------------------------

constant float opacity = 0.05;
constant float colorIntensityAddStrength = 0.2;

fragment float4 ncsColor(QuadOut in [[stage_in]],
                         texture2d<float> densityTex [[texture(0)]],
                         sampler smp [[sampler(0)]],
                         constant NCSUniforms& u [[buffer(0)]]) {
    float depth = densityTex.sample(smp, in.uv).r * u.densityScale;
    if (depth > 0.0001) {
        float dps = depth / particleSize;
        float s = (pow(dps, colorIntensityAddStrength) - colorIntensityAddStrength)
                  * (1.0 - pow(1.0 - opacity, dps));
        s = max(s, 0.0);
        return float4(u.color.rgb * s, s);
    }
    return float4(0.0);
}

// --- 3 回目: 光彩とトーン -----------------------------------------------------------

constant float glowSize = 10.0;
constant float glowIntensity = 0.5;
constant float twoPi = 6.28318530718;

// 暗い画素で 0.92 + 0.92/sqrt(L) が発散しないよう挟んだトーンカーブ
float tone(float value, float strength, float dist) {
    return clamp(dist + dist / pow(max(value, 1e-4), strength), 0.0, 1.0);
}

fragment float4 ncsGlow(QuadOut in [[stage_in]],
                        texture2d<float> prevTex [[texture(0)]],
                        sampler smp [[sampler(0)]],
                        constant NCSUniforms& u [[buffer(0)]]) {
    float2 radius = glowSize / u.screen;
    float4 Color = float4(0.0);
    float4 prevColor = prevTex.sample(smp, in.uv, level(0));
    // GLSL の float のループ（16 方向 × 6 段）と同じ回数を整数で回す
    for (int di = 0; di < 16; di++) {
        float d = float(di) * twoPi / 16.0;
        for (int qi = 1; qi <= 6; qi++) {
            float i = float(qi) / 6.0;
            float2 coords = in.uv + radius * i * float2(cos(d), sin(d));
            if (coords.x > 0.0 && coords.x < 1.0 && coords.y > 0.0 && coords.y < 1.0) {
                Color += prevTex.sample(smp, coords, level(0));
            }
        }
    }
    Color /= 96.0;

    // premultiplied を守る: rgb <= alpha、alpha == 0 なら rgb == 0
    float a = clamp(max(prevColor.a, Color.a * glowIntensity), 0.0, 1.0);
    float3 rgb = prevColor.rgb + u.color.rgb * (Color.a * glowIntensity);
    float L = length(rgb);
    rgb *= (L > 0.0025) ? tone(L, 0.5, 0.92) : 0.0;
    return float4(min(rgb, float3(a)), a);
}
