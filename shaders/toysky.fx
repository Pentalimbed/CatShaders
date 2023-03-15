// src: https://www.shadertoy.com/view/fd2fWc
// src fr: https://github.com/sebh/UnrealEngineSkyAtmosphere

#include "ReShade.fxh"

#ifndef TRANSMITTANCE_LUT_WIDTH
#   define TRANSMITTANCE_LUT_WIDTH 256
#endif
#ifndef TRANSMITTANCE_LUT_HEIGHT
#   define TRANSMITTANCE_LUT_HEIGHT 64
#endif
#define TRANSMITTANCE_LUT_SIZE int2(TRANSMITTANCE_LUT_WIDTH, TRANSMITTANCE_LUT_HEIGHT)

#ifndef MULTISCATTER_LUT_WIDTH
#   define MULTISCATTER_LUT_WIDTH 32
#endif
#ifndef MULTISCATTER_LUT_HEIGHT
#   define MULTISCATTER_LUT_HEIGHT 32
#endif
#define TRANSMITTANCE_LUT_SIZE int2(MULTISCATTER_LUT_WIDTH, MULTISCATTER_LUT_HEIGHT)

#ifndef SKY_LUT_WIDTH
#   define SKY_LUT_WIDTH 200
#endif
#ifndef SKY_LUT_HEIGHT
#   define SKY_LUT_HEIGHT 200
#endif
#define TRANSMITTANCE_LUT_SIZE int2(SKY_LUT_WIDTH, SKY_LUT_HEIGHT)


uniform float3 fCampos_mm < source = "pos_mmition"; >;


uniform float fGroundRadiusMM <
	ui_type = "slider";
    ui_label = "Ground Radius (megameter)";
    ui_category = "World";
    ui_min = 0.0; ui_max = 10.0;
    ui_step = 0.01;
> = 6.36;

uniform float fAtmosThicknessMM <
	ui_type = "slider";
    ui_label = "Atmosphere Thickness (megameter)";
    ui_category = "World";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.001;
> = 0.1;

uniform float3 fRayleighScatterCoeff <
	ui_type = "color";
    ui_label = "Rayleigh Scattering Color";
    ui_category = "Atmosphere";
> = float3(0.16, 0.374, 0.913);

uniform float fRayleighScatterScale <
	ui_type = "input";
    ui_label = "Rayleigh Scattering Scale";
    ui_category = "Atmosphere";
    ui_step = 0.01;
> = 36.24;

uniform float fRayleighAbsorpScale <
	ui_type = "input";
    ui_label = "Rayleigh Absorption Scale";
    ui_category = "Atmosphere";
    ui_step = 0.01;
> = 0.0;

uniform float fMieScatterScale <
	ui_type = "input";
    ui_label = "Mie Scattering Scale";
    ui_category = "Atmosphere";
    ui_step = 0.01;
> = 3.996;

uniform float fMieAbsorpScale <
	ui_type = "input";
    ui_label = "Mie Absorption Scale";
    ui_category = "Atmosphere";
    ui_step = 0.01;
> = 4.4;

uniform float3 fOzoneAbsorpCoeff <
	ui_type = "color";
    ui_label = "Ozone Absorption Color";
    ui_category = "Atmosphere";
> = float3(0.326, 0.944, 0.044);

uniform float fOzoneAbsorpScale <
	ui_type = "input";
    ui_label = "Ozone Absorption Scale";
    ui_category = "Atmosphere";
    ui_step = 0.01;
> = 1.99;

uniform int iSunTransmittanceStep <
	ui_type = "slider";
    ui_label = "Transmittance Steps";
    ui_category = "Quality";
    ui_min = 1; ui_max = 50;
    ui_step = 1;
> = 40;

texture tex_transmittance_lut {Width = TRANSMITTANCE_LUT_WIDTH; Height = TRANSMITTANCE_LUT_HEIGHT; Format = RGBA16F};
sampler samp_transmittance_lut {Texture = tex_transmittance_lut;};

// return distance to sphere surface
// src: https://gamedev.stackexchange.com/questions/96459/fast-ray-sphere-collision-code.
float rayIntersectSphere(float3 orig, float3 dir, float rad) {
    float b = dot(orig, dir);
    float c = dot(orig, orig) - rad*rad;
    if (c > 0.0f && b > 0.0) return -1.0;
    float discr = b*b - c;
    if (discr < 0.0) return -1.0;
    // Special case: inside sphere, use far discriminant
    if (discr > b*b) return (-b + sqrt(discr));
    return -b - sqrt(discr);
}

void getScatteringValues(float3 pos_mm, 
                         out float3 rayleigh_scatter, 
                         out float mie_scatter,
                         out float3 extinction)
{
    float altitude_km = (length(pos_mm) - fGroundRadiusMM) * 1000.0;
    float rayleigh_density = exp(-altitude_km / 8.0);
    float mie_density = exp(-altitude_km / 1.2);
    
    rayleigh_scatter = fRayleighScatterCoeff * fRayleighScatterScale * rayleigh_density;
    float rayleigh_absorp = fRayleighAbsorpScale * rayleigh_density;

    mie_scatter = fMieScatterScale * mie_density;
    float mie_absorp = fMieAbsorpScale * mie_density;

    float3 ozone_absorp = fOzoneAbsorpCoeff * fOzoneAbsorpScale * max(0, 1 - abs(altitude_km * 25.0) / 15.0);

    extinction = rayleigh_scatter + rayleigh_absorp + mie_scatter + mie_absorp + ozone_absorp;
}

// -------------- Transmittance LUT -------------- //
float3 getSunTransmittance(float3 pos_mm, float3 sun_dir)
{
    // ground occlusion
    if(rayIntersectSphere(pos_mm, sun_dir, fGroundRadiusMM) > 0.0)
        return 0;

    float atmos_dist = rayIntersectSphere(pos_mm, sun_dir, fGroundRadiusMM + fAtmosThicknessMM);

    float t = 0.0;
    float3 transmittance = 1;
    for(int i = 0; i < iSunTransmittanceStep; ++i)
    {
        float new_t = (i + 0.3) / iSunTransmittanceStep * atmos_dist;
        float dt = new_t - t;
        t = new_t;
        float3 new_pos_mm = pos_mm + t * sun_dir;

        float3 rayleigh_scatter, extinction;
        float mie_scatter;
        getScatteringValues(new_pos_mm, rayleigh_scatter, mie_scatter, extinction);

        transmittance *= exp(-dt * extinction);
    }
    return transmittance;
}

void PS_Transmittance(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    float sun_cos_theta = 2.0 * uv.x - 1.0;
    // float sun_theta = acos(sun_cos_theta);
    float height = ground + fAtmosThicknessMM * uv.y;

    float3 pos = float3(0, height, 0);
    float3 sun_dir = normalize(float3(0, sun_cos_theta, -sqrt(1 - sun_cos_theta * sun_cos_theta)));

    color = float4(getSunTransmittance(pos, sun_dir), 1.0);
}

technique PhysicalSky
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Transmittance;
        RenderTarget0 = tex_transmittance_lut;
    }
}