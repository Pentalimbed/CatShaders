// Tone Mapping Based on Multi-scale Histogram Synthesis

#include "ReShade.fxh"

#ifndef MSHIST_NTHREADS
#   define MSHIST_NTHREADS 512
#endif

// +2 for one padding
#if BUFFER_WIDTH > BUFFER_HEIGHT
#   define CACHE_LEN ((BUFFER_WIDTH - 1) / PREFIX_SUM_NTHREADS + 2)
#else
#   define CACHE_LEN ((BUFFER_HEIGHT - 1) / PREFIX_SUM_NTHREADS + 2)
#endif

#define NBINS 6



uniform float fFrameTime < source = "frametime"; >;

// +++++++++++++++++++++++++++++
// UI variables
// +++++++++++++++++++++++++++++

uniform float fDebug = 1.0;

// ----- Tonemapping ----- //

uniform float fMaxValLog <
    ui_category = "Tonemapping";
    ui_label = "Max Log Value";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 10.0;
    ui_step = 0.01;
> = 3;

uniform uint fFineScale <
    ui_category = "Tonemapping";
    ui_label = "Fine Scale";
    ui_type = "slider";
    ui_min = 1; ui_max = 6;
> = 3;

uniform float fVarSensitivity <
    ui_category = "Tonemapping";
    ui_label = "Variance Sensitivity";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.5;
    ui_step = 0.01;
> = 0.1;

uniform float fLinearBias <
    ui_category = "Tonemapping";
    ui_label = "Linearization Bias";
    ui_type = "slider";
    ui_tooltip = "Less = Preserve contrast, brighter\n"
                "Greater = Preserve value scale, more salient adaptation";
    ui_min = 0.01; ui_max = 1.0;
    ui_step = 0.01;
> = 0.2;

// ----- Adaptation ----- //

uniform float2 fAdaptAreaSize<
    ui_category = "Adaptation";
    ui_label = "Adaptation Area Size";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
> = float2(1.0, 1.0);

uniform float2 fAdaptAreaOffset<
    ui_category = "Adaptation";
    ui_label = "Adaptation Area Offset";
    ui_type = "slider";
    ui_min = -0.5; ui_max = 0.5;
    ui_step = 0.01;
> = float2(0, 0.0);

uniform float fTargetMaxBinMul <
    ui_category = "Adaptation";
    ui_label = "Target Max Bin Mult";
    ui_type = "slider";
    ui_tooltip = "How many times the average value of adaptation area "
                 "the value of maximal bin (white point) should be.";
    ui_min = 0.01; ui_max = 100.0;
    ui_step = 0.01;
> = 9.6;

uniform float2 fMaxBinLogRange<
    ui_category = "Adaptation";
    ui_label = "Max Bin Log Range";
    ui_type = "slider";
    ui_min = 0.01; ui_max = 10.0;
    ui_step = 0.01;
> = float2(0.01, 10.0);

uniform float fAdaptSpeed <
    ui_category = "Adaptation";
    ui_label = "Adaptation Speed";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 5.0;
    ui_step = 0.01;
> = 1.0;


// +++++++++++++++++++++++++++++
// Buffers
// +++++++++++++++++++++++++++++

// bin1 (uint4 RGBA)
texture2D tex_integral_1  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA32F;};
storage2D st_integral_1   {Texture = tex_integral_1; MipLevel = 0;};
sampler2D samp_integral_1 {Texture = tex_integral_1;};

// moments (float2 RG) bin2 (uint2 BA)
texture2D tex_integral_2  {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA32F;};
storage2D st_integral_2   {Texture = tex_integral_2; MipLevel = 0;};
sampler2D samp_integral_2 {Texture = tex_integral_2;};

// storing log max bin (adaptation)
texture2D tex_adapt  {Width = 1; Height = 1; Format = R32F;};
storage2D st_adapt   {Texture = tex_adapt; MipLevel = 0;};
sampler2D samp_adapt {Texture = tex_adapt;};


// +++++++++++++++++++++++++++++
// Functions
// +++++++++++++++++++++++++++++

// ----- Integral Data Handling ----- //

struct IntegralData
{
    uint4 bin1;  // bin 0~3
    uint2 bin2;  // bin 4~5
    float2 moments;  // value - 0.5
};

IntegralData integralDataZero()
{
    IntegralData retval;
    retval.bin1 = 0;
    retval.bin2 = 0;
    retval.moments = 0;
    return retval;
}

void integralDataAdd(inout IntegralData a, in IntegralData b)
{
    a.bin1 += b.bin1;
    a.bin2 += b.bin2;
    a.moments += b.moments;
}

void integralDataSub(inout IntegralData a, in IntegralData b)
{
    a.bin1 -= b.bin1;
    a.bin2 -= b.bin2;
    a.moments -= b.moments;
}

IntegralData integralDataUnpack(float4 in1, float4 in2)
{
    IntegralData retval;
    retval.bin1 = (in1);
    retval.bin2 = (in2.ba);
    retval.moments = in2.rg;

    return retval;
}

void integralDataPack(IntegralData data, out float4 out1, out float4 out2)
{
    out1 = (data.bin1);
    out2 = float4(data.moments, (data.bin2));
}

IntegralData integralDataFetchStorage(int2 px_coord)
{
    if(any(px_coord < 0))
        return integralDataZero();
    px_coord = min(px_coord, BUFFER_SCREEN_SIZE - 1);

    float4 data1 = tex2Dfetch(st_integral_1, px_coord);
    float4 data2 = tex2Dfetch(st_integral_2, px_coord);

    IntegralData retval = integralDataUnpack(data1, data2);
    return retval;
}

IntegralData integralDataFetchSampler(int2 px_coord)
{
    if(any(px_coord < 0))
        return integralDataZero();
    px_coord = min(px_coord, BUFFER_SCREEN_SIZE - 1);

    float4 data1 = tex2Dfetch(samp_integral_1, px_coord);
    float4 data2 = tex2Dfetch(samp_integral_2, px_coord);

    IntegralData retval = integralDataUnpack(data1, data2);
    return retval;
}

void integralDataStore(uint2 px_coord, IntegralData data)
{
    float4 out1, out2;
    integralDataPack(data, out1, out2);
    tex2Dstore(st_integral_1, px_coord, out1);
    tex2Dstore(st_integral_2, px_coord, out2);
}

float4 moveAreaInScreen(float4 uv_area)
{
    uv_area.xz += max(-uv_area.x, 0);
    uv_area.xz += min(1 - uv_area.z, 0);
    uv_area.yw += max(-uv_area.y, 0);
    uv_area.yw += min(1 - uv_area.w, 0);
    return saturate(uv_area);
}

// minx - 1, miny - 1, maxx, maxy
IntegralData getIntegral(uint4 px_coord_area)
{
    // sanitization
    int4 px_coord_area_valid = px_coord_area;
    px_coord_area_valid.xy -= 1;

    IntegralData lu = integralDataFetchSampler(px_coord_area_valid.xy);
    IntegralData lb = integralDataFetchSampler(px_coord_area_valid.xw);
    IntegralData ru = integralDataFetchSampler(px_coord_area_valid.zy);
    IntegralData rb = integralDataFetchSampler(px_coord_area_valid.zw);

    // IntegralData retval;
    // retval.bin1 = (rb.bin1 + lu.bin1) - (lb.bin1 + ru.bin1);
    // retval.bin2 = (rb.bin2 + lu.bin2) - (lb.bin2 + ru.bin2);
    // retval.moments = (rb.moments + lu.moments) - (lb.moments + ru.moments);
    // return retval;

    integralDataAdd(rb, lu);
    integralDataAdd(lb, ru);
    integralDataSub(rb, lb);
    return rb;
}

// ----- Prefix Sum ----- //

// chain+Kogge-Stone+chain sum on one dimension
groupshared IntegralData global_sum[PREFIX_SUM_NTHREADS];
void prefixSumNaive(uint gid, uint tid, bool row_wise)
{
    int dim_size = row_wise ? BUFFER_WIDTH : BUFFER_HEIGHT;
    uint work_size = (dim_size - 1) / PREFIX_SUM_NTHREADS + 1;
    uint offset = tid * work_size;

    // chain sum within partition
    IntegralData part_sum[CACHE_LEN];
    part_sum[0] = integralDataZero();
    for(uint i = 0; i < work_size; ++i)
    {
        uint2 px_coord = row_wise ? uint2(offset + i, gid) : uint2(gid, offset + i);
        part_sum[i + 1] = integralDataFetchStorage(px_coord);
        integralDataAdd(part_sum[i + 1], part_sum[i]);
    }

    // inter-partition Kogge-Stone
    global_sum[tid] = part_sum[work_size - 1];
    for(uint shift = 1; shift < PREFIX_SUM_NTHREADS; shift = shift << 1)
    {
        IntegralData shifted_sum = integralDataZero();
        barrier();
        if(shift <= tid)
            shifted_sum = global_sum[tid - shift];

        barrier();
        integralDataAdd(global_sum[tid], shifted_sum);
    }

    IntegralData prev_global_sum = integralDataZero();
    barrier();
    if(tid > 0)
        prev_global_sum = global_sum[tid - 1];

    // adding back
    for(uint i = 0; i < work_size; ++i)
    {
        if(offset + i >= dim_size)
            break;

        uint2 px_coord = row_wise ? uint2(offset + i, gid) : uint2(gid, offset + i);
        integralDataAdd(part_sum[i + 1], prev_global_sum);
        integralDataStore(px_coord, part_sum[i + 1]);
    }
}

// ----- Tonemapping ----- //

float luma(float3 rgb)
{
    return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b;
}

void assignBin(float val, float max_bin_log, inout IntegralData data)
{
    uint bin = clamp(log(val + 1) * NBINS / max_bin_log, 0, NBINS);  // greater values are omitted
    switch(bin)
    {
        case 0: data.bin1.x = 1; break;
        case 1: data.bin1.y = 1; break;
        case 2: data.bin1.z = 1; break;
        case 3: data.bin1.w = 1; break;
        case 4: data.bin2.x = 1; break;
        case 5: data.bin2.y = 1; break;
        default: break;
    }
}

void calcBinDisplayLevel(IntegralData data, out float disp_level[NBINS + 1])
{
    uint temp_u[NBINS];
    temp_u[0] = data.bin1.x;
    temp_u[1] = data.bin1.y + temp_u[0];
    temp_u[2] = data.bin1.z + temp_u[1];
    temp_u[3] = data.bin1.w + temp_u[2];
    temp_u[4] = data.bin2.x + temp_u[3];
    temp_u[5] = data.bin2.y + temp_u[4];

    disp_level[0] = 0;
    for(uint i = 0; i < NBINS; ++i)
        disp_level[i + 1] = (temp_u[i] / float(temp_u[5]) + fLinearBias) / (1 + NBINS * fLinearBias);
}

// +++++++++++++++++++++++++++++
// Shaders
// +++++++++++++++++++++++++++++

void PS_Binning(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 int_data1 : SV_Target0, out float4 int_data2 : SV_Target1)
{
    float max_bin_log = tex2Dfetch(samp_adapt, uint2(0, 0)).x;
    max_bin_log = fMaxValLog;

    float4 color = tex2D(ReShade::BackBuffer, uv);
    float val = luma(color.rgb);

    IntegralData int_data = integralDataZero();
    int_data.moments = float2(val, val * val);
    assignBin(val, max_bin_log, int_data);

    integralDataPack(int_data, int_data1, int_data2);
}

void CS_SumRow(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    prefixSumNaive(gid.x, tid.x, true);
}

void CS_SumCol(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    prefixSumNaive(gid.x, tid.x, false);
}

void PS_Display(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    float max_bin_log = tex2Dfetch(samp_adapt, uint2(0, 0)).x;
    max_bin_log = fMaxValLog;

    IntegralData d = integralDataFetchSampler(uv * BUFFER_SCREEN_SIZE);

    color = tex2D(ReShade::BackBuffer, uv);
    float val = luma(color.rgb);
    float logval = log(val + 1);
    
    float sum = 0;
    float weightsum = 0;
    for(uint scale = 0; scale < fFineScale; ++scale)
    {
        float2 window_size = 1 / float(1 << scale);
        float4 uv_area = moveAreaInScreen(float4(uv - window_size * 0.5, uv + window_size * 0.5));
        uint4 px_coord_area = (uv_area * BUFFER_SCREEN_SIZE.xyxy);
        px_coord_area.zw = min(px_coord_area.zw, BUFFER_SCREEN_SIZE - 1);

        IntegralData int_data = getIntegral(px_coord_area);
        uint px_count = (px_coord_area.z - px_coord_area.x + 1) * (px_coord_area.w - px_coord_area.y + 1);

        // "texture area" score
        float variance = (int_data.moments.y - int_data.moments.x * int_data.moments.x) / float(px_count);
        float a = 1 - fVarSensitivity / (variance * variance + fVarSensitivity);

        // piecewise linear mapping
        float disp_level[NBINS + 1];
        calcBinDisplayLevel(int_data, disp_level);
        float whatdoicallthis = logval * NBINS / max_bin_log;
        uint bin = clamp(whatdoicallthis, 0, NBINS - 1);
        float u = lerp(disp_level[bin], disp_level[bin + 1], saturate(whatdoicallthis - bin / float(NBINS)));

        sum += a * u;
        weightsum += a;
    }

    float val_target = sum / (weightsum + 1e-8);
    color *= val_target / (val + 1e-8);
    color = saturate(color);
}

void CS_Adapt(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    float2 uv_center = fAdaptAreaOffset;
    float4 uv_area = saturate(float4(uv_center - fAdaptAreaSize * 0.5, uv_center + fAdaptAreaSize * 0.5));
    uint4 px_coord_area = uv_area * BUFFER_SCREEN_SIZE.xyxy;
    px_coord_area.zw = min(px_coord_area.zw, BUFFER_SCREEN_SIZE - 1);
    
    IntegralData int_data = getIntegral(px_coord_area);
    float mean = int_data.moments.x / float((px_coord_area.z - px_coord_area.x + 1) * (px_coord_area.w - px_coord_area.y + 1));

    float max_bin_log_prev = tex2Dfetch(st_adapt, uint2(0, 0)).x;
    float max_bin_log_target = clamp(log(mean * fTargetMaxBinMul + 1), fMaxBinLogRange.x, fMaxBinLogRange.y);
    float max_bin_log_new = lerp(max_bin_log_prev, max_bin_log_target, saturate(fFrameTime * 0.001 * fAdaptSpeed));

    max_bin_log_new = (isnan(max_bin_log_new) || isinf(max_bin_log_new)) ? 0.0 : max_bin_log_new;
    tex2Dstore(st_adapt, uint2(0, 0), max_bin_log_new);
}

technique MSHIST
{
    pass
    {
        VertexShader  = PostProcessVS;
        PixelShader   = PS_Binning;
        RenderTarget0 = tex_integral_1;
        RenderTarget1 = tex_integral_2;
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
    pass
    {
        ComputeShader = CS_Adapt<1, 1>;
        DispatchSizeX = 1;
		DispatchSizeY = 1;
    }
}