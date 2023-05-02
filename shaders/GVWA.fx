/*
    Edge-aware filter based on adaptive patch variance weighted average
    https://ieeexplore.ieee.org/ielx7/6287639/6514899/09521149.pdf
*/

#include "ReShade.fxh"

#define TERNARY(cond, a, b) ((cond) * (a) + !(cond) * (b))

#define LOG_1(n) ((n) >= 2)
#define LOG_2(n) TERNARY(((n) >= 1<<2), (2 + LOG_1((n)>>2)), LOG_1(n))
#define LOG_4(n) TERNARY(((n) >= 1<<4), (4 + LOG_2((n)>>4)), LOG_2(n))
#define LOG_8(n) TERNARY(((n) >= 1<<8), (8 + LOG_4((n)>>8)), LOG_4(n))
#define LOG(n)   TERNARY(((n) >= 1<<16), (16 + LOG_8((n)>>16)), LOG_8(n))

#define GVWA_MEAN_MIP LOG(TERNARY(BUFFER_WIDTH > BUFFER_HEIGHT, BUFFER_WIDTH, BUFFER_HEIGHT))

namespace GVWA
{
uniform float fSigmaS <
    ui_label = "Sigma";
    ui_type = "slider";
    ui_min = 0.1; ui_max = 4.0;
    ui_step = 0.1;
> = 1.0;

uniform float fScale <
    ui_label = "Scale";
    ui_type = "slider";
    ui_min = 0.01; ui_max = 1.0;
    ui_step = 0.01;
> = 0.01;

uniform float fMixDetail <
    ui_label = "Detail";
    ui_type = "slider";
    ui_min = 0.00; ui_max = 2.0;
    ui_step = 0.1;
> = 0.00;

sampler2D samp_color {Texture = ReShade::BackBufferTex; AddressU = MIRROR; AddressV = MIRROR;};

texture2D tex_mean  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F;};
sampler2D samp_mean {Texture = tex_mean; AddressU = MIRROR; AddressV = MIRROR;};
texture2D tex_mean_sqr  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F;};
sampler2D samp_mean_sqr {Texture = tex_mean_sqr; AddressU = MIRROR; AddressV = MIRROR;};

texture2D tex_var  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; MipLevels = GVWA_MEAN_MIP + 1;};
sampler2D samp_var {Texture = tex_var; AddressU = MIRROR; AddressV = MIRROR;};

texture2D tex_weight  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F;};
sampler2D samp_weight {Texture = tex_weight; AddressU = MIRROR; AddressV = MIRROR;};

texture2D tex_normfactor_0  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F;};
sampler2D samp_normfactor_0 {Texture = tex_normfactor_0; AddressU = MIRROR; AddressV = MIRROR;};
texture2D tex_normfactor_1  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F;};
sampler2D samp_normfactor_1 {Texture = tex_normfactor_1;};

texture2D tex_filter_0  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F;};
sampler2D samp_filter_0 {Texture = tex_filter_0; AddressU = MIRROR; AddressV = MIRROR;};
texture2D tex_filter_1  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F;};
sampler2D samp_filter_1 {Texture = tex_filter_1; AddressU = MIRROR; AddressV = MIRROR;};

uint getRadius()
{
    return max(1, 2 * fSigmaS);
}

float gaussWeight(float x, float sigma)
{
    return exp(-x * x / (2 * sigma * sigma));
}

float4 conv1D(sampler2D samp, float2 uv, uint radius, bool is_gaussian, bool row_wise)
{
    float4 sum = tex2Dlod(samp, float4(uv, 0, 0));
    float4 weightsum = 1;

    float2 dir_unit = float2(BUFFER_RCP_WIDTH * row_wise, BUFFER_RCP_HEIGHT * (!row_wise));

    if(radius % 2)
    {
        float weight = is_gaussian ? gaussWeight(radius, fSigmaS) : 1;
        float2 offset = radius * dir_unit;
        sum += tex2Dlod(samp, float4(uv + offset, 0, 0)) * weight;
        sum += tex2Dlod(samp, float4(uv - offset, 0, 0)) * weight;
        weightsum += 2 * weight;
    }

    // 1 tap 4 2
    for(uint i = 1; i * 2 <= radius; ++i)
    {
        float weight_inner = is_gaussian ? gaussWeight(i * 2 - 1, fSigmaS) : 1;
        float weight_outer = is_gaussian ? gaussWeight(i * 2, fSigmaS) : 1;
        float weight_together = weight_inner + weight_outer;
        float2 offset = lerp(i * 2 - 1, i * 2, weight_outer / weight_together) * dir_unit;
        sum += tex2Dlod(samp, float4(uv + offset, 0, 0)) * weight_together;
        sum += tex2Dlod(samp, float4(uv - offset, 0, 0)) * weight_together;
        weightsum += 2 * weight_together;
    }

    return sum / weightsum;
}

// also transfer input color to tex_filter_0
void PS_MomentsHor(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 mean : SV_Target0, out float4 mean_sqr : SV_Target1)
{
    uint radius = getRadius();

    float4 mid_sample = tex2Dlod(samp_color, float4(uv, 0, 0));
    float4 sum = mid_sample;
    float4 sum_sqr = mid_sample * mid_sample;
    float4 weightsum = 1;
    for(uint i = 1; i <= radius; ++i)
    {
        float2 offset = float2(i * BUFFER_RCP_WIDTH, 0);

        float4 color_sample = tex2Dlod(samp_color, float4(uv + offset, 0, 0));
        sum += color_sample;
        sum_sqr += color_sample * color_sample;

        color_sample = tex2Dlod(samp_color, float4(uv - offset, 0, 0));
        sum += color_sample;
        sum_sqr += color_sample * color_sample;

        weightsum += 2;
    }
    
    mean = sum / weightsum;
    mean_sqr = sum_sqr / weightsum;
}

void PS_Variance(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float variance : SV_Target0)
{
    uint radius = getRadius();
    float4 mean = conv1D(samp_mean, uv, radius, false, false);
    float4 mean_sqr = conv1D(samp_mean_sqr, uv, radius, false, false);
    float4 var = max(0, mean_sqr - mean * mean);
    variance = max(max(var.x, var.y), max(var.z, var.w));
}

void PS_Weight(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float weight : SV_Target0)
{
    uint2 px_coord = uv * BUFFER_SCREEN_SIZE;
    float scaled_stuff = tex2Dfetch(samp_var, px_coord, 0).x / (fScale * tex2Dfetch(samp_var, uint2(0, 0), GVWA_MEAN_MIP).x);
    weight = 1 / (1 + scaled_stuff * scaled_stuff);
}

void PS_NormFactorHor(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float norm_factor : SV_Target0)
{
    uint radius = getRadius();
    norm_factor = conv1D(samp_weight, uv, radius, true, true).x;
}

void PS_NormFactorVer(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float norm_factor : SV_Target0)
{
    uint radius = getRadius();
    norm_factor = conv1D(samp_normfactor_0, uv, radius, true, false).x;
}

void PS_PrepareFilter(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 weighted_color : SV_Target0)
{
    uint2 px_coord = uv * BUFFER_SCREEN_SIZE;
    weighted_color = tex2Dfetch(samp_color, px_coord) * tex2Dfetch(samp_weight, px_coord).x;
}

void PS_FilterHor(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    uint radius = getRadius();
    color = conv1D(samp_filter_1, uv, radius, true, true);
}

void PS_FilterVer(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    uint2 px_coord = uv * BUFFER_SCREEN_SIZE;
    uint radius = getRadius();
    color = conv1D(samp_filter_0, uv, radius, true, false) / (tex2Dfetch(samp_normfactor_1, px_coord).x + 1e-8);
}

void PS_Display(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    uint2 px_coord = uv * BUFFER_SCREEN_SIZE;
    float4 base = tex2Dfetch(samp_filter_1, px_coord);
    float4 orig = tex2Dfetch(ReShade::BackBuffer, px_coord);
    color = base + (orig - base) * fMixDetail;
}

technique GVWA
{
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_MomentsHor;
        RenderTarget0 = tex_mean;
        RenderTarget1 = tex_mean_sqr;
    }
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_Variance;
        RenderTarget0 = tex_var;
    }
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_Weight;
        RenderTarget0 = tex_weight;
    }
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_NormFactorHor;
        RenderTarget0 = tex_normfactor_0;
    }
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_NormFactorVer;
        RenderTarget0 = tex_normfactor_1;
    }

    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_PrepareFilter;
        RenderTarget0 = tex_filter_1;
    }
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_FilterHor;
        RenderTarget0 = tex_filter_0;
    }
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_FilterVer;
        RenderTarget0 = tex_filter_1;
    }

// in the original paper there are iterations

    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_Display;
    }
}

}