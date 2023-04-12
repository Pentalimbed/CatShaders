// src: https://github.com/AKGWSB/FFTConvolutionBloom/

#ifndef LOG_FFT_TEX_SIZE
#   define LOG_FFT_TEX_SIZE 9
#endif
#define FFT_TEX_SIZE (1<<LOG_FFT_TEX_SIZE)
#define HALF_FFT_TEX_SIZE (FFT_TEX_SIZE>>1)

#include "ReShade.fxh"

namespace FFTBloom
{
static const float PI = 3.141592653589793238462643383279;

uniform float fLowPassFreq <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 10;
    ui_step = 0.1;
> = 1;

uniform float fBrightnessThres <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0;
    ui_step = 0.01;
> = 0.7;

uniform float fMixStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 10.0;
    ui_step = 0.01;
> = 4.0;

texture2D tex_color_scaled {Width = FFT_TEX_SIZE; Height = FFT_TEX_SIZE; Format = RGBA16F;};
storage2D st_color_scaled  {Texture = tex_color_scaled; MipLevel = 0;};

texture2D tex_freq {Width = FFT_TEX_SIZE << 1; Height = FFT_TEX_SIZE; Format = RGBA16F;};
storage2D st_freq  {Texture = tex_freq; MipLevel = 0;};

texture2D tex_freq_temp {Width = FFT_TEX_SIZE << 1; Height = FFT_TEX_SIZE; Format = RGBA16F;};
storage2D st_freq_temp  {Texture = tex_freq_temp; MipLevel = 0;};

texture2D tex_ifft  {Width = FFT_TEX_SIZE; Height = FFT_TEX_SIZE; Format = RGBA16F;};
sampler2D samp_ifft {Texture = tex_ifft;};
storage2D st_ifft   {Texture = tex_ifft; MipLevel = 0;};

float2 complexMul(float2 a, float2 b)
{
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

float2 complexConjugate(float2 a){return float2(a.x, -a.y);}

groupshared float2 groupshared_buffer[FFT_TEX_SIZE];
float2 cooleyTukey(float2 f_n, uint idx, bool is_forward)
{
    uint reverse_idx = reversebits(idx) >> (32 - LOG_FFT_TEX_SIZE);
    barrier();
    groupshared_buffer[reverse_idx] = f_n;

    for(uint N = 2; N <= FFT_TEX_SIZE; N = N << 1)
    {
        uint i = idx % N;
        uint k = idx % (N >> 1);
        uint even_idx_start = idx - i;
        uint odd_idx_start  = even_idx_start + (N >> 1);
        
        barrier();
        float2 F_even_k = groupshared_buffer[even_idx_start + k];
        float2 F_odd_k  = groupshared_buffer[odd_idx_start  + k];

        float2 W;
        sincos(2 * PI * float(k) / float(N), W.y, W.x);
        W = is_forward ? W : complexConjugate(W);
        
        float2 F_k;
        if(i < N/2)
            F_k = F_even_k + complexMul(W, F_odd_k);
        else
            F_k = F_even_k - complexMul(W, F_odd_k);
        
        barrier();
        groupshared_buffer[idx] = F_k;
    }

    barrier();
    return groupshared_buffer[idx] / sqrt(FFT_TEX_SIZE);
}

void fft(storage2D st_source, storage2D st_target, uint thread_id, uint group_id, bool is_forward, bool is_horizontal)
{
    uint2 px_coord = is_horizontal ? uint2(thread_id, group_id) : uint2(group_id, thread_id);
    uint2 px_rg = px_coord;
    uint2 px_ba = uint2(px_coord.x + FFT_TEX_SIZE, px_coord.y);

    float2 inputs[3];
    float2 outputs[3] = {0.0.xx, 0.0.xx, 0.0.xx};
    [branch]
    if(is_forward && is_horizontal)
    {
        float4 src = tex2Dfetch(st_source, px_coord);
        inputs[0] = float2(src.x, 0);
        inputs[1] = float2(src.y, 0);
        inputs[2] = float2(src.z, 0);
    }
    else
    {
        float4 src_rg = tex2Dfetch(st_source, px_rg);
        float4 src_ba = tex2Dfetch(st_source, px_ba);
        inputs[0] = src_rg.xy;
        inputs[1] = src_rg.zw;
        inputs[2] = src_ba.xy;
    }

    for(uint channel = 0; channel < 3; ++channel)
    {
        float2 f_n = inputs[channel];
        float2 F_k = cooleyTukey(f_n, thread_id, is_forward);
        outputs[channel] = F_k;
    }

    [branch]
    if(is_forward || !is_horizontal)
    {
        tex2Dstore(st_target, px_rg, float4(outputs[0], outputs[1]));
        tex2Dstore(st_target, px_ba, float4(outputs[2], 1, 1));
    }
    else
    {
        tex2Dstore(st_target, px_coord, float4(outputs[0].x, outputs[1].x, outputs[2].x, 1));
    }
}

void PS_downscale(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    float2 scale = float2(BUFFER_WIDTH, BUFFER_HEIGHT) / max(BUFFER_WIDTH, BUFFER_HEIGHT);
    float2 uv_orig = 0.5 + (0.5 - uv) / scale * 2;

    color = 0;
    [branch]
    if(all(uv_orig < 1) && all(uv_orig > 0))
    {
        color = tex2D(ReShade::BackBuffer, uv_orig);
        color = length(color.rgb) > fBrightnessThres ? color : 0;
    }
}

void CS_fftHorizontal(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    fft(st_color_scaled, st_freq_temp, tid.x, gid.x, true, true);
}

void CS_fftVertical(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    fft(st_freq_temp, st_freq, tid.x, gid.x, true, false);
}

void CS_convolution(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    uint2 px_rg = id.xy;
    uint2 px_ba = uint2(id.x + FFT_TEX_SIZE, id.y);

    float4 rg = tex2Dfetch(st_freq, px_rg);
    float4 ba = tex2Dfetch(st_freq, px_ba);

    float weight = exp(-length(px_rg) * 0.5 / (fLowPassFreq * fLowPassFreq));
    
    tex2Dstore(st_freq, px_rg, rg * weight);
    tex2Dstore(st_freq, px_ba, ba * weight);
}

void CS_ifftVertical(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    fft(st_freq, st_freq_temp, tid.x, gid.x, false, false);
}

void CS_ifftHorizontal(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    fft(st_freq_temp, st_ifft, tid.x, gid.x, false, true);
}

void PS_Display(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    float2 scale = float2(BUFFER_WIDTH, BUFFER_HEIGHT) / max(BUFFER_WIDTH, BUFFER_HEIGHT);
    // 0.5 + (float2(0.25, 0.5) - uv) / scale * float2(4, 2);
    float2 uv_mapped = 0.5 - (uv - 0.5) * scale * 0.5;
    color = tex2D(ReShade::BackBuffer, uv) + saturate(tex2D(samp_ifft, uv_mapped)) * fMixStrength;
}

technique FFTBloom
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_downscale;
        RenderTarget0 = tex_color_scaled;
    }
    pass
    {
        ComputeShader = CS_fftHorizontal<FFT_TEX_SIZE, 1>;
        DispatchSizeX = FFT_TEX_SIZE;
		DispatchSizeY = 1;
    }
    pass
    {
        ComputeShader = CS_fftVertical<FFT_TEX_SIZE, 1>;
        DispatchSizeX = FFT_TEX_SIZE;
		DispatchSizeY = 1;
    }
    pass
    {
        ComputeShader = CS_convolution<8, 8>;
        DispatchSizeX = FFT_TEX_SIZE / 8;
		DispatchSizeY = FFT_TEX_SIZE / 8;
    }
    pass
    {
        ComputeShader = CS_ifftVertical<FFT_TEX_SIZE, 1>;
        DispatchSizeX = FFT_TEX_SIZE;
		DispatchSizeY = 1;
    }
    pass
    {
        ComputeShader = CS_ifftHorizontal<FFT_TEX_SIZE, 1>;
        DispatchSizeX = FFT_TEX_SIZE;
		DispatchSizeY = 1;
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Display;
    }
}
}