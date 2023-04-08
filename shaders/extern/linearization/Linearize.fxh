#pragma once

// SPDX-License-Identifier: Unlicense
#include "ReShade.fxh"
#include "SRGB.fxh"
#include "PQ.fxh"

// only if we are in 8-bit SRGB do hardware linearization.
sampler2D BackBufferLinear
{
    Texture = ReShade::BackBufferTex;
    SRGBTexture = _SRGB;
};

float4 GetBackBuffer(float2 texcoord)
{
    float4 c = tex2D(BackBufferLinear, texcoord.xy);

    // non 8-bit SRGB, means we have to handle linearization ourselves.
#   if (BUFFER_COLOR_SPACE == 1 && BUFFER_COLOR_BIT_DEPTH != 8)
    return SRGBToLinear(c);
#   elif (_PQ)
    return PQToLinear(c);
#   else
    return c;
#   endif
}

// This relies on *you* setting `SRGBWriteEnable` in your pass.
float4 DisplayBackBuffer(float4 color)
{
#   if (BUFFER_COLOR_SPACE == 1 && BUFFER_COLOR_BIT_DEPTH != 8)
    return LinearToSRGB(color);
#   elif (_PQ)
    return LinearToPQ(color);
#   else
    return color;
#   endif
}

float3 DisplayBackBuffer(float3 color)
{
    return DisplayBackBuffer(float4(color, 1.0)).rgb;
}

/**
 * Implementation notes.
 *
 * Make sure your passes look something like this:
 * ```
 * pass
 * {
 *     PixelShader = PS_Main;
 *     VertexShader = PostProcessVS;
 *     SRGBWriteEnable = _SRGB; // This part is most important.
 * }
 * ```
 *
 * ReShade will handle writing to RGBA8 SRGB targets with low overhead.
 *
 * Replace any appearances of `tex2D(ReShade::BackBuffer, texcoord.xy)` with `GetBackBuffer(texcoord.xy)`
 * This will ensure the backbuffer is linear before you use it.
 */
