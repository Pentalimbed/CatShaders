#pragma once

// SPDX-License-Identifier: Unlicense
#include "ReShade.fxh"

#ifndef _SRGB
#define _SRGB (BUFFER_COLOR_SPACE == 1 && BUFFER_COLOR_BIT_DEPTH == 8)
#endif



// marty found this, need to ask this where it came from.
float3 SRGBToLinear(in float3 srgb)
{
    return pow(srgb * 0.947867 + 0.052132685, 2.4) - saturate(0.00081 - srgb * 0.0283);
    // return (srgb < 0.04045) ? srgb / 12.92 : pow(abs((srgb + 0.055) / 1.055), 2.4);
}

float4 SRGBToLinear(in float4 srgb)
{
    return float4(SRGBToLinear(srgb.rgb), srgb.a);
}

float3 LinearToSRGB(in float3 lin)
{
    return (lin < 0.0031308) ? 12.92 * lin : 1.055 * pow(abs(lin), 0.41666666) - 0.055;
}

float4 LinearToSRGB(in float4 lin)
{
    return float4(LinearToSRGB(lin.rgb), lin.a);
}
