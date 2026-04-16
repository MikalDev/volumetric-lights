# Construct 3 WebGPU/WGSL Shader Reference

## Providing a WGSL shader variant

To support WebGPU, `addon.json` must specify `"webgpu"` in `"supported-renderers"`:

```json
"supported-renderers": ["webgl2", "webgpu"]
```

Construct will look for a WGSL shader file named `effect.wgsl`.

## Key differences from GLSL

- WGSL is more verbose than GLSL and requires explicit binding/group numbers.
- Construct provides `%%NAME%%` preprocessor placeholders to avoid hard-coding engine-specific details.
- Effect parameters are stored in a struct referenced by byte offset (not by uniform name). List all parameters in `ShaderParams` in the **same order** as defined in `addon.json` with the appropriate type.

## Construct-specific placeholders

### Sampler/Texture bindings

| Placeholder | Purpose |
|---|---|
| `%%SAMPLERFRONT_BINDING%%` | Foreground sampler binding |
| `%%TEXTUREFRONT_BINDING%%` | Foreground texture binding |
| `%%SAMPLERBACK_BINDING%%` | Background sampler binding |
| `%%TEXTUREBACK_BINDING%%` | Background texture binding |
| `%%SAMPLERDEPTH_BINDING%%` | Depth sampler binding |
| `%%TEXTUREDEPTH_BINDING%%` | Depth texture binding |

Example:
```wgsl
%%SAMPLERFRONT_BINDING%% var samplerFront : sampler;
%%TEXTUREFRONT_BINDING%% var textureFront : texture_2d<f32>;
```

### Struct placeholders

| Placeholder | Defines |
|---|---|
| `%%FRAGMENTINPUT_STRUCT%%` | `FragmentInput` struct with `fragUV : vec2<f32>`, `fragColor : vec4<f32>`, `worldPos : vec3<f32>` (added post-docs), `@builtin(position) fragPos : vec4<f32>`. Note: `fragColor` can be used for vertex lighting in effects that need it. |
| `%%FRAGMENTOUTPUT_STRUCT%%` | `FragmentOutput` struct with `color : vec4<f32>` |
| `%%SHADERPARAMS_BINDING%%` | Binding attributes for custom shader params uniform |
| `%%C3PARAMS_STRUCT%%` | `c3Params` struct with engine-provided uniforms |
| `%%C3_UTILITY_FUNCTIONS%%` | Utility helper functions |

### c3Params members

```wgsl
srcStart            : vec2<f32>,
srcEnd              : vec2<f32>,
srcOriginStart      : vec2<f32>,
srcOriginEnd        : vec2<f32>,
layoutStart         : vec2<f32>,
layoutEnd           : vec2<f32>,
destStart           : vec2<f32>,
destEnd             : vec2<f32>,
devicePixelRatio    : f32,
layerScale          : f32,
layerAngle          : f32,
seconds             : f32,
zNear               : f32,
zFar                : f32,
isSrcTexRotated     : u32
```

## Utility functions

### From `%%FRAGMENTINPUT_STRUCT%%`

- `c3_getBackUV(fragPos : vec2<f32>, texBack : texture_2d<f32>) -> vec2<f32>` - Background texture UVs
- `c3_getDepthUV(fragPos : vec2<f32>, texDepth : texture_depth_2d) -> vec2<f32>` - Depth texture UVs

### From `%%C3PARAMS_STRUCT%%`

- `c3_srcToNorm(p) / c3_normToSrc(p)` - Normalize/denormalize relative to src box
- `c3_srcOriginToNorm(p) / c3_normToSrcOrigin(p)` - Same for srcOrigin box
- `c3_clampToSrc(p) / c3_clampToSrcOrigin(p)` - Clamp to box
- `c3_getLayoutPos(p)` - Layout coordinates from fragUV
- `c3_srcToDest(p)` - Map src rect to dest rect
- `c3_clampToDest(p)` - Clamp to dest rect
- `c3_linearizeDepth(depthSample) -> f32` - Linearize depth sample to Z distance

### From `%%C3_UTILITY_FUNCTIONS%%`

- `c3_premultiply(c) / c3_unpremultiply(c)` - Premultiplied alpha conversion
- `c3_grayscale(rgb) -> f32` - RGB to grayscale
- `c3_getPixelSize(t : texture_2d<f32>) -> vec2<f32>` - Pixel size in texture coords (replaces WebGL `pixelSize` uniform)
- `c3_RGBtoHSL(color) / c3_HSLtoRGB(hsl)` - Color space conversion

## Common shader patterns

Sample foreground:
```wgsl
var front : vec4<f32> = textureSample(textureFront, samplerFront, input.fragUV);
```

Sample adjacent pixel:
```wgsl
var pixelWidth : f32 = c3_getPixelSize(textureFront).x;
var next : vec4<f32> = textureSample(textureFront, samplerFront, input.fragUV + vec2<f32>(pixelWidth, 0.0));
```

Sample background:
```wgsl
var back : vec4<f32> = textureSample(textureBack, samplerBack, c3_getBackUV(input.fragPos.xy, textureBack));
```

Sample and linearize depth:
```wgsl
var depthSample : f32 = textureSample(textureDepth, samplerDepth, c3_getDepthUV(input.fragPos.xy, textureDepth));
var zLinear : f32 = c3_linearizeDepth(depthSample);
```

Unpremultiply/premultiply workflow:
```wgsl
var front : vec4<f32> = textureSample(textureFront, samplerFront, input.fragUV);
front = c3_unpremultiply(front);
// ...modify...
front = c3_premultiply(front);
```

## Precision

- WebGPU uses explicit types (`f32`) instead of GLSL precision qualifiers (`lowp`, `mediump`).
- Construct defines `f16or32` type: uses `f16` when `shader-f16` is supported, otherwise `f32`.
- All built-in inputs/outputs use `f32` for compatibility; shaders can use `f16or32` internally for performance.

## Compatibility: WebGL vs WebGPU Y-axis

WebGL `src/srcOrigin/dest` uniforms use **inverted Y** (1-0 top-to-bottom) vs WebGPU (0-1). When porting GLSL to WGSL, you may need to invert Y:

```wgsl
var tex : vec2<f32> = c3_srcToNorm(input.fragUV);
tex.y = 1.0 - tex.y;
// ... effect ...
p.y = 1.0 - p.y;
```

**Recommendation:** Write the WebGPU shader first, apply Y inversion in WebGL if needed. WebGL may eventually be retired.
