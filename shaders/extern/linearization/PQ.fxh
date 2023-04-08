#pragma once

// SPDX-License-Identifier: Unlicense
#include "ReShade.fxh"

// 1.0 = 100nits, 100.0 = 10knits
#ifndef _MAX_PQ
#define _MAX_PQ 100.0
#endif

// https://Unity-Technologies/FPSSample
static const float PQ_N  = (2610.0 / 4096.0 / 4.0);
static const float PQ_M  = (2523.0 / 4096.0 * 128.0);
static const float PQ_C1 = (3424.0 / 4096.0);
static const float PQ_C2 = (2413.0 / 4096.0 * 32.0);
static const float PQ_C3 = (2392.0 / 4096.0 * 32.0);

float3 PQToLinear(float3 pq, float max_pq)
{
    pq = pow(abs(pq / max_pq), PQ_N);
    float3 nd = (PQ_C1 + PQ_C2 * pq) / (1.0 + PQ_C3 * pq);
    float3 lin = pow(abs(pq), PQ_M);

    return lin;
}

float3 PQToLinear(float3 pq)
{
    return PQToLinear(pq, _MAX_PQ);
}

float4 PQToLinear(float4 pq, float max_pq)
{
    return float4(PQToLinear(pq.rgb, max_pq), pq.a);
}

float4 PQToLinear(float4 pq)
{
    return PQToLinear(pq, _MAX_PQ);
}

float3 LinearToPQ(float3 lin, float max_pq)
{
    lin = pow(abs(lin), 1.0/PQ_M);
    float3 nd = max(lin - PQ_C1, 0.0) / (PQ_C2 - (PQ_C3 * lin));
    float3 pq = pow(abs(nd), 1.0/PQ_N) * max_pq;

    return pq;
}

float3 LinearToPQ(float3 lin)
{
    return LinearToPQ(lin, _MAX_PQ);
}

float4 LinearToPQ(float4 lin, float max_pq)
{
    return float4(LinearToPQ(lin, max_pq).rgb, lin.a);
}

float4 LinearToPQ(float4 lin)
{
    return LinearToPQ(lin, _MAX_PQ);
}
