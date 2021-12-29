Shader "Feral_Pug/SkyBox/MyProceduralSkybox"
{
    Properties
    {
        [Header(SkyAndSun)]
        [KeywordEnum(None, Simple, High Quality)] _SunDisk ("Sun", Int) = 2
        _SunSize ("Sun Size", Range(0,1)) = 0.04
        _SunSizeConvergence("Sun Size Convergence", Range(1,10)) = 5
        _AtmosphereThickness ("Atmosphere Thickness", Range(0,5)) = 1.0
        _SkyTint ("Sky Tint", Color) = (.5, .5, .5, 1)
        _GroundColor ("Ground", Color) = (.369, .349, .341, 1)
        _Exposure("Exposure", Range(0, 8)) = 1.3
        _NightStartHeight("Night Start Height", Range(-1, 1)) = -.1
        _NightEndHeight("Night End Height", Range(-1, 1)) = -.2
        _SkyFadeStart("Sky Fade Start", Range(-1, 1)) = .05
        _SkyFadeEnd("Sky End Start", Range(-1, 1)) = -.05

        [Header (Stars)]
        _StarTex("Star Tex", 2D) = "black" {}
        _StarBending("Star Bending", Range(0, 1)) = 1
        _StarBrightness("Star Brightness", Range(0, 100)) = 8.5
        _TwinkleTex ("Twinkle Noise Tex", 2D) = "black" {}
        _TwinkleBoost("Twinkle Boost", Range(0, 1)) = .25
        _TwinkleSpeed("Twinkle Speed", Range(0, 1)) = .1
    }
    SubShader
    {
        Tags { "Queue"="Background" "RenderType"="Background" "PreviewType"="Skybox" }
        Cull Off ZWrite Off

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"
            #include "Lighting.cginc"
            #include "Includes/Scattering.cginc"

            #pragma multi_compile_local _SUNDISK_NONE _SUNDISK_SIMPLE _SUNDISK_HIGH_QUALITY

            uniform half _Exposure;     // HDR exposure
            uniform half3 _GroundColor;
            uniform half _SunSize;
            uniform half _SunSizeConvergence;
            uniform half3 _SkyTint;
            uniform half _AtmosphereThickness;
            uniform half _NightStartHeight, _NightEndHeight;
            uniform half _SkyFadeStart, _SkyFadeEnd;

            uniform sampler2D _StarTex, _TwinkleTex;
            uniform float4 _StarTex_ST, _TwinkleTex_ST;
            uniform float _StarBending, _StarBrightness;
            uniform float _TwinkleBoost, _TwinkleSpeed;

            struct appdata
            {
                float4 vertex : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float4  pos             : SV_POSITION;
                float3 worldPos : TEXCOORD0;
                #if SKYBOX_SUNDISK == SKYBOX_SUNDISK_HQ
                    // for HQ sun disk, we need vertex itself to calculate ray-dir per-pixel
                    float3  vertex          : TEXCOORD1;
                #elif SKYBOX_SUNDISK == SKYBOX_SUNDISK_SIMPLE
                    half3   rayDir          : TEXCOORD1;
                #else
                    // as we dont need sun disk we need just rayDir.y (sky/ground threshold)
                    half    skyGroundFactor : TEXCOORD1;
                #endif

                    // calculate sky colors in vprog
                    half3   groundColor     : TEXCOORD2;
                    half3   skyColor        : TEXCOORD3;

                #if SKYBOX_SUNDISK != SKYBOX_SUNDISK_NONE
                    half3   sunColor        : TEXCOORD4;
                #endif

                UNITY_VERTEX_OUTPUT_STEREO
            };



            v2f vert (appdata v)
            {
                v2f OUT;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(OUT);
                OUT.pos = UnityObjectToClipPos(v.vertex);
                OUT.worldPos = mul(unity_ObjectToWorld, v.vertex);

                float3 kSkyTintInGammaSpace = COLOR_2_GAMMA(_SkyTint); // convert tint from Linear back to Gamma
                float3 kScatteringWavelength = lerp (
                    kDefaultScatteringWavelength-kVariableRangeForScatteringWavelength,
                    kDefaultScatteringWavelength+kVariableRangeForScatteringWavelength,
                    half3(1,1,1) - kSkyTintInGammaSpace); // using Tint in sRGB gamma allows for more visually linear interpolation and to keep (.5) at (128, gray in sRGB) point
                float3 kInvWavelength = 1.0 / pow(kScatteringWavelength, 4);

                float kKrESun = kRAYLEIGH * kSUN_BRIGHTNESS;
                float kKr4PI = kRAYLEIGH * 4.0 * 3.14159265;

                float3 cameraPos = float3(0,kInnerRadius + kCameraHeight,0);    // The camera's current position

                // Get the ray from the camera to the vertex and its length (which is the far point of the ray passing through the atmosphere)
                float3 eyeRay = normalize(mul((float3x3)unity_ObjectToWorld, v.vertex.xyz));

                float far = 0.0;
                half3 cIn, cOut;

                if(eyeRay.y >= 0.0)
                {
                    // Sky
                    // Calculate the length of the "atmosphere"
                    far = sqrt(kOuterRadius2 + kInnerRadius2 * eyeRay.y * eyeRay.y - kInnerRadius2) - kInnerRadius * eyeRay.y;

                    float3 pos = cameraPos + far * eyeRay;

                    // Calculate the ray's starting position, then calculate its scattering offset
                    float height = kInnerRadius + kCameraHeight;
                    float depth = exp(kScaleOverScaleDepth * (-kCameraHeight));
                    float startAngle = dot(eyeRay, cameraPos) / height;
                    float startOffset = depth*scale(startAngle);


                    // Initialize the scattering loop variables
                    float sampleLength = far / kSamples;
                    float scaledLength = sampleLength * kScale;
                    float3 sampleRay = eyeRay * sampleLength;
                    float3 samplePoint = cameraPos + sampleRay * 0.5;

                    // Now loop through the sample rays
                    float3 frontColor = float3(0.0, 0.0, 0.0);
                    // Weird workaround: WP8 and desktop FL_9_3 do not like the for loop here
                    // (but an almost identical loop is perfectly fine in the ground calculations below)
                    // Just unrolling this manually seems to make everything fine again.
    //              for(int i=0; i<int(kSamples); i++)
                    {
                        float height = length(samplePoint);
                        float depth = exp(kScaleOverScaleDepth * (kInnerRadius - height));
                        float lightAngle = dot(_WorldSpaceLightPos0.xyz, samplePoint) / height;
                        float cameraAngle = dot(eyeRay, samplePoint) / height;
                        float scatter = (startOffset + depth*(scale(lightAngle) - scale(cameraAngle)));
                        float3 attenuate = exp(-clamp(scatter, 0.0, kMAX_SCATTER) * (kInvWavelength * kKr4PI + kKm4PI));

                        frontColor += attenuate * (depth * scaledLength);
                        samplePoint += sampleRay;
                    }
                    {
                        float height = length(samplePoint);
                        float depth = exp(kScaleOverScaleDepth * (kInnerRadius - height));
                        float lightAngle = dot(_WorldSpaceLightPos0.xyz, samplePoint) / height;
                        float cameraAngle = dot(eyeRay, samplePoint) / height;
                        float scatter = (startOffset + depth*(scale(lightAngle) - scale(cameraAngle)));
                        float3 attenuate = exp(-clamp(scatter, 0.0, kMAX_SCATTER) * (kInvWavelength * kKr4PI + kKm4PI));

                        frontColor += attenuate * (depth * scaledLength);
                        samplePoint += sampleRay;
                    }



                    // Finally, scale the Mie and Rayleigh colors and set up the varying variables for the pixel shader
                    cIn = frontColor * (kInvWavelength * kKrESun);
                    cOut = frontColor * kKmESun;
                }
                else
                {
                    // Ground
                    far = (-kCameraHeight) / (min(-0.001, eyeRay.y));

                    float3 pos = cameraPos + far * eyeRay;

                    // Calculate the ray's starting position, then calculate its scattering offset
                    float depth = exp((-kCameraHeight) * (1.0/kScaleDepth));
                    float cameraAngle = dot(-eyeRay, pos);
                    float lightAngle = dot(_WorldSpaceLightPos0.xyz, pos);
                    float cameraScale = scale(cameraAngle);
                    float lightScale = scale(lightAngle);
                    float cameraOffset = depth*cameraScale;
                    float temp = (lightScale + cameraScale);

                    // Initialize the scattering loop variables
                    float sampleLength = far / kSamples;
                    float scaledLength = sampleLength * kScale;
                    float3 sampleRay = eyeRay * sampleLength;
                    float3 samplePoint = cameraPos + sampleRay * 0.5;

                    // Now loop through the sample rays
                    float3 frontColor = float3(0.0, 0.0, 0.0);
                    float3 attenuate;
    //              for(int i=0; i<int(kSamples); i++) // Loop removed because we kept hitting SM2.0 temp variable limits. Doesn't affect the image too much.
                    {
                        float height = length(samplePoint);
                        float depth = exp(kScaleOverScaleDepth * (kInnerRadius - height));
                        float scatter = depth*temp - cameraOffset;
                        attenuate = exp(-clamp(scatter, 0.0, kMAX_SCATTER) * (kInvWavelength * kKr4PI + kKm4PI));
                        frontColor += attenuate * (depth * scaledLength);
                        samplePoint += sampleRay;
                    }

                    cIn = frontColor * (kInvWavelength * kKrESun + kKmESun);
                    cOut = clamp(attenuate, 0.0, 1.0);
                }

                #if SKYBOX_SUNDISK == SKYBOX_SUNDISK_HQ
                    OUT.vertex          = -eyeRay;
                #elif SKYBOX_SUNDISK == SKYBOX_SUNDISK_SIMPLE
                    OUT.rayDir          = half3(-eyeRay);
                #else
                    OUT.skyGroundFactor = -eyeRay.y / SKY_GROUND_THRESHOLD;
                #endif

                // if we want to calculate color in vprog:
                // 1. in case of linear: multiply by _Exposure in here (even in case of lerp it will be common multiplier, so we can skip mul in fshader)
                // 2. in case of gamma and SKYBOX_COLOR_IN_TARGET_COLOR_SPACE: do sqrt right away instead of doing that in fshader

                OUT.groundColor = _Exposure * (cIn + COLOR_2_LINEAR(_GroundColor) * cOut);
                OUT.skyColor    = _Exposure * (cIn * getRayleighPhase(_WorldSpaceLightPos0.xyz, -eyeRay));

                #if SKYBOX_SUNDISK != SKYBOX_SUNDISK_NONE
                    // The sun should have a stable intensity in its course in the sky. Moreover it should match the highlight of a purely specular material.
                    // This matching was done using the standard shader BRDF1 on the 5/31/2017
                    // Finally we want the sun to be always bright even in LDR thus the normalization of the lightColor for low intensity.
                    half lightColorIntensity = clamp(length(_LightColor0.xyz), 0.25, 1);
                    #if SKYBOX_SUNDISK == SKYBOX_SUNDISK_SIMPLE
                        OUT.sunColor    = kSimpleSundiskIntensityFactor * saturate(cOut * kSunScale) * _LightColor0.xyz / lightColorIntensity;
                    #else // SKYBOX_SUNDISK_HQ
                        OUT.sunColor    = kHDSundiskIntensityFactor * saturate(cOut) * _LightColor0.xyz / lightColorIntensity;
                    #endif

                #endif

                #if defined(UNITY_COLORSPACE_GAMMA) && SKYBOX_COLOR_IN_TARGET_COLOR_SPACE
                    OUT.groundColor = sqrt(OUT.groundColor);
                    OUT.skyColor    = sqrt(OUT.skyColor);
                    #if SKYBOX_SUNDISK != SKYBOX_SUNDISK_NONE
                        OUT.sunColor= sqrt(OUT.sunColor);
                    #endif
                #endif

                return OUT;
            }

            float Remap(float In, float2 InMinMax, float2 OutMinMax)
            {
                return OutMinMax.x + (In - InMinMax.x) * (OutMinMax.y - OutMinMax.x) / (InMinMax.y - InMinMax.x);
            }

            fixed4 frag (v2f IN) : SV_Target
            {
                //first off we declare some values and set up some stuff that will get used a lot in the shader
                float4 col = float4(0, 0, 0, 0);

                //first off we have to make our positions fit a sphere
                float3 normWorldPos = normalize(IN.worldPos);

                //this sets up where things will start to fade out along the horizon. The values allow us to give it some range so it fades out
                //we have to do 1 minus because the start fade value is actauly higher then the end. You could do the dot with down but I like this better
                float horizonValue = dot(normWorldPos, float3(0, 1, 0));
                horizonValue = 1 - saturate(Remap(horizonValue, float2(_SkyFadeStart, _SkyFadeEnd), float2(0, 1)));

                //grab the sun position
                float3 sunPos = _WorldSpaceLightPos0.xyz;

                //and then do a similar method as the horizon to figure out when things should transistion to the night colors
                float sunDotUp = dot(sunPos, float3(0, 1, 0));
                float night = saturate(Remap(sunDotUp, float2(_NightStartHeight, _NightEndHeight), float2(0, 1)));

    //Start of Unity code
                // if y > 1 [eyeRay.y < -SKY_GROUND_THRESHOLD] - ground
                // if y >= 0 and < 1 [eyeRay.y <= 0 and > -SKY_GROUND_THRESHOLD] - horizon
                // if y < 0 [eyeRay.y > 0] - sky
                #if SKYBOX_SUNDISK == SKYBOX_SUNDISK_HQ
                    half3 ray = normalize(IN.vertex.xyz);
                    half y = ray.y / SKY_GROUND_THRESHOLD;
                #elif SKYBOX_SUNDISK == SKYBOX_SUNDISK_SIMPLE
                    half3 ray = IN.rayDir.xyz;
                    half y = ray.y / SKY_GROUND_THRESHOLD;
                #else
                    half y = IN.skyGroundFactor;
                #endif

                    // if we did precalculate color in vprog: just do lerp between them
                    col.rgb = lerp(IN.skyColor, IN.groundColor, saturate(y));

                #if SKYBOX_SUNDISK != SKYBOX_SUNDISK_NONE
                    if(y < 0.0)
                    {
                        col.rgb += IN.sunColor * calcSunAttenuation(sunPos, -ray, _SunSize, _SunSizeConvergence);
                    }
                #endif

                #if defined(UNITY_COLORSPACE_GAMMA) && !SKYBOX_COLOR_IN_TARGET_COLOR_SPACE
                    col.rgb = LINEAR_2_OUTPUT(col);
                #endif

    //End of Unity Code

    //Stars
                float2 starsUV = normWorldPos.xz / (normWorldPos.y + _StarBending);
                float stars = tex2D(_StarTex, starsUV * _StarTex_ST.xy + _StarTex_ST.zw).r;
                //invert the voronoi
                stars = 1 - stars;
                //and then raise the value to a power to adjust the brightness falloff of the stars
                stars = pow(stars, _StarBrightness);
                
                //we also sample a basic noise texture, this allows us to modulate the star brightness, this creates a twinkle effect
                float twinkle = tex2D(_TwinkleTex, (starsUV * _TwinkleTex_ST.xy) + _TwinkleTex_ST.zw + float2(1, 0) * _Time.y * _TwinkleSpeed).r;
                //modulate the twinkle value
                twinkle *= _TwinkleBoost;
                
                //then adjust the final color
                stars -= twinkle;
                stars = saturate(stars);

                //then lerp to the stars color masking out the horizon
                col.rgb = lerp(col.rgb, col.rgb + stars, night * horizonValue);
    
                return col;
            }
            ENDCG
        }
    }
}
