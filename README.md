# Camera Effects

A macOS app that captures your webcam (or any other camera source), applies a
chain of user-editable GLSL effects on the GPU, and republishes the result as a
system-wide **virtual camera** you can pick in Zoom, Meet, FaceTime, etc.

- Effects are authored in **GLSL 450** and transpiled to Metal at runtime
  (glslang → SPIR-V → SPIRV-Cross → MSL).
- Every effect gets the last **N frames** of the raw feed as a **3D texture**
  (`sampler3D uFrames`), with N configurable in the app.
- Built-in editor with live recompile, inline compile errors, and
  auto-generated parameter controls reflected from your shader's `Params`
  uniform block.
- The virtual camera is a modern **CoreMediaIO Camera Extension** (the same
  mechanism OBS uses); the app renders frames and pushes them into the
  extension through a sink stream.

## Requirements

- macOS 14+ (Apple silicon or Intel)
- Xcode 15+ (full Xcode, not just Command Line Tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and CMake
  (`brew install xcodegen cmake`)
- A **paid Apple Developer account** (system extensions cannot be signed with
  a free account)

## Building

```sh
# 1. Build third-party shader libraries (glslang + SPIRV-Cross, one-time, ~5 min)
./Scripts/build_dependencies.sh

# 2. Configure signing
cp Config/Signing.xcconfig.template Config/Signing.xcconfig
#    ...then edit Config/Signing.xcconfig and set DEVELOPMENT_TEAM to your team ID

# 3. Generate and open the Xcode project
xcodegen
open CameraEffects.xcodeproj
```

Build and run the `CameraEffects` scheme. The built app is written to
`build/Debug/CameraEffects.app` (project-relative). If you build from Xcode
without changing the scheme, Xcode may still use DerivedData — prefer
`xcodebuild` or set the scheme's build location to match.

## Installing the virtual camera (development)

The `com.apple.developer.system-extension.install` entitlement requires a
provisioning profile, so the first build must happen from Xcode while signed
in to your Apple Developer account (Xcode → Settings → Accounts). Xcode then
registers this Mac and creates the profile automatically; after that,
command-line builds work too.

System extensions only load from `/Applications` (unless SIP is configured to
allow developer mode via `systemextensionsctl developer on`). So:

1. Build the app in Xcode (Release recommended).
2. Copy `CameraEffects.app` into `/Applications` and launch it from there.
3. Click **Install Extension** in the toolbar and approve the extension in
   System Settings → General → Login Items & Extensions.
4. "Camera Effects" now appears as a camera in any video-call app. Toggle
   **Virtual Camera** in the toolbar to stream your processed feed to it.

To remove: `systemextensionsctl uninstall <team-id> studio.polyglot.CameraEffects.Extension`.

> If you fork this project, change the `studio.polyglot` bundle-ID prefix in
> `project.yml` to your own.

## Writing effects

Effects live in the app's sandbox container at
`~/Library/Containers/studio.polyglot.CameraEffects/Data/Library/Application Support/CameraEffects/Effects/`,
one folder per effect containing `shader.frag` (GLSL) and `effect.json`
(name + saved parameter values). You can edit them in the app's editor
(recompiles as you type) or in an external editor (hot-reloads on save).

Your shader is a GLSL 450 **fragment shader body**. The app injects a prelude
that declares the interface, so you only write `main()` plus an optional
`Params` block. The inspector lists every built-in symbol when editing an effect.

### Built-in interface

| Symbol | Type | Description |
| --- | --- | --- |
| `vUV` | `in vec2` | Fullscreen UV coordinates. (0, 0) is top-left; (1, 1) is bottom-right. |
| `outColor` | `out vec4` | Write the effect output here. |
| `uPrev` | `sampler2D` | Previous pass output (or the scaled/mirrored camera frame for pass 0). |
| `uFrames` | `sampler3D` | Last **N** raw camera frames. The z axis is history — prefer `ceHistory()` over manual z indexing. |
| `ceHistory(uv, ago)` | `vec4` | Sample the raw frame from `ago` frames ago (0 = newest). Handles ring-buffer wrapping. |

### CEContext uniform block (binding = 2)

| Member | Type | Description |
| --- | --- | --- |
| `uResolution` | `vec2` | Output size in pixels (1280 × 720). |
| `uTime` | `float` | Seconds since the capture stream started. |
| `uTimeDelta` | `float` | Seconds since the previous rendered frame. |
| `uFrameCount` | `int` | Depth **N** of `uFrames` (Settings → Frame History). |
| `uHeadIndex` | `int` | z-slice index of the newest raw frame (0 … N − 1). |
| `uFrameNumber` | `int` | Frame counter since the stream started. |

### User-declared uniforms

| Symbol | Type | Description |
| --- | --- | --- |
| `Params` | `std140` block, binding = 3 | Optional effect parameters — become inspector controls. |
| `yourSampler` | `sampler2D`, binding ≥ 4 | Optional 2D textures assigned from the media library. |

Example effect:

```glsl
layout(std140, binding = 3) uniform Params {
    float amount;   // becomes a slider in the inspector
};

void main() {
    vec4 now  = texture(uPrev, vUV);
    vec4 past = ceHistory(vUV, 10);
    outColor  = mix(now, past, amount);
}
```

Supported `Params` member types and their generated controls: `float`
(slider), `int` (slider), `uint` (toggle switch — use this for boolean flags;
std140 stores them as 0/1), `vec2` (numeric fields), `vec3` / `vec4` (color
picker). Parameter values and ranges are stored in the effect's `effect.json`.

## Project layout

| Path | Purpose |
| --- | --- |
| `App/` | SwiftUI app: capture, Metal renderer, editor UI, sink-stream client |
| `Extension/` | CoreMediaIO camera extension (virtual camera) |
| `Shared/` | Constants shared by app and extension |
| `Transpiler/` | C++ bridge wrapping glslang + SPIRV-Cross (GLSL → MSL + reflection) |
| `Scripts/` | Dependency build script |
| `project.yml` | XcodeGen project definition |
