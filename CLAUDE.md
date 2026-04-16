# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Construct 3 effect addon called **"Volumetric Spotlight"** (`mikal-volumetric-spot-v1`). A layer/post-process effect that renders volumetric light scattering ("god rays") from spotlight cones using ray marching through the depth buffer. Version 1.0.0.0, by Mikal.

Companion to the **Frag Light V2** surface lighting addon (`mikal-frag8-v2`). This effect is applied as a layer effect and runs on every pixel, reading the depth buffer to determine ray endpoints.

## Build & Test

There is no build system, package manager, or test framework. This is a pure shader asset — all files under `src/` are the distributable addon. Testing is manual within the Construct 3 editor/runtime.

To install in Construct 3: open the editor's addon manager and point it at the `src/` folder or package it as a `.c3addon` zip.

## Architecture

All source lives in `src/`:

- **`addon.json`** — Addon manifest and parameter definitions. Single source of truth for parameter IDs, uniform names, types, and default values. Every uniform in the shaders must have a matching entry here.
- **`effect.webgl2.fx`** — WebGL2 (GLSL ES 3.0) fragment shader. Entry point: `void main(void)`.
- **`effect.wgsl`** — WebGPU (WGSL) fragment shader. Entry point: `@fragment fn main(...)`. Uses Construct 3 template placeholders (`%%FRAGMENTOUTPUT_STRUCT%%`, `%%SAMPLERFRONT_BINDING%%`, etc.) that the engine fills at runtime.
- **`lang/en-US.json`** — UI labels and descriptions for all parameters.

## Shader Conventions

- Both shaders must stay feature-parallel — any change needs to be replicated in both `effect.webgl2.fx` and `effect.wgsl`.
- WebGL2 shader uses precision qualifiers (`highp` for positions/math, `lowp` for colors). WGSL has no precision qualifiers.
- WGSL uses `select()` where GLSL uses ternary/`if` in some cases.
- WGSL ShaderParams struct field order must exactly match addon.json parameter order.

## Key Design Decisions

- **Layer effect**: `blends-background: true`, `uses-depth: true` — reads composited layer background and depth buffer
- **Ray marching**: 8 steps per pixel with Bayer dither jitter for anti-banding
- **Depth-limited rays**: Ray endpoint is the scene depth at each pixel (scatter stops at solid surfaces)
- **Additive output**: Scatter is added on top of the background, not replacing it
- **Camera params as uniforms**: Camera position, look-at, and FOV are passed as float uniforms (set via C3 events)
- **Spotlight conventions match Frag Light V2**: Same attenuation formula `1/((1+C) + d*L + d²*Q)`, same cone angle (cos half-angle), same edge softness formula

## Coordinate System

Construct 3 uses: +X right, -Y up, +Z toward camera.

## C3 Depth Buffer Access

- WebGL2: `samplerDepth` sampler with `zNear`/`zFar` uniforms
- WGSL: `textureDepth` + `samplerDepth` via `%%SAMPLERDEPTH_BINDING%%` / `%%TEXTUREDEPTH_BINDING%%` placeholders
- Linearize with `c3_linearizeDepth()` (WGSL) or manual linearization (WebGL2)

## Expandability

Currently 1 spotlight. Designed so lights 1-3 can be added by appending parameter blocks before the debug-mode parameter without breaking existing projects.
