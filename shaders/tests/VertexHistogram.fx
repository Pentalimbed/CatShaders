/*
    Efficient Histogram Generation Using Scattering on GPUs
        https://shaderwrangler.com/publications/histogram/histogram_cameraready.pdf
*/

#include "ReShade.fxh"

#ifndef VERTHIST_BINS
#   define VERTHIST_BINS 1024
#endif

namespace VertexHistogram
{

static const float maxbin_val = 2.0;

// set format to rgba32f for maximum bins (4096!) or color histogram
// but alas i'm lazy
texture2D tex_histogram  {Width = VERTHIST_BINS; Height = 1; Format = R32F;};
storage2D st_histogram   {Texture = tex_histogram; MipLevel = 0;};
sampler2D samp_histogram {Texture = tex_histogram;};

void VS_Histogram(in uint id : SV_VertexID, out float4 position : SV_Position)
{
    uint2 px_coord = uint2(id % BUFFER_WIDTH, id / BUFFER_WIDTH);
    float4 color = tex2Dfetch(ReShade::BackBuffer, px_coord);
    uint bin = length(color.rgb) * VERTHIST_BINS / maxbin_val;
    float2 uv = float2((bin + 0.5) / VERTHIST_BINS, 0.5);
    position = float4(uv * 2 - 1, 0, 1);
}

void PS_Histogram( in float4 vpos : SV_Position, out float4 color : SV_Target0)
{
    color = 1.0;
}

technique VertexHistogram
{
    pass
    {
        VertexShader = VS_Histogram;
        VertexCount = BUFFER_WIDTH * BUFFER_HEIGHT;
        PrimitiveTopology = POINTLIST;

        PixelShader = PS_Histogram;

        RenderTarget0 = tex_histogram;

        ClearRenderTargets = true; 
		BlendEnable = true; 
		SrcBlend = ONE; 
		DestBlend = ONE;
		BlendOp = ADD;
    }
}

}
