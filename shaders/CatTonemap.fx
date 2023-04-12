/*
    Reference:
    tizian/tonemapper
        url:    https://github.com/tizian/tonemapper
        credit: plenty o' mapping functions
    How to compute log with the preprocessor
        url:    https://stackoverflow.com/questions/27581671/how-to-compute-log-with-the-preprocessor
        credit: LOG macro

    亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖亖

    TODO:
    - More adaptation curves (log, bidirectional speed)
    - Local tonemapper (!madness)
*/

#include "ReShade.fxh"
#include "extern/linearization/Linearize.fxh"


#define EPS 1e-6

#define TERNARY(cond, a, b) ((cond) * (a) + !(cond) * (b))

#define LOG_1(n) ((n) >= 2)
#define LOG_2(n) TERNARY(((n) >= 1<<2), (2 + LOG_1((n)>>2)), LOG_1(n))
#define LOG_4(n) TERNARY(((n) >= 1<<4), (4 + LOG_2((n)>>4)), LOG_2(n))
#define LOG_8(n) TERNARY(((n) >= 1<<8), (8 + LOG_4((n)>>8)), LOG_4(n))
#define LOG(n)   TERNARY(((n) >= 1<<16), (16 + LOG_8((n)>>16)), LOG_8(n))


#define CATTONE_ERRMSG(Mac) Invalid Mac Value


#ifndef CATTONE_INPUT_HALFRES
#   define CATTONE_INPUT_HALFRES 1
#endif

#if CATTONE_INPUT_HALFRES
#   define CATTONE_INPUT_WIDTH  (BUFFER_WIDTH >> 1)
#   define CATTONE_INPUT_HEIGHT (BUFFER_HEIGHT >> 1)
#else
#   define CATTONE_INPUT_WIDTH  BUFFER_WIDTH
#   define CATTONE_INPUT_HEIGHT BUFFER_HEIGHT
#endif
#define CATTONE_INPUT_TEXMIP LOG(TERNARY(BUFFER_WIDTH > BUFFER_HEIGHT, CATTONE_INPUT_WIDTH, CATTONE_INPUT_HEIGHT))


#ifndef CATTONE_VALUE_FUNC
#   define CATTONE_VALUE_FUNC 0
#endif
/*
    0 - sRGB luminance
    1 - l2 norm aka euclidean distance aka length
    2 - linf norm aka max
*/
#if CATTONE_VALUE_FUNC == 0
#   define VALUE_FUNC(color) rgbLuminance(color.rgb);
#elif CATTONE_VALUE_FUNC == 1
#   define VALUE_FUNC(color) length(color.rgb);
#elif CATTONE_VALUE_FUNC == 2
#   define VALUE_FUNC(color) max(color.r, max(color.g, color.b));
#else
#   error CATTONE_ERRMSG(CATTONE_VALUE_FUNC)
#endif


#ifndef CATTONE_TONEMAPPER
#   define CATTONE_TONEMAPPER 2
#endif
/*
    0 - Gamma Only
    1 - Reinhard => Reinhard et al. Photographic Tone Reproduction for Digital Images.
    2 - Reinhard Extended => Reinhard et al. Photographic Tone Reproduction for Digital Images.
    3 - Uncharted 2 => John Hable. Filmic Tonemapping for Real-time Rendering.
    4 - Hejl Burgess-Dawson Filmic => Jim Hejl and Richard Burgess-Dawson. Filmic Tonemapping for Real-time Rendering.
    ACES
    photoreceptor => Dunn et al. Light adaptation in cone vision involves switching between receptor and post-receptor sites.
*/
#if CATTONE_TONEMAPPER == 0
#   define PARAM_KEYVAL
#   define TONEMAP keyValAdapt
#   define TONEMAPPER_NAME "Gamma Only"
#elif CATTONE_TONEMAPPER == 1
#   define PARAM_KEYVAL
#   define TONEMAP reinhard
#   define TONEMAPPER_NAME "Reinhard"
#elif CATTONE_TONEMAPPER == 2
#   define PARAM_KEYVAL
#   define PARAM_WHITEPOINT
#   define TONEMAP reinhardExt
#   define TONEMAPPER_NAME "Reinhard Extended"
#elif CATTONE_TONEMAPPER == 3
#   define PARAM_KEYVAL
// #   define PARAM_WHITEPOINT
#   define TONEMAP uncharted
#   define TONEMAPPER_NAME "Filmic (Hable 2010 / Uncharted 2)"
#elif CATTONE_TONEMAPPER == 4
#   define PARAM_KEYVAL
#   define TONEMAP hejlBurgessDawsonFilmic
#   define TONEMAPPER_NAME "Filmic (Hejl Burgess-Dawson)"
#else
#   error CATTONE_ERRMSG(CATTONE_TONEMAPPER)
#endif


#ifndef CATTONE_PER_CHANNEL_MAP
#   define CATTONE_PER_CHANNEL_MAP 0
#endif


namespace CatTonemap
{

uniform float fFrameTime < source = "frametime"; >;

uniform bool bDisplayInterestArea <
    ui_category = "IO";
    ui_label = "Display Interest Area (Colored)";
> = false;

uniform float2 fAreaSize <
    ui_category = "IO";
    ui_label = "Interest Area Size";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
> = float2(1.0, 1.0);

uniform float2 fAreaOffset <
    ui_category = "IO";
    ui_label = "Interest Area Offset";
    ui_type = "slider";
    ui_min = -0.5; ui_max = 0.5;
    ui_step = 0.01;
> = float2(0.0, 0.0);

uniform float2 fOutputRange <
    ui_category = "IO";
    ui_label = "Output Range";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
> = float2(0.0, 1.0);

uniform float fAdaptSpeed <
    ui_category = "Adaptation";
    ui_label = "Adaptation Speed";
    ui_type = "slider";
    ui_min = 0.01; ui_max = 2.0;
    ui_step = 0.01;
> = 0.5;

uniform float2 fAdaptRange <
    ui_category = "Adaptation";
    ui_label = "Adaptation Value Range (Log)";
    ui_type = "slider";
    ui_min = -10.0; ui_max = 10.0;
    ui_step = 0.01;
> = float2(-5.0, 10.0);

uniform int iTonemapDisplay <
	ui_text = "Current TMO: "
              TONEMAPPER_NAME;
	ui_category = "Tonemapping";
	ui_label = " ";
	ui_type = "radio";
>;

#ifdef PARAM_KEYVAL
uniform float fKeyValue <
    ui_category = "Tonemapping";
    ui_label = "Key Value / Exposure";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0;
    ui_step = 0.01;
> = 0.25;
#endif

#ifdef PARAM_WHITEPOINT
uniform float fWhitePoint <
    ui_category = "Tonemapping";
    ui_label = "White Point";
    ui_type = "slider";
    ui_min = 0.01; ui_max = 10.0;
    ui_step = 0.01;
> = 2.0;
#endif

#if CATTONE_PER_CHANNEL_MAP == 0
uniform float fSatPower <
    ui_category = "Tonemapping";
    ui_label = "Saturation Power";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0;
    ui_step = 0.01;
> = 1.0;
#endif

uniform float fPostGamma <
    ui_category = "Tonemapping";
    ui_label = "Post Gamma";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0;
    ui_step = 0.01;
> = 1.0;


texture2D tex_input    {Width = CATTONE_INPUT_WIDTH; Height = CATTONE_INPUT_HEIGHT; Format = R32F; MipLevels = CATTONE_INPUT_TEXMIP + 1;};
sampler2D samp_input   {Texture = tex_input;};
storage2D st_input_avg {Texture = tex_input; MipLevel = CATTONE_INPUT_TEXMIP;};

texture2D tex_avg_val  {Width = 1; Height = 1; Format = R32F;};
sampler2D samp_avg_val {Texture = tex_avg_val;};
storage2D st_avg_val   {Texture = tex_avg_val; MipLevel = 0;};


bool isInScreen(float2 uv)
{
    return all(uv > 0) && all(uv < 1);
}

float rgbLuminance(float3 rgb)
{
    return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b;
}

#ifdef PARAM_KEYVAL
float3 keyValAdapt(float3 val, float3 avg_val)
{
    return fKeyValue * val / avg_val;
}

float3 reinhard(float3 val, float3 avg_val)
{
    val = keyValAdapt(val, avg_val);
    val = val / (1 + val);
    return val;
}

#ifdef PARAM_WHITEPOINT
float3 reinhardExt(float3 val, float3 avg_val)
{
    val = keyValAdapt(val, avg_val);
    val = val * (1 + val / (fWhitePoint * fWhitePoint)) / (1 + val);
    return val;
}
#endif

float3 hejlBurgessDawsonFilmic(float3 val, float3 avg_val)
{
    val = keyValAdapt(val, avg_val);
    val = max(0, val - 0.004);
    val = (val * (6.2 * val + .5)) / (val * (6.2 * val + 1.7) + 0.06);
    return val;
}

float3 unchartedHelper(float3 x)
{
    static const float A = 0.15;
    static const float B = 0.50;
    static const float C = 0.10;
    static const float D = 0.20;
    static const float E = 0.02;
    static const float F = 0.30;
    return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F;
}

float3 uncharted(float3 val, float3 avg_val)
{
    val = keyValAdapt(val, avg_val);
    val = unchartedHelper(val);
    val /= unchartedHelper(11.2);
    return val;
}
#endif

void PS_PrepareInput(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 out_val : SV_Target0)
{
    float2 remapped_uv = 0.5 + fAreaOffset + lerp(-fAreaSize, fAreaSize, uv) * 0.5;
    float4 color = isInScreen(uv) ? GetBackBuffer(uv) : 0;

    float value = VALUE_FUNC(color);
    value = log(value + EPS);

    out_val = value;
}

void CS_Adapt(uint3 id : SV_DispatchThreadID)
{
    float prev_val = tex2Dfetch(st_avg_val, uint2(0, 0)).x;
    float target_val = exp(tex2Dfetch(st_input_avg, uint2(0, 0)).x);
    float new_val = clamp(lerp(prev_val, target_val, saturate(fAdaptSpeed * fFrameTime * 1e-3)), exp(fAdaptRange.x), exp(fAdaptRange.y));
    tex2Dstore(st_avg_val, uint2(0, 0), new_val);
}

void PS_Tonemap(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 out_color : SV_Target0)
{
    float4 color = GetBackBuffer(uv);
    
    float avg_val = tex2Dfetch(samp_avg_val, uint2(0, 0)).x;
    float val = VALUE_FUNC(color);

#if CATTONE_PER_CHANNEL_MAP
    float3 mapped_color = TONEMAP(color, avg_val);
#else 
    float mapped_val = TONEMAP(val, avg_val);
    float3 mapped_color = pow(abs(color.rgb / val), fSatPower) * mapped_val;
#endif

    mapped_color = pow(abs(mapped_color), rcp(fPostGamma));

    out_color = lerp(fOutputRange.x, fOutputRange.y, saturate(mapped_color));
    out_color = DisplayBackBuffer(out_color);

    if(bDisplayInterestArea)
    {
        float2 uv_center = 0.5 + fAreaOffset;
        if(all(abs(uv - uv_center) < fAreaSize * 0.5))
            out_color = val;
    }
}

technique CatTonemap
{
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_PrepareInput;
        RenderTarget0 = tex_input;
    }
    pass
    {
        ComputeShader = CS_Adapt<1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
    }
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_Tonemap;
        SRGBWriteEnable = _SRGB;
    }
}
}
