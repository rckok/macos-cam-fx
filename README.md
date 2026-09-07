# Camera Effects

A macOS app that captures your webcam (or any other camera source), applies a
user-editable GLSL **effect** on the GPU, and republishes the result as a
system-wide **virtual camera** you can pick in Zoom, Meet, FaceTime, etc.

- An **effect** is a small pipeline of one or more **stages**. Exactly one
  effect is active at a time — the one selected in the sidebar.
- Stages are authored in **GLSL 450** and transpiled to Metal at runtime
  (glslang → SPIR-V → SPIRV-Cross → MSL).
- Every stage gets the last **N frames** of the raw feed as a **3D texture**
  (`sampler3D uFrames`), with N configurable in the app.
- **Basic Mode** (the default) is just the effect list plus the controls each
  effect exposes. **Editor Mode** adds the stages inside every effect, the
  GLSL editor, and the per-stage inspector.
- Built-in editor with GLSL syntax highlighting, code completion (keywords,
  built-ins, and the injected prelude symbols), live recompile, inline compile
  errors, `⌘/` to comment or uncomment the selected lines, and auto-generated
  parameter controls reflected from your shader's `Params` uniform block.
- The virtual camera is a modern **CoreMediaIO Camera Extension** (the same
  mechanism OBS uses); the app streams to it automatically as soon as the
  extension is installed.

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
4. "Camera Effects" now appears as a camera in any video-call app. Streaming
   starts on its own — the toolbar just reports whether the sink stream is
   connected.

To remove: `systemextensionsctl uninstall <team-id> studio.polyglot.CameraEffects.Extension`.

> If you fork this project, change the `studio.polyglot` bundle-ID prefix in
> `project.yml` to your own.

## Effects and stages

An **effect** is a named list of **stages**. Only one effect renders at a
time: the one that owns the sidebar selection, so clicking an effect (or any
stage inside it) activates that effect. There is nothing to enable or
disable — picking an effect *is* turning it on.

Within an effect, stages run top to bottom, each one sampling the previous
stage's output through `uPrev`. The first stage of every effect sees the
scaled (and optionally mirrored) camera frame, identical to
`ceHistory(vUV, 0)`, so nothing carries over from whichever effect was active
before.

A stage that never samples `uPrev` does not build on its effect's chain — it
replaces the whole frame. Every stage before it in the same effect is
therefore invisible, so the app skips those passes entirely and marks them in
the sidebar. Their vision detectors do not run either.

Use Editor Mode to add, remove and duplicate stages (the duplicate lands right
below the original with the same shader and parameter values). Drag a stage by
its row to reorder it or to move it into another effect — an insertion line
shows where it will land:

- onto another stage, to go directly above it;
- onto an effect's header, to become that effect's first stage (this is also
  how you drop into a collapsed effect);
- onto an effect's **Add Stage** row, to go last.

Effects are reordered the same way: drag an effect's header onto another
effect to go above it, or onto the **Add Effect** bar to go last. Effects and
stages carry different drag payloads, so neither can land in the other's slot.

## Storage layout

Stages live in the app's sandbox container at
`~/Library/Containers/studio.polyglot.CameraEffects/Data/Library/Application Support/CameraEffects/Stages/`,
one folder per stage containing `shader.frag` (GLSL) and `stage.json`
(name + saved parameter values). You can edit them in the app's editor
(recompiles as you type) or in an external editor (hot-reloads on save).

Which stages belong to which effect — and in what order — lives in
`config.json` next to the `Stages` folder. It is the only place that grouping
exists, so it is written immediately whenever it changes rather than on a
timer, and a `config.json` the app cannot read is set aside as
`config.unreadable.json` instead of being overwritten. A stage folder that no
config claims becomes an effect of its own, named after the folder, so it
stays reachable.

## Writing stages

Your shader is a GLSL 450 **fragment shader body**. The app injects a prelude
that declares the interface, so you only write `main()` plus an optional
`Params` block. The inspector lists every built-in symbol when editing a stage.

### Built-in interface

| Symbol | Type | Description |
| --- | --- | --- |
| `vUV` | `in vec2` | Fullscreen UV coordinates. (0, 0) is top-left; (1, 1) is bottom-right. |
| `outColor` | `out vec4` | Write the stage output here. |
| `uPrev` | `sampler2D` | Previous stage's output (or the scaled/mirrored camera frame for the first stage of an effect). Not sampling it disables every earlier stage — see [Effects and stages](#effects-and-stages). |
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

### Vision data (bindings 16–20)

Face detection, eye/mouth segmentation, hand pose, hand segmentation, and a
person matte for background subtraction are available as standard uniforms.
The underlying detectors (Apple's Vision framework — no extra dependencies)
**only run while a stage of the active effect uses one of these uniforms**;
unused uniforms are dead-code-eliminated at compile time, so referencing none
of them costs nothing. Switching effects re-evaluates what has to run, so the
cost follows whatever is on screen. All coordinates and masks are in vUV space
(top-left origin, mirroring already applied).

| Symbol | Type | Description |
| --- | --- | --- |
| `uPersonMatte` | `sampler2D` | Person-segmentation luma matte: 1 = person, 0 = background. Sample `.r`. |
| `uFaceMask` | `sampler2D` | Face parts from facial landmarks: R = left eye, G = right eye, B = mouth, A = union. |
| `uHandMask` | `sampler2D` | Approximate hand silhouette built from the hand skeleton. Sample `.r`. |
| `uFaceCount` | `int` (`CEFace`, binding = 19) | Detected faces (0 … `CE_MAX_FACES`). |
| `uFaceRects[4]` | `vec4` (`CEFace`) | Face bounding boxes: xy = top-left corner, zw = size, in vUV space. |
| `uHandCount` | `int` (`CEHands`, binding = 20) | Detected hands (0 … `CE_MAX_HANDS`). |
| `uHandInfo[2]` | `vec4` (`CEHands`) | Per hand: x = chirality (−1 left, +1 right), y = confidence. |
| `uHandJoints[42]` | `vec4` (`CEHands`) | 21 joints per hand: xy = vUV position, z = confidence. |
| `ceHandJoint(hand, joint)` | `vec4` | Convenience accessor; use with the `CE_*` joint constants (`CE_WRIST`, `CE_THUMB_TIP`, `CE_INDEX_TIP`, …). |

Example — background subtraction with a luma matte:

```glsl
void main() {
    float matte = texture(uPersonMatte, vUV).r;
    outColor = mix(vec4(0.0, 1.0, 0.0, 1.0), texture(uPrev, vUV), matte);
}
```

Example — circle following the right index fingertip:

```glsl
void main() {
    outColor = texture(uPrev, vUV);
    for (int i = 0; i < uHandCount; i++) {
        vec4 tip = ceHandJoint(i, CE_INDEX_TIP);
        if (tip.z < 0.3) { continue; }
        float d = distance(vUV * uResolution, tip.xy * uResolution);
        outColor = mix(vec4(1.0, 0.0, 0.0, 1.0), outColor, smoothstep(18.0, 22.0, d));
    }
}
```

### User-declared uniforms

| Symbol | Type | Description |
| --- | --- | --- |
| `Params` | `std140` block, binding = 3 | Optional stage parameters — become inspector controls. |
| `yourSampler` | `sampler2D`, binding 4–15 | Optional 2D textures assigned from the media library. Accepts `// @metadata(global)`. |

Example stage:

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

Slider ranges default to 0…1 for floats and 0…10 for ints. Override them with a
decorator on the preceding line:

```glsl
layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=2.0 default=0.35)
    float amount;
    // @metadata(min=vec2(-1.0) max=vec2(1.0) default=vec2(0.0))
    vec2 offset;
    // @metadata(min=vec3(-1) max=vec3(1, 2, 1) default=vec3(0, 1, 0))
    vec3 direction;
    // @metadata(color=true)
    vec3 tint;
    // @metadata(min=0.0 max=1.0 default=0.5 global)
    float intensity;
};
```

`min` / `max` update the inspector on every compile. `default` is used only
when the parameter is first created. Current slider values stay in
`stage.json` and are clamped into the new range. Float sliders include an
editable value field for precise input.

A scalar `min`/`max`/`default` broadcasts to every component. Vector
constructors follow GLSL rules: `vec3(1)` fills all three components;
`vec3(1, 2, 3)` sets them individually; nested constructors such as
`vec3(vec2(1, 2), 3)` are allowed. A constructor with the wrong arity, a
component count that does not match the uniform, or a non-finite value is
reported as a shader error on that `@metadata` line.

`vec3` / `vec4` use a slider per component. Add `color=true` (or a bare
`color`) to show a color picker instead.

### Effect-level controls (`global`)

Basic Mode never shows stages, so by default it cannot reach a stage's
controls. Add `global` (or `global=true`) to a parameter's `@metadata` and its
control is listed on the owning **effect** as well as on the stage — which is
what Basic Mode renders. Effects made of several stages group the borrowed
controls under each stage's name.

Sampler uniforms take the same decorator, and `global` is the only key they
accept — a sampler has no range and no components, so `min`, `max`, `default`
and `color` are reported as errors on that line:

```glsl
// @metadata(global)
layout(binding = 4) uniform sampler2D uOverlay;
```

Supported `Params` member types and their generated controls: `float`
(slider), `int` (slider), `uint` (toggle switch — use this for boolean flags;
std140 stores them as 0/1), `vec2` / `vec3` / `vec4` (a slider per component;
`vec3` / `vec4` become a color picker when `color=true`). Parameter values
and ranges are stored in the stage's `stage.json`.

## Project layout

| Path | Purpose |
| --- | --- |
| `App/` | SwiftUI app: capture, Metal renderer, editor UI, sink-stream client |
| `Extension/` | CoreMediaIO camera extension (virtual camera) |
| `Shared/` | Constants shared by app and extension |
| `Transpiler/` | C++ bridge wrapping glslang + SPIRV-Cross (GLSL → MSL + reflection) |
| `Scripts/` | Dependency build script |
| `project.yml` | XcodeGen project definition |
