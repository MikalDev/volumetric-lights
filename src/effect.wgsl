%%FRAGMENTINPUT_STRUCT%%

%%FRAGMENTOUTPUT_STRUCT%%

%%SAMPLERFRONT_BINDING%% var samplerFront : sampler;
%%TEXTUREFRONT_BINDING%% var textureFront : texture_2d<f32>;

%%SAMPLERBACK_BINDING%% var samplerBack : sampler;
%%TEXTUREBACK_BINDING%% var textureBack : texture_2d<f32>;

%%SAMPLERDEPTH_BINDING%% var samplerDepth : sampler;
%%TEXTUREDEPTH_BINDING%% var textureDepth : texture_depth_2d;

struct ShaderParams {
    camX : f32,
    camY : f32,
    camZ : f32,
    camLookX : f32,
    camLookY : f32,
    camLookZ : f32,
    camFov : f32,
    light1X : f32,
    light1Y : f32,
    light1Z : f32,
    light1DirX : f32,
    light1DirY : f32,
    light1DirZ : f32,
    light1Color : vec3<f32>,
    light1Intensity : f32,
    light1ConeAngle : f32,
    light1ConeEdge : f32,
    light1AttenC : f32,
    light1AttenL : f32,
    light1AttenQ : f32,
    debugMode : f32,
};

%%SHADERPARAMS_BINDING%% var<uniform> shaderParams : ShaderParams;

%%C3PARAMS_STRUCT%%

%%C3_UTILITY_FUNCTIONS%%

const STEPS : i32 = 8;

fn bayerDither4x4(fragCoord : vec2<f32>) -> f32 {
    let x = i32(fragCoord.x) & 3;
    let y = i32(fragCoord.y) & 3;
    let index = x + y * 4;
    let bayer = array<i32, 16>(
         0,  8,  2, 10,
        12,  4, 14,  6,
         3, 11,  1,  9,
        15,  7, 13,  5
    );
    return f32(bayer[index]) / 16.0;
}

fn spotAttenuation(samplePos : vec3<f32>, lightPos : vec3<f32>, lightDir : vec3<f32>,
                    coneAngle : f32, coneEdge : f32,
                    attenC : f32, attenL : f32, attenQ : f32) -> f32 {
    let toSample = samplePos - lightPos;
    let d = length(toSample);
    if (d < 0.001) {
        return 0.0;
    }

    let toSampleDir = toSample / d;
    let cosAngle = dot(toSampleDir, lightDir);

    // Cone falloff: coneAngle is cos(half-angle), larger cosine = tighter cone
    let innerEdge = coneAngle + coneEdge;
    let cone = smoothstep(coneAngle, innerEdge, cosAngle);

    // Distance attenuation matching Frag Light V2
    let atten = 1.0 / ((1.0 + attenC) + d * attenL + d * d * attenQ);

    return cone * atten;
}

@fragment
fn main(input : FragmentInput) -> FragmentOutput
{
    var output : FragmentOutput;

    // Background color (blends-background: front IS the composited background)
    let back = textureSample(textureFront, samplerFront, input.fragUV);

    // Depth
    let depthUV = c3_getDepthUV(input.fragPos.xy, textureDepth);
    let rawDepth = textureSample(textureDepth, samplerDepth, depthUV);
    let zLinear = c3_linearizeDepth(rawDepth);

    // Debug mode 1: depth heat map (red=near, green=mid, blue=far)
    if (shaderParams.debugMode > 0.5 && shaderParams.debugMode < 1.5) {
        let d = sqrt(clamp(zLinear / c3Params.zFar, 0.0, 1.0));
        let col = vec3<f32>(1.0 - d, 1.0 - abs(d - 0.5) * 2.0, d);
        output.color = vec4<f32>(col, 1.0);
        return output;
    }

    // Camera basis vectors (C3: -Y is up)
    let camPos = vec3<f32>(shaderParams.camX, shaderParams.camY, shaderParams.camZ);
    let lookAt = vec3<f32>(shaderParams.camLookX, shaderParams.camLookY, shaderParams.camLookZ);
    let forward = normalize(lookAt - camPos);
    var worldUp = vec3<f32>(0.0, -1.0, 0.0);
    // Fallback if camera looks straight along world up (gimbal lock)
    if (abs(dot(forward, worldUp)) > 0.999) {
        worldUp = vec3<f32>(0.0, 0.0, 1.0);
    }
    let right = normalize(cross(forward, worldUp));
    let up = cross(right, forward);

    // Screen UV to ray direction
    let srcSize = c3Params.srcEnd - c3Params.srcStart;
    let uv = (input.fragUV - c3Params.srcStart) / srcSize;
    let aspect = abs(srcSize.x / srcSize.y);
    let halfH = tan(shaderParams.camFov * 0.5);
    var screen = uv * 2.0 - 1.0;
    screen.x = screen.x * aspect * halfH;
    screen.y = screen.y * -halfH;  // negate: UV y=0 is top of screen, but camera up is +screen.y
    let rayDir = normalize(forward + screen.x * right + screen.y * up);

    // Debug mode 3: ray direction (RGB = abs world XYZ)
    if (shaderParams.debugMode > 2.5) {
        output.color = vec4<f32>(abs(rayDir), 1.0);
        return output;
    }

    // Light params
    let lightPos = vec3<f32>(shaderParams.light1X, shaderParams.light1Y, shaderParams.light1Z);
    let lightDir = normalize(vec3<f32>(shaderParams.light1DirX, shaderParams.light1DirY, shaderParams.light1DirZ));
    let lightColor = shaderParams.light1Color * shaderParams.light1Intensity;

    // Light occlusion: is the light behind geometry along this pixel's ray?
    let lightT = dot(lightPos - camPos, rayDir);
    if (lightT > zLinear) {
        output.color = vec4<f32>(back.rgb, back.a);
        return output;
    }

    // Ray march setup — clamp max distance to avoid sky blowout
    let maxDist = min(zLinear, c3Params.zFar * 0.99);
    let stepSize = maxDist / f32(STEPS);
    let jitter = bayerDither4x4(input.fragPos.xy);

    // Accumulate scatter
    var scatter = vec3<f32>(0.0, 0.0, 0.0);
    for (var i = 0; i < STEPS; i = i + 1) {
        let t = (f32(i) + jitter) * stepSize;
        let samplePos = camPos + rayDir * t;
        let atten = spotAttenuation(samplePos, lightPos, lightDir,
                                     shaderParams.light1ConeAngle, shaderParams.light1ConeEdge,
                                     shaderParams.light1AttenC, shaderParams.light1AttenL, shaderParams.light1AttenQ);
        scatter = scatter + atten * lightColor;
    }
    scatter = scatter / f32(STEPS);

    // Debug mode 2: scatter only (amplified, on black)
    if (shaderParams.debugMode > 1.5 && shaderParams.debugMode < 2.5) {
        output.color = vec4<f32>(scatter * 10.0, 1.0);
        return output;
    }

    // Additive output — scatter needs alpha to be visible on transparent layers
    let scatterLum = max(scatter.r, max(scatter.g, scatter.b));
    output.color = vec4<f32>(back.rgb + scatter, max(back.a, scatterLum));
    return output;
}
