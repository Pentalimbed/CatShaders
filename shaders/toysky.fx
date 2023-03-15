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
#define MULTISCATTER_LUT_SIZE int2(MULTISCATTER_LUT_WIDTH, MULTISCATTER_LUT_HEIGHT)

#ifndef SKY_LUT_WIDTH
#   define SKY_LUT_WIDTH 200
#endif
#ifndef SKY_LUT_HEIGHT
#   define SKY_LUT_HEIGHT 200
#endif
#define SKY_LUT_SIZE int2(SKY_LUT_WIDTH, SKY_LUT_HEIGHT)


static const float PI = 3.14159265358;


uniform float fFarPlane < source = "Far"; >;
uniform float fNearPlane < source = "Near"; >;

uniform float3 fCamPos < source = "position"; >;

uniform float4x4 fInvViewProjMatrix < source = "InvViewProjMatrix"; >;


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

uniform float3 fGroundAlbedo <
	ui_type = "color";
    ui_label = "Ground Albedo";
    ui_category = "World";
> = 0.3;

uniform float2 fSunDir <
	ui_type = "slider";
    ui_label = "Sun Direction";
    ui_category = "World";
    ui_min = 0; ui_max = float2(360, 180);
    ui_step = 0.1;
> = float2(0, 45);

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

uniform int iMultiscatterStep <
	ui_type = "slider";
    ui_label = "Multiscattering Steps";
    ui_category = "Quality";
    ui_min = 1; ui_max = 50;
    ui_step = 1;
> = 20;

uniform int iMultiscatterSqrtSamples <
	ui_type = "slider";
    ui_label = "Multiscattering Sqrt Sample";
    ui_category = "Quality";
    ui_min = 1; ui_max = 16;
    ui_step = 1;
> = 8;

uniform int iSkyScatterStep <
	ui_type = "slider";
    ui_label = "Final Scattering Steps";
    ui_category = "Quality";
    ui_min = 1; ui_max = 50;
    ui_step = 1;
> = 32;


namespace Skyrim
{
texture tex_depth : TARGET_MAIN_DEPTH;
sampler samp_depth { Texture = tex_depth; };
}

texture tex_transmittance_lut {Width = TRANSMITTANCE_LUT_WIDTH; Height = TRANSMITTANCE_LUT_HEIGHT; Format = RGBA16F;};
sampler samp_transmittance_lut {Texture = tex_transmittance_lut;};

texture tex_multiscatter_lut {Width = MULTISCATTER_LUT_WIDTH; Height = MULTISCATTER_LUT_HEIGHT; Format = RGBA16F;};
sampler samp_multiscatter_lut {Texture = tex_multiscatter_lut;};

texture tex_sky_lut {Width = SKY_LUT_WIDTH; Height = SKY_LUT_HEIGHT; Format = RGBA16F;};
sampler samp_sky_lut {Texture = tex_sky_lut;};


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

float3 getSphericalDir(float theta, float phi)
{
    float cos_phi, sin_phi, cos_theta, sin_theta;
    sincos(phi, sin_phi, cos_phi);
    sincos(theta, sin_theta, cos_theta);
    return float3(sin_phi * sin_theta, cos_phi, sin_phi * cos_theta);
}

void getScatteringValues(float3 pos, 
                         out float3 rayleigh_scatter, 
                         out float mie_scatter,
                         out float3 extinction)
{
    float altitude_km = (length(pos) - fGroundRadiusMM) * 1000.0;
    float rayleigh_density = exp(-altitude_km / 8.0);
    float mie_density = exp(-altitude_km / 1.2);
    
    rayleigh_scatter = fRayleighScatterCoeff * fRayleighScatterScale * rayleigh_density;
    float rayleigh_absorp = fRayleighAbsorpScale * rayleigh_density;

    mie_scatter = fMieScatterScale * mie_density;
    float mie_absorp = fMieAbsorpScale * mie_density;

    float3 ozone_absorp = fOzoneAbsorpCoeff * fOzoneAbsorpScale * max(0, 1 - abs(altitude_km * 25.0) / 15.0);

    extinction = rayleigh_scatter + rayleigh_absorp + mie_scatter + mie_absorp + ozone_absorp;
}

float getMiePhase(float cosTheta) {
    const float g = 0.8;
    const float scale = 3.0/(8.0*PI);
    
    float num = (1.0-g*g)*(1.0+cosTheta*cosTheta);
    float denom = (2.0+g*g)*pow((1.0 + g*g - 2.0*g*cosTheta), 1.5);
    
    return scale*num/denom;
}

float getRayleighPhase(float cosTheta) {
    const float k = 3.0/(16.0*PI);
    return k*(1.0+cosTheta*cosTheta);
}

float3 sampleLUT(sampler samp, float3 pos, float3 sun_dir)
{
    float height = length(pos);
    float3 up = pos / height;
    float sun_cos_zenith = dot(sun_dir, up);
    float2 uv = float2(saturate(0.5 + 0.5 * sun_cos_zenith), saturate((height - fGroundRadiusMM) / fAtmosThicknessMM));
    return tex2Dlod(samp, float4(uv, 0, 0)).rgb;
}

// -------------- Transmittance LUT -------------- //
float3 getSunTransmittance(float3 pos, float3 sun_dir)
{
    // ground occlusion
    if(rayIntersectSphere(pos, sun_dir, fGroundRadiusMM) > 0.0)
        return 0;

    float atmos_dist = rayIntersectSphere(pos, sun_dir, fGroundRadiusMM + fAtmosThicknessMM);

    float t = 0.0;
    float3 transmittance = 1;
    for(int i = 0; i < iSunTransmittanceStep; ++i)
    {
        float new_t = (i + 0.3) / iSunTransmittanceStep * atmos_dist;
        float dt = new_t - t;
        t = new_t;
        float3 new_pos = pos + t * sun_dir;

        float3 rayleigh_scatter, extinction;
        float mie_scatter;
        getScatteringValues(new_pos, rayleigh_scatter, mie_scatter, extinction);

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
    float height = fGroundRadiusMM + fAtmosThicknessMM * uv.y;

    float3 pos = float3(0, height, 0);
    float3 sun_dir = normalize(float3(0, sun_cos_theta, -sqrt(1 - sun_cos_theta * sun_cos_theta)));

    color = float4(getSunTransmittance(pos, sun_dir), 1.0);
}

// -------------- Multiscatter LUT -------------- //

void getMultiScatterValues(
    float3 pos, float3 sun_dir,
    out float3 lum_total, out float3 f_ms)
{
    lum_total = 0;
    f_ms = 0;

    float rcp_samples = rcp(iMultiscatterSqrtSamples * iMultiscatterSqrtSamples);
    for(int i = 0; i < iMultiscatterSqrtSamples; ++i)
        for(int j = 0; j < iMultiscatterSqrtSamples; ++j)
        {
            float theta = (i + 0.5) * PI / iMultiscatterSqrtSamples;
            float phi = acos(1.0 - 2.0 * (j + 0.5) / iMultiscatterSqrtSamples);
            float3 ray_dir = getSphericalDir(theta, phi);

            float ground_dist = rayIntersectSphere(pos, ray_dir, fGroundRadiusMM);
            float atmos_dist = rayIntersectSphere(pos, ray_dir, fGroundRadiusMM + fAtmosThicknessMM);
            float t_max = ground_dist > 0 ? ground_dist : atmos_dist;

            float cos_theta = dot(ray_dir, sun_dir);
            float mie_phase = getMiePhase(cos_theta);
            float rayleigh_phase = getRayleighPhase(-cos_theta);

            float3 lum = 0, lum_factor = 0, transmittance = 1;
            float t = 0;
            for(float step = 0; step < iMultiscatterStep; ++step)
            {
                float new_t = (step + 0.3) / iMultiscatterStep * t_max;
                float dt = new_t - t;
                t = new_t;
                float3 new_pos = pos + t * ray_dir;

                float3 rayleigh_scatter, extinction;
                float mie_scatter;
                getScatteringValues(new_pos, rayleigh_scatter, mie_scatter, extinction);

                float3 sample_transmittance = exp(-dt * extinction);

                float3 scatter_no_phase = rayleigh_scatter + mie_scatter;
                float3 scatter_f = (scatter_no_phase - scatter_no_phase * sample_transmittance) / extinction;
                lum_factor += transmittance * scatter_f;

                float3 sun_transmittance = sampleLUT(samp_transmittance_lut, new_pos, sun_dir);

                float3 rayleigh_inscatter = rayleigh_scatter * rayleigh_phase;
                float mie_inscatter = mie_scatter * mie_phase;
                float3 in_scatter = (rayleigh_inscatter + mie_inscatter) * sun_transmittance;

                float3 scatter_integeral = (in_scatter - in_scatter * sample_transmittance) / extinction;

                lum += scatter_integeral * transmittance;
                transmittance *= sample_transmittance;
            }

            if(ground_dist > 0)
            {
                float3 hit_pos = pos + ground_dist * ray_dir;
                if(dot(pos, sun_dir) > 0)
                {
                    hit_pos = normalize(hit_pos) * fGroundRadiusMM;
                    lum += transmittance * fGroundAlbedo * sampleLUT(samp_transmittance_lut, hit_pos, sun_dir);
                }
            }
            
            f_ms += lum_factor * rcp_samples;
            lum_total += lum * rcp_samples;
        }
}

void PS_Multiscatter(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    float sun_cos_theta = 2.0 * uv.x - 1.0;
    // float sun_theta = acos(sun_cos_theta);
    float height = fGroundRadiusMM + fAtmosThicknessMM * uv.y;

    float3 pos = float3(0, height, 0);
    float3 sun_dir = normalize(float3(0, sun_cos_theta, -sqrt(1 - sun_cos_theta * sun_cos_theta)));

    float3 lum, f_ms;
    getMultiScatterValues(pos, sun_dir, lum, f_ms);

    float3 psi = lum / (1 - f_ms);
    color = float4(psi, 1);
}

// -------------- Skyview LUT -------------- //

float3 raymarchScatter(float3 pos, float3 ray_dir, float3 sun_dir, float t_max)
{
    float cos_theta = dot(ray_dir, sun_dir);

    float mie_phase = getMiePhase(cos_theta);
    float rayleigh_phase = getRayleighPhase(-cos_theta);

    float3 lum = 0, transmittance = 1;
    float t = 0;
    for(int i = 0; i < iSkyScatterStep; ++i)
    {
        float new_t = (i + 0.3) / iSkyScatterStep * t_max;
        float dt = new_t - t;
        t = new_t;
        float3 new_pos = pos + t * ray_dir;

        float3 rayleigh_scatter, extinction;
        float mie_scatter;
        getScatteringValues(new_pos, rayleigh_scatter, mie_scatter, extinction);

        float3 sample_transmittance = exp(-dt * extinction);

        float3 sun_transmittance = sampleLUT(samp_transmittance_lut, new_pos, sun_dir);
        float3 psi_ms = sampleLUT(samp_multiscatter_lut, new_pos, sun_dir);
                
        float3 rayleigh_inscatter = rayleigh_scatter * (rayleigh_phase * sun_transmittance + psi_ms);
        float3 mie_inscatter = mie_scatter * (mie_phase * sun_transmittance + psi_ms);
        float3 in_scatter = rayleigh_inscatter + mie_inscatter;

        float3 scatter_integeral = in_scatter * (1 - sample_transmittance) / extinction;

        lum += scatter_integeral * sample_transmittance;
        transmittance *= sample_transmittance;
    }
    return lum;
}

float3 jodieReinhardTonemap(float3 c){
    // From: https://www.shadertoy.com/view/tdSXzD
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    float3 tc = c / (c + 1.0);
    return lerp(c / (l + 1.0), tc, tc);
}

void PS_Skyview(
    in float4 vpos : SV_Position, in float2 uv : TEXCOORD0,
    out float4 color : SV_Target0)
{
    float azimuth_angle = (uv.x - 0.5) * 2 * PI;

    // non-linear altitude mapping
    float coord = 1 - 2 * uv.y;
    float adj_v = coord * coord * sign(uv.y - 0.5);

    float3 view_pos = float3(0, 0.0002 + fGroundRadiusMM, 0);
    float height = view_pos.y;
    float3 up = float3(0, 1, 0);
    float horizon_angle = acos(sqrt(height * height - fGroundRadiusMM * fGroundRadiusMM) / height) - 0.5 * PI;
    float altitude_angle = adj_v * 0.5 * PI - horizon_angle;

    float3 ray_dir = float3(cos(altitude_angle) * sin(azimuth_angle), sin(altitude_angle), -cos(altitude_angle) * cos(azimuth_angle));
    float3 sun_dir = getSphericalDir(radians(fSunDir.x), radians(fSunDir.y));

    float ground_dist = rayIntersectSphere(view_pos, ray_dir, fGroundRadiusMM);
    float atmos_dist = rayIntersectSphere(view_pos, ray_dir, fGroundRadiusMM + fAtmosThicknessMM);
    float t_max = ground_dist > 0.0 ? ground_dist : atmos_dist;

    float3 lum = raymarchScatter(view_pos, ray_dir, sun_dir, t_max);

    color = float4(lum, 1);
}

technique PhysicalSky
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Transmittance;
        RenderTarget0 = tex_transmittance_lut;
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Multiscatter;
        RenderTarget0 = tex_multiscatter_lut;
    }
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Skyview;
        RenderTarget0 = tex_sky_lut;
    }
}