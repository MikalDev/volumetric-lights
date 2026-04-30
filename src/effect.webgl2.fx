#version 300 es
precision highp float;

in mediump vec2 vTex;
in highp vec3 vWorldPos;
out lowp vec4 outColor;
uniform lowp sampler2D samplerFront;
uniform lowp sampler2D samplerBack;
uniform mediump vec2 srcStart;
uniform mediump vec2 srcEnd;
uniform mediump vec2 srcOriginStart;
uniform mediump vec2 srcOriginEnd;
uniform mediump vec2 layoutStart;
uniform mediump vec2 layoutEnd;
uniform lowp float seconds;
uniform mediump vec2 pixelSize;
uniform mediump float zNear;
uniform mediump float zFar;
uniform mediump sampler2D samplerDepth;
uniform highp mat4 matP;
uniform highp mat4 matMV;

// Camera
uniform mediump float camX;
uniform mediump float camY;
uniform mediump float camZ;
uniform mediump float camLookX;
uniform mediump float camLookY;
uniform mediump float camLookZ;
uniform mediump float camFov;
uniform mediump float camLookUpX;
uniform mediump float camLookUpY;
uniform mediump float camLookUpZ;

// Light 1
uniform mediump float light1X;
uniform mediump float light1Y;
uniform mediump float light1Z;
uniform mediump float light1DirX;
uniform mediump float light1DirY;
uniform mediump float light1DirZ;
uniform mediump vec3 light1Color;
uniform mediump float light1Intensity;
uniform mediump float light1ConeAngle;
uniform mediump float light1ConeEdge;
uniform mediump float light1AttenC;
uniform mediump float light1AttenL;
uniform mediump float light1AttenQ;
uniform mediump float light1Dust;
uniform mediump float light1DustCount;
uniform mediump float light1DustSpeed;
uniform mediump float light1DustFade;
uniform mediump float light1DustDrift;
uniform mediump float light1Shadow;
uniform mediump float light1ShadowSteps;
uniform mediump float light1ShadowBias;
uniform mediump float debugMode;

const int STEPS = 8;

float linearizeDepth(float d) {
    return (zNear * zFar) / (zFar - d * (zFar - zNear));
}

float bayerDither4x4(vec2 fragCoord) {
    int x = int(fragCoord.x) & 3;
    int y = int(fragCoord.y) & 3;
    int index = x + y * 4;
    // 4x4 Bayer matrix values / 16
    int bayer[16] = int[16](
         0,  8,  2, 10,
        12,  4, 14,  6,
         3, 11,  1,  9,
        15,  7, 13,  5
    );
    return float(bayer[index]) / 16.0;
}

float hash31(vec3 p) {
    p = fract(p * vec3(443.897, 441.423, 437.195));
    p += dot(p, p.yzx + 19.19);
    return fract((p.x + p.y) * p.z);
}

float spotAttenuation(vec3 samplePos, vec3 lightPos, vec3 lightDir,
                       float coneAngle, float coneEdge,
                       float attenC, float attenL, float attenQ) {
    vec3 toSample = samplePos - lightPos;
    float d = length(toSample);
    if (d < 0.001) return 0.0;

    vec3 toSampleDir = toSample / d;
    float cosAngle = dot(toSampleDir, lightDir);

    // Cone falloff: coneAngle is cos(half-angle), larger cosine = tighter cone
    float innerEdge = coneAngle + coneEdge;
    float cone = smoothstep(coneAngle, innerEdge, cosAngle);

    // Distance attenuation matching Frag Light V2
    float atten = 1.0 / ((1.0 + attenC) + d * attenL + d * d * attenQ);

    return cone * atten;
}

float screenSpaceShadow(vec3 samplePos, vec3 lightPos,
                        vec3 camPos, vec3 fwd, vec3 right, vec3 up,
                        float halfH, float aspect,
                        vec2 srcSt, vec2 srcEn, vec2 pxSize,
                        int steps, float bias) {
    // Project sample point to screen UV + view depth
    vec3 sOff = samplePos - camPos;
    float sViewZ = dot(sOff, fwd);
    if (sViewZ <= 0.0) return 1.0;
    vec2 sUV = vec2(
        (dot(sOff, right) / (sViewZ * aspect * halfH)) * 0.5 + 0.5,
        (dot(sOff, up) / (sViewZ * -halfH)) * 0.5 + 0.5
    );

    // Project light to screen UV + view depth
    vec3 lOff = lightPos - camPos;
    float lViewZ = dot(lOff, fwd);
    if (lViewZ <= 0.0) return 1.0;
    vec2 lUV = vec2(
        (dot(lOff, right) / (lViewZ * aspect * halfH)) * 0.5 + 0.5,
        (dot(lOff, up) / (lViewZ * -halfH)) * 0.5 + 0.5
    );

    // Adaptive step count: ~1 step per 4 pixels, minimum user steps, cap at 4x
    float screenPixels = length((lUV - sUV) / pxSize);
    int actualSteps = min(max(steps, int(screenPixels * 0.25)), steps * 4);

    // March in screen space — uniform UV steps, perspective-correct depth
    float invSZ = 1.0 / sViewZ;
    float invLZ = 1.0 / lViewZ;
    for (int j = 1; j <= actualSteps; j++) {
        float frac = float(j) / float(actualSteps + 1);
        vec2 uv = mix(sUV, lUV, frac);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) continue;

        float expectedZ = 1.0 / mix(invSZ, invLZ, frac);
        vec2 texUV = srcSt + (srcEn - srcSt) * uv;
        float bufferZ = linearizeDepth(texture(samplerDepth, texUV).r);
        if (bufferZ < expectedZ - bias) return 0.0;
    }

    return 1.0;
}

void main(void) {
    // Background color
    vec4 back = texture(samplerFront, vTex);

    // Depth
    float rawDepth = texture(samplerDepth, vTex).r;
    float zLinear = linearizeDepth(rawDepth);

    // Camera basis vectors from uniforms (C3: -Y is up)
    vec3 camPos = vec3(camX, camY, camZ);
    vec3 forward = normalize(vec3(camLookX, camLookY, camLookZ));
    vec3 worldUp = vec3(camLookUpX, camLookUpY, camLookUpZ);
    vec3 right = normalize(cross(worldUp, forward));
    vec3 up = cross(forward, right);

    // Screen UV to ray direction
    vec2 uv = (vTex - srcStart) / (srcEnd - srcStart);
    float aspect = pixelSize.y / pixelSize.x;
    float halfH = tan(camFov * 0.5);
    vec2 screen = uv * 2.0 - 1.0;
    screen.x *= aspect * halfH;
    screen.y *= -halfH;  // negate: UV y=0 is top, camera up is +screen.y
    vec3 rayDir = normalize(forward + screen.x * right + screen.y * up);

    // Debug mode 1: depth heat map (red=near, green=mid, blue=far)
    if (debugMode > 0.5 && debugMode < 1.5) {
        float d = sqrt(clamp(zLinear / zFar, 0.0, 1.0));
        vec3 col = vec3(1.0 - d, 1.0 - abs(d - 0.5) * 2.0, d);
        outColor = vec4(col, 1.0);
        return;
    }

    // Debug mode 3: ray direction (RGB = abs world XYZ)
    if (debugMode > 2.5 && debugMode < 3.5) {
        outColor = vec4(abs(rayDir), 1.0);
        return;
    }

    // Light params
    vec3 lightPos = vec3(light1X, light1Y, -light1Z);
    vec3 lightDir = normalize(vec3(light1DirX, light1DirY, -light1DirZ));
    vec3 lightColor = light1Color * light1Intensity;

    // Ray march setup — depth-limited to stop at solid surfaces
    float maxRayDist = zLinear / dot(rayDir, forward);
    float maxDist = min(maxRayDist, zFar * 0.99);
    float stepSize = maxDist / float(STEPS);
    float jitter = bayerDither4x4(gl_FragCoord.xy);

    // Accumulate scatter and dust separately
    vec3 scatter = vec3(0.0);
    vec3 dustAccum = vec3(0.0);
    float dustAlpha = 0.0;
    for (int i = 0; i < STEPS; i++) {
        float t = (float(i) + jitter) * stepSize;
        vec3 samplePos = camPos + rayDir * t;
        float atten = spotAttenuation(samplePos, lightPos, lightDir,
                                       light1ConeAngle, light1ConeEdge,
                                       light1AttenC, light1AttenL, light1AttenQ);
        float dust = 0.0;
        if (atten > 0.001 && light1Dust > 0.0 && t < maxDist * 0.9) {
            float cellSize = 2.0;
            vec3 cell = vec3(floor(gl_FragCoord.xy / cellSize), float(i));
            float eligible = step(1.0 - light1DustCount, hash31(cell + 1.0));
            // Per-particle smooth drift (sine oscillation, random direction + phase)
            float driftAngle = hash31(cell + 3.0) * 6.2832;
            float driftPhase = hash31(cell + 5.0) * 6.2832;
            vec2 particlePos = (cell.xy + 0.5) * cellSize
                + vec2(cos(driftAngle), sin(driftAngle))
                * sin(seconds * light1DustDrift + driftPhase) * cellSize;
            float pDist = length(gl_FragCoord.xy - particlePos) / cellSize;
            float spatial = smoothstep(1.0, 0.0, pDist);
            float density = hash31(cell + 0.5);
            float window = fract(seconds * light1DustSpeed);
            float dist = abs(density - window);
            dist = min(dist, 1.0 - dist);
            dust = smoothstep(light1DustFade, 0.0, dist) * spatial * eligible * light1Dust;
        }
        float shadow = 1.0;
        if (light1Shadow > 0.001 && atten > 0.001) {
            int ssteps = int(clamp(light1ShadowSteps, 1.0, 16.0));
            shadow = screenSpaceShadow(samplePos, lightPos,
                         camPos, forward, right, up, halfH, aspect,
                         srcStart, srcEnd, pixelSize, ssteps, light1ShadowBias);
        }
        scatter += atten * shadow * lightColor;
        // Dust: accumulate color and opacity for opaque blending
        float dustStrength = dust * atten * shadow;
        dustAccum += dustStrength * lightColor;
        dustAlpha += dustStrength;
    }
    scatter /= float(STEPS);
    scatter = min(scatter, vec3(1.0));
    dustAlpha = clamp(dustAlpha, 0.0, 1.0);
    vec3 dustColor = dustAlpha > 0.001 ? dustAccum / dustAlpha : vec3(0.0);

    // Debug mode 2: scatter only (amplified, on black)
    if (debugMode > 1.5 && debugMode < 2.5) {
        outColor = vec4(scatter * 10.0, 1.0);
        return;
    }

    // Extinction + additive scatter, then opaque dust on top
    float scatterLum = clamp(max(scatter.r, max(scatter.g, scatter.b)), 0.0, 1.0);
    vec3 result = back.rgb * (1.0 - scatterLum) + scatter;
    result = mix(result, dustColor, dustAlpha);
    outColor = vec4(result, max(back.a, max(scatterLum, dustAlpha)));
}
