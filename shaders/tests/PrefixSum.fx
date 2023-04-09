#include "ReShade.fxh"

texture2D tex_prefixsum_1  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA32F;};
storage2D st_prefixsum_1   {Texture = tex_prefixsum_1; MipLevel = 0;};
sampler2D samp_prefixsum_1 {Texture = tex_prefixsum_1;};

texture2D tex_prefixsum_2  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA32F;}; 
storage2D st_prefixsum_2   {Texture = tex_prefixsum_2; MipLevel = 0;};
sampler2D samp_prefixsum_2 {Texture = tex_prefixsum_2;};

#ifndef PREFIX_SUM_NTHREADS
#   define PREFIX_SUM_NTHREADS 512
#endif

#if BUFFER_WIDTH > BUFFER_HEIGHT
#   define CACHE_LEN ((BUFFER_WIDTH - 1) / PREFIX_SUM_NTHREADS + 1)
#else
#   define CACHE_LEN ((BUFFER_HEIGHT - 1) / PREFIX_SUM_NTHREADS + 1)
#endif

// chain+Kogge-Stone+chain sum on one dimension
// source and target are transposed 
groupshared uint4 shared_buffer[PREFIX_SUM_NTHREADS];
void prefixSumNaive(storage2D st_source, storage2D st_target, uint gid, uint tid, bool row_wise, bool transpose)
{
    int dim_size = row_wise ? BUFFER_WIDTH : BUFFER_HEIGHT;
    uint work_size = (dim_size - 1) / PREFIX_SUM_NTHREADS + 1;
    uint offset = tid * work_size;

    // chain sum within partition
    uint4 part_sum[CACHE_LEN];
    for(uint i = 0; i < work_size; ++i)
    {
        uint2 px_coord = row_wise ? uint2(offset + i, gid) : uint2(gid, offset + i);
        part_sum[i] = tex2Dfetch(st_source, px_coord);
        if(i > 0)
            part_sum[i] += part_sum[i - 1];
    }

    // inter-partition Kogge-Stone
    shared_buffer[tid] = part_sum[work_size - 1];
    for(uint shift = 1; shift < PREFIX_SUM_NTHREADS; shift = shift << 1)
    {
        uint4 shifted_sum = 0;
        barrier();
        if(shift <= tid)
            shifted_sum = shared_buffer[tid - shift];

        barrier();
        shared_buffer[tid] += shifted_sum;
    }

    uint4 prev_shared_buffer = 0;
    barrier();
    if(tid > 0)
        prev_shared_buffer = shared_buffer[tid - 1];

    // chain again
    // actually, since we cached partition prefix sum, we can just add the cached value
    for(uint i = 0; i < work_size; ++i)
    {
        if(offset + i >= dim_size)
            break;

        uint2 px_coord = row_wise ^ transpose ? uint2(offset + i, gid) : uint2(gid, offset + i);
        part_sum[i] += prev_shared_buffer;
        tex2Dstore(st_target, px_coord, part_sum[i]);
    }
}

void PS_Init(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    color = 1;  // !
}

void CS_SumRow(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    prefixSumNaive(st_prefixsum_1, st_prefixsum_2, gid.x, tid.x, true, false);
}

void CS_SumCol(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    prefixSumNaive(st_prefixsum_2, st_prefixsum_1, gid.x, tid.x, false, false);
}

void PS_Display(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    uint2 px_coord = uv * BUFFER_SCREEN_SIZE;
    color = tex2Dfetch(samp_prefixsum_1, px_coord) / float(BUFFER_WIDTH * BUFFER_HEIGHT);
}

technique TestPrefixSum
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Init;
        RenderTarget0 = tex_prefixsum_1;
    }
    pass
    {
        ComputeShader = CS_SumRow<PREFIX_SUM_NTHREADS, 1>;
        DispatchSizeX = BUFFER_HEIGHT;
		DispatchSizeY = 1;
    }
    pass
    {
        ComputeShader = CS_SumCol<PREFIX_SUM_NTHREADS, 1>;
        DispatchSizeX = BUFFER_WIDTH;
		DispatchSizeY = 1;
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Display;
    }
}