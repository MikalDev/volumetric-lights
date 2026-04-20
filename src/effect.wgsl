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
    camLookUpX : f32,
    camLookUpY : f32,
    camLookUpZ : f32,
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
    light1Dust : f32,
    light1DustCount : f32,
    light1DustSpeed : f32,
    light1DustFade : f32,
    light1DustDrift : f32,
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

fn hash31(p_in : vec3<f32>) -> f32 {
    var p = fract(p_in * vec3<f32>(443.897, 441.423, 437.195));
    p = p + dot(p, p.yzx + 19.19);
    return fract((p.x + p.y) * p.z);
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
    let forward = normalize(vec3<f32>(shaderParams.camLookX, shaderParams.camLookY, shaderParams.camLookZ));
    let worldUp = vec3<f32>(shaderParams.camLookUpX, shaderParams.camLookUpY, shaderParams.camLookUpZ);
    let right = normalize(cross(worldUp, forward));
    let up = cross(forward, right);

    // Screen UV to ray direction
    let srcSize = c3Params.srcEnd - c3Params.srcStart;
    let uv = (input.fragUV - c3Params.srcStart) / srcSize;
    let aspect = c3Params.pixelSize.y / c3Params.pixelSize.x;
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
    let lightPos = vec3<f32>(shaderParams.light1X, shaderParams.light1Y, -shaderParams.light1Z);
    let lightDir = normalize(vec3<f32>(shaderParams.light1DirX, shaderParams.light1DirY, -shaderParams.light1DirZ));
    let lightColor = shaderParams.light1Color * shaderParams.light1Intensity;

    // Light occlusion: is the light behind geometry along this pixel's ray?
    let lightT = dot(lightPos - camPos, rayDir);
    let maxRayDist = zLinear / dot(rayDir, forward);
    if (lightT > maxRayDist && shaderParams.debugMode < 0.5) {
        output.color = vec4<f32>(back.rgb, back.a);
        return output;
    }

    // Ray march setup — clamp to avoid sky blowout
    let maxDist = min(maxRayDist, c3Params.zFar * 0.99);
    let stepSize = maxDist / f32(STEPS);
    let jitter = bayerDither4x4(input.fragPos.xy);

    // Accumulate scatter and dust separately
    var scatter = vec3<f32>(0.0, 0.0, 0.0);
    var dustAccum = vec3<f32>(0.0, 0.0, 0.0);
    var dustAlpha = 0.0;
    for (var i = 0; i < STEPS; i = i + 1) {
        let t = (f32(i) + jitter) * stepSize;
        let samplePos = camPos + rayDir * t;
        let atten = spotAttenuation(samplePos, lightPos, lightDir,
                                     shaderParams.light1ConeAngle, shaderParams.light1ConeEdge,
                                     shaderParams.light1AttenC, shaderParams.light1AttenL, shaderParams.light1AttenQ);
        var dust = 0.0;
        if (atten > 0.001 && shaderParams.light1Dust > 0.0 && t < maxDist * 0.9) {
            let cellSize = 2.0;
            let cell = vec3<f32>(floor(input.fragPos.xy / cellSize), f32(i));
            let eligible = step(1.0 - shaderParams.light1DustCount, hash31(cell + 1.0));
            // Per-particle smooth drift (sine oscillation, random direction + phase)
            let driftAngle = hash31(cell + 3.0) * 6.2832;
            let driftPhase = hash31(cell + 5.0) * 6.2832;
            let particlePos = (cell.xy + 0.5) * cellSize
                + vec2<f32>(cos(driftAngle), sin(driftAngle))
                * sin(c3Params.seconds * shaderParams.light1DustDrift + driftPhase) * cellSize;
            let pDist = length(input.fragPos.xy - particlePos) / cellSize;
            let spatial = smoothstep(1.0, 0.0, pDist);
            let density = hash31(cell + 0.5);
            let window = fract(c3Params.seconds * shaderParams.light1DustSpeed);
            var dist2 = abs(density - window);
            dist2 = min(dist2, 1.0 - dist2);
            dust = smoothstep(shaderParams.light1DustFade, 0.0, dist2) * spatial * eligible * shaderParams.light1Dust;
        }
        scatter = scatter + atten * lightColor;
        // Dust: accumulate color and opacity for opaque blending
        let dustStrength = dust * atten;
        dustAccum = dustAccum + dustStrength * lightColor;
        dustAlpha = dustAlpha + dustStrength;
    }
    scatter = scatter / f32(STEPS);
    scatter = min(scatter, vec3<f32>(1.0, 1.0, 1.0));
    dustAlpha = clamp(dustAlpha, 0.0, 1.0);
    let dustColor = select(vec3<f32>(0.0, 0.0, 0.0), dustAccum / dustAlpha, dustAlpha > 0.001);

    // Debug mode 2: scatter only (amplified, on black)
    if (shaderParams.debugMode > 1.5 && shaderParams.debugMode < 2.5) {
        output.color = vec4<f32>(scatter * 10.0, 1.0);
        return output;
    }

    // Extinction + additive scatter, then opaque dust on top
    let scatterLum = clamp(max(scatter.r, max(scatter.g, scatter.b)), 0.0, 1.0);
    var result = back.rgb * (1.0 - scatterLum) + scatter;
    result = mix(result, dustColor, dustAlpha);
    output.color = vec4<f32>(result, max(back.a, max(scatterLum, dustAlpha)));
    return output;
}
