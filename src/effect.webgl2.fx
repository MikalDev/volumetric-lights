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
uniform mediump float pixelSize;
uniform mediump float zNear;
uniform mediump float zFar;
uniform mediump sampler2D samplerDepth;
uniform highp mat4 matP;
uniform highp mat4 matMV;

// Camera (used by WGSL path; WebGL2 uses matP/matMV instead)
uniform mediump float camX;
uniform mediump float camY;
uniform mediump float camZ;
uniform mediump float camLookX;
uniform mediump float camLookY;
uniform mediump float camLookZ;
uniform mediump float camFov;

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

void main(void) {
    // Background color
    vec4 back = texture(samplerFront, vTex);

    // Depth
    float rawDepth = texture(samplerDepth, vTex).r;
    float zLinear = linearizeDepth(rawDepth);

    // Camera position from inverse model-view matrix
    mat3 rotMV = mat3(matMV);
    vec3 camPos = -(transpose(rotMV) * matMV[3].xyz);

    // Ray direction: unproject screen UV through inverse projection + inverse view
    vec2 uv = (vTex - srcStart) / (srcEnd - srcStart);
    vec2 ndc = uv * 2.0 - 1.0;
    vec3 viewDir = normalize(vec3(ndc.x / matP[0][0], ndc.y / matP[1][1], -1.0));
    vec3 rayDir = normalize(transpose(rotMV) * viewDir);

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
    vec3 lightPos = vec3(light1X, light1Y, light1Z);
    vec3 lightDir = normalize(vec3(light1DirX, light1DirY, light1DirZ));
    vec3 lightColor = light1Color * light1Intensity;

    // Light occlusion: is the light behind geometry along this pixel's ray?
    float lightT = dot(lightPos - camPos, rayDir);
    if (lightT > zLinear && debugMode < 0.5) {
        outColor = vec4(back.rgb, back.a);
        return;
    }

    // Ray march setup — clamp max distance to avoid sky blowout
    float maxDist = min(zLinear, zFar * 0.99);
    float stepSize = maxDist / float(STEPS);
    float jitter = bayerDither4x4(gl_FragCoord.xy);

    // Accumulate scatter
    vec3 scatter = vec3(0.0);
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
            float density = hash31(cell + 0.5);
            float eligible = step(1.0 - light1DustCount, hash31(cell + 1.0));
            float window = fract(seconds * light1DustSpeed);
            float dist = abs(density - window);
            dist = min(dist, 1.0 - dist);
            dust = smoothstep(light1DustFade, 0.0, dist) * eligible * light1Dust;
        }
        scatter += atten * (1.0 + dust * 15.0) * lightColor;
    }
    scatter /= float(STEPS);
    scatter = min(scatter, vec3(1.0));

    // Debug mode 2: scatter only (amplified, on black)
    if (debugMode > 1.5 && debugMode < 2.5) {
        outColor = vec4(scatter * 10.0, 1.0);
        return;
    }

    // Additive output — scatter needs alpha to be visible on transparent layers
    float scatterLum = max(scatter.r, max(scatter.g, scatter.b));
    outColor = vec4(back.rgb + scatter, max(back.a, scatterLum));
}
