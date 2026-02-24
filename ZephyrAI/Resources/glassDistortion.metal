#include <metal_stdlib>
using namespace metal;

#include <SwiftUI/SwiftUI_Metal.h>

[[ stitchable ]]
float2 glassDistortion(
    float2 position,
    float2 size,
    float time
) {
    float2 uv = position / size;

    // Centered coords (-0.5 .. 0.5)
    float2 centered = uv - 0.5;

    float dist = length(centered);

    // Primary flowing waves
    float waveA = sin((uv.y + time * 0.6) * 22.0) * 0.007;
    float waveB = cos((uv.x + time * 0.5) * 18.0) * 0.007;

    // Secondary micro ripples
    float ripple =
        sin((uv.x + uv.y + time) * 40.0) * 0.003;

    // Soft noise blur (pseudo gaussian jitter)
    float blurX =
        sin((uv.x + time) * 120.0) * 0.0015;
    float blurY =
        cos((uv.y + time) * 110.0) * 0.0015;

    float2 blur = float2(blurX, blurY);

    // Radial lens distortion
    float lens = smoothstep(0.7, 0.0, dist) * 0.02;

    // Flow field
    float2 flow = float2(
        waveA + ripple,
        waveB - ripple
    );

    // Final offset with blur
    float2 offset =
        flow * 22.0 +
        centered * lens * 35.0 +
        blur * 14.0;

    return offset;
}
