// ref: http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare

#include "ReShade.fxh"

uniform float fLumaThres <
    ui_label = "Threshold";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.5;
    ui_step = 0.01;
> = 0.7;

uniform float fUpsampleBlurRadius <
    ui_label = "Upsample Blur Radius";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0;
    ui_step = 0.1;
> = 2.0;

#define BLURTEX(N) tex_cod_blur_##N
#define BLURSAMP(N) samp_cod_blur_##N
#define BLURUPTEX(N) tex_cod_blur_up_##N
#define BLURUPSAMP(N) samp_cod_blur_up_##N
#define BLURMIX(N) fBloom##N##Mix
#define BLURLABEL(N) "Level "#N" Mix"
#define BLUR_DEF(N)             \
uniform float BLURMIX(N) <      \
    ui_label = BLURLABEL(N);    \
    ui_type = "slider";         \
    ui_min = 0.0; ui_max = 2.0; \
    ui_step = 0.01;             \
> = 1.0;                        \
texture2D BLURTEX(N)    {Width = BUFFER_WIDTH >> N; Height = BUFFER_HEIGHT >> N; Format = RGBA16F;}; \
sampler2D BLURSAMP(N)   {Texture = BLURTEX(N);};                                                     \
texture2D BLURUPTEX(N)  {Width = BUFFER_WIDTH >> N; Height = BUFFER_HEIGHT >> N; Format = RGBA16F;}; \
sampler2D BLURUPSAMP(N) {Texture = BLURUPTEX(N);};

uniform float fBloomMix <      
    ui_label = "Effect Mix";    
    ui_type = "slider";         
    ui_min = 0.0; ui_max = 2.0; 
    ui_step = 0.01;             
> = 1.0;  
texture2D BLURTEX(0)    {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F;}; 
sampler2D BLURSAMP(0)   {Texture = BLURTEX(0);};     

BLUR_DEF(1)
BLUR_DEF(2)
BLUR_DEF(3)
BLUR_DEF(4)
BLUR_DEF(5)
BLUR_DEF(6)
BLUR_DEF(7)

float luma(float3 rgb)
{
    return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b;
}

float4 downsample(sampler samp, float2 uv, float2 px_size)
{
    float4 fetches2x2[4];
    float4 fetches3x3[9];

    [unroll]for(uint x = 0; x < 2; ++x)
        [unroll]for(uint y = 0; y < 2; ++y)
            fetches2x2[x * 2 + y] = tex2D(samp, uv + (int2(x, y) * 2 - 1) * px_size);
    [unroll]for(uint x = 0; x < 3; ++x)
        [unroll]for(uint y = 0; y < 3; ++y)
            fetches3x3[x * 3 + y] = tex2D(samp, uv + (int2(x, y) - 1) * 2 * px_size);

    float4 retval = 0;
    [unroll]for(uint x = 0; x < 2; ++x)
        [unroll]for(uint y = 0; y < 2; ++y)
        {
            retval += 0.5 * 0.25 * fetches2x2[x * 2 + y];
            retval += 0.125 * 0.25 * fetches3x3[ x      * 3 + y    ];
            retval += 0.125 * 0.25 * fetches3x3[(x + 1) * 3 + y    ];
            retval += 0.125 * 0.25 * fetches3x3[ x      * 3 + y + 1];
            retval += 0.125 * 0.25 * fetches3x3[(x + 1) * 3 + y + 1];
        }

    return retval;
}

float4 upsample(sampler samp, float2 uv, float2 radius)
{
    float4 retval = 0;
    [unroll]for(int x = -1; x <= 1; ++x)
        [unroll]for(int y = -1; y <= 1; ++y)
        {
            float w = (1 << (!x + !y)) * 0.0625;
            float2 uv_sample = uv + float2(x, y) * radius;
            retval += tex2D(samp, uv_sample) * w;
        }
    return retval;
}

void PS_ProcessInput(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    color = tex2D(ReShade::BackBuffer, uv);
    color = luma(color.rgb) > fLumaThres ? color : 0;
    color.a = 1;
}

#define DOWN_FUNC(N) PS_Downsample##N
#define DOWN_FUNC_DEF(N)                                                                                  \
void DOWN_FUNC(N) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0) \
{color = downsample(BLURSAMP(N), uv, BUFFER_PIXEL_SIZE * (1 << N));}

DOWN_FUNC_DEF(0)
DOWN_FUNC_DEF(1)
DOWN_FUNC_DEF(2)
DOWN_FUNC_DEF(3)
DOWN_FUNC_DEF(4)
DOWN_FUNC_DEF(5)
DOWN_FUNC_DEF(6)

#define UP_FUNC(N) PS_Upsample##N
// #define UP_FUNC_DEF(N, N_ADD_1)                                                                         \
// void UP_FUNC(N) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0) \ 
// {color = upsample(BLURSAMP(N), uv, BUFFER_PIXEL_SIZE * (1 << N) * fUpsampleBlurRadius) * BLURMIX(N) + tex2D(BLURUPSAMP(N_ADD_1), uv);}

void UP_FUNC(7) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0)      
{
    color = upsample(BLURSAMP(7), uv, BUFFER_PIXEL_SIZE * (1 << 7) * fUpsampleBlurRadius) * BLURMIX(7);
}
void UP_FUNC(6) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0)      
{
    color = upsample(BLURSAMP(6), uv, BUFFER_PIXEL_SIZE * (1 << 6) * fUpsampleBlurRadius) * BLURMIX(6) + tex2D(BLURUPSAMP(7), uv);                                                                        
}
void UP_FUNC(5) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0)      
{
    color = upsample(BLURSAMP(5), uv, BUFFER_PIXEL_SIZE * (1 << 5) * fUpsampleBlurRadius) * BLURMIX(5) + tex2D(BLURUPSAMP(6), uv);                                                                        
}
void UP_FUNC(4) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0)      
{
    color = upsample(BLURSAMP(4), uv, BUFFER_PIXEL_SIZE * (1 << 4) * fUpsampleBlurRadius) * BLURMIX(4) + tex2D(BLURUPSAMP(5), uv);                                                                        
}
void UP_FUNC(3) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0)      
{
    color = upsample(BLURSAMP(3), uv, BUFFER_PIXEL_SIZE * (1 << 3) * fUpsampleBlurRadius) * BLURMIX(3) + tex2D(BLURUPSAMP(4), uv);                                                                        
}
void UP_FUNC(2) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0)      
{
    color = upsample(BLURSAMP(2), uv, BUFFER_PIXEL_SIZE * (1 << 2) * fUpsampleBlurRadius) * BLURMIX(2) + tex2D(BLURUPSAMP(3), uv);                                                                        
}
void UP_FUNC(1) (in float4 vpos : SV_Position, in float2 uv : TEXCOORD0, out float4 color : SV_Target0)      
{
    color = upsample(BLURSAMP(1), uv, BUFFER_PIXEL_SIZE * (1 << 1) * fUpsampleBlurRadius) * BLURMIX(1) + tex2D(BLURUPSAMP(2), uv);                                                                        
}

void PS_Display(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    color = tex2D(ReShade::BackBuffer, uv) + tex2D(BLURUPSAMP(1), uv) * fBloomMix;
}

technique CodBloom
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_ProcessInput;
        RenderTarget0 = BLURTEX(0);
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = DOWN_FUNC(0);
        RenderTarget0 = BLURTEX(1);
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = DOWN_FUNC(1);
        RenderTarget0 = BLURTEX(2);
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = DOWN_FUNC(2);
        RenderTarget0 = BLURTEX(3);
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = DOWN_FUNC(3);
        RenderTarget0 = BLURTEX(4);
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = DOWN_FUNC(4);
        RenderTarget0 = BLURTEX(5);
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = DOWN_FUNC(5);
        RenderTarget0 = BLURTEX(6);
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = DOWN_FUNC(6);
        RenderTarget0 = BLURTEX(7);
    }

#define UPPASS(N) \
    pass                              \
    {                                 \
        VertexShader = PostProcessVS; \
        PixelShader = UP_FUNC(N);     \
        RenderTarget0 = BLURUPTEX(N); \
    }

    UPPASS(7)
    UPPASS(6)
    UPPASS(5)
    UPPASS(4)
    UPPASS(3)
    UPPASS(2)
    UPPASS(1)

    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Display;
    }
}