# Camera Effects

A macOS app that captures your webcam (or any other camera source), applies a
user-editable GLSL **effect** on the GPU, and republishes the result as a
system-wide **virtual camera** you can pick in Zoom, Meet, FaceTime, etc.

- An **effect** is a small pipeline of one or more **stages**. Exactly one
  effect is active at a time — the one picked in the effect menu.
- Stages are authored in **GLSL 450** and transpiled to Metal at runtime
  (glslang → SPIR-V → SPIRV-Cross → MSL).
- Every stage gets the last **N frames** of the raw feed as a **3D texture**
  (`sampler3D uFrames`), with N configurable in the app.
- **Basic Mode** (the default) is the camera filling the window, with four
  glass controls floating over it: a camera picker, the effect menu, the
  effect's controls in a pane that unfolds from its button, and the editor
  switch. **Editor Mode** slides an editor panel in under the camera — the
  active effect's stages, the GLSL editor, and the selected stage's controls
  — and leaves everything above it in place. The effect menu unfolds into a
  glass list there, where effects can also be added, reordered and removed.
- Built-in editor with GLSL syntax highlighting, code completion (keywords,
  built-ins, and the injected prelude symbols), live recompile, inline compile
  errors, `⌘/` to comment or uncomment the selected lines, and auto-generated
  parameter controls reflected from your shader's `Params` uniform block.
- The virtual camera is a modern **CoreMediaIO Camera Extension** (the same
  mechanism OBS uses); the app streams to it automatically as soon as the
  extension is installed.
- The UI adopts **Liquid Glass** on macOS 26 and falls back to the standard
  materials on older releases — see [Liquid Glass](#liquid-glass).

## Requirements

- macOS 14+ (Apple silicon or Intel)
- Xcode 15+ (full Xcode, not just Command Line Tools). Xcode 26 or newer for
  the Liquid Glass look; older Xcode builds the same app with the pre-26 UI.
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
3. Click **Install Extension** in the window's top-right corner and approve
   the extension in System Settings → General → Login Items & Extensions.
4. "Camera Effects" now appears as a camera in any video-call app. Streaming
   starts on its own — the status in the corner only stays visible while the
   sink stream is not connected.

To remove: `systemextensionsctl uninstall <team-id> studio.polyglot.CameraEffects.Extension`.

> If you fork this project, change the `studio.polyglot` bundle-ID prefix in
> `project.yml` to your own.

## Liquid Glass

Built with Xcode 26 or newer, the app picks up macOS 26's Liquid Glass:
popovers, lists and every standard control are restyled by the system without
any code. On top of that the app opts in explicitly for the chrome it draws
itself:

- the whole window is one `GlassEffectContainer`, so its glass surfaces blend
  with each other and render in one pass instead of sampling each other;
- the editor panel's headers and the stage list's **Add Stage** bar are glass
  strips that the list scrolls *under*, rather than rows above a divider;
- the editor header is a glass strip too, and the diagnostics list below the
  code tints its glass red or yellow — the tint is what carries the compile
  status, replacing the old color wash;
- the Dock icon is an Icon Composer package (`App/Resources/AppIcon.icon`).

The camera view is built around glass: the window has no title bar or toolbar
of its own, the camera runs edge to edge, and everything else floats over it
as interactive *clear* glass — the style meant for controls over photos and
video, which shows far more of the feed than the frosted `regular` glass the
app's chrome uses. The floating elements are the circular camera, controls and
editor buttons, the effect menu, the controls pane, and the extension status,
which only appears while the virtual camera needs installing, approving or is
still connecting. Clear glass leaves legibility to the app, so each surface
carries a scrim between the glass and its contents, sized to how fine that
content is — a hint under the control bar, more under the pane's sliders (the
`dim` argument of `glassSurface`).
The camera menu also holds two view settings: **Mirror**, and **Fill Window**
(on by default), which crops the frame to cover the window — turn it off to
letterbox it and see everything the virtual camera sends. Both are remembered.
Frame history is in the editor panel's settings.

The camera menu's **Background…** item unfolds a gallery pane above the
control bar: a grid of images to put behind you, led by a **None** tile that
leaves the camera as it is — picking any image turns the background on,
picking None turns it off. The **Add** tile at the end adds images from disk
(adding one also selects it), and each image has a delete button (hover it,
or use the context menu); deleting the one in use goes back to None. The pane
closes with its **×** or with a click on the camera outside it. The chosen image is cropped
to fill the frame and never mirrored, whatever **Mirror** does to the feed.
With an image chosen, the frame the effects get *is* the composite — the
image with the camera masked by the person matte on top — so `uPrev` in the
first stage, `ceHistory()` and `uFrames` all carry it, and every effect works
over the new background without knowing about it. The segmentation model runs
whenever an image is chosen, even for effects that never sample
`uPersonMatte`; until its first matte arrives, the camera passes through
untouched.

Above the gallery, **High-accuracy matte** switches person segmentation from
Vision's balanced level to its accurate one: cleaner edges around hair and
shoulders for a noticeably higher cost per frame. It is one setting for the
matte wherever it is used — the background composite and any effect sampling
`uPersonMatte` — and applies whether or not a background is chosen. The
choice of background, the matte setting and the gallery are remembered across
launches. The floating UI is pinned to
the dark appearance whatever the system is set to: glass takes its tone from
the video behind it rather than from the system, and the pane's native
controls can only be made to match it by fixing their appearance.

Editor Mode does not replace that layout — it slides a panel in under the
camera and slides it back out when switched off. The window grows to make
room rather than the camera shrinking: opening the panel extends the window
downwards by the panel's height (the first time, by the camera's own height,
so the window doubles), and closing it takes that back. Only the window's
frame is animated: how much of the panel shows is read off the window's
content height as it changes, so the camera — content minus panel — holds
still while the panel appears. The screen caps the growth: the window never gets
taller than the screen's visible area, whatever it could not grow by comes
out of the camera, and a window that would run off the bottom is moved up
instead, never past the top. Both the window frame (AppKit's frame autosave)
and the panel height (`config.json`) are remembered across launches.

The panel's three columns are an `HSplitView`, and the seam between the panel
and the camera is a drag handle that trades height between the two; the panel
follows the system appearance while the floating controls above it stay dark.

None of this raises the macOS 14 deployment target. Every use is behind
`#if compiler(>=6.2)` (the Liquid Glass symbols only exist in the macOS 26
SDK, which ships with Swift 6.2) and `#available(macOS 26.0, *)`. Both checks
live in `App/Sources/UI/LiquidGlass.swift`, which is also where the pre-26
fallbacks are. On macOS 14 and 15 the same chrome renders with the `.bar`
material as before.

## Effects and stages

An **effect** is a named list of **stages**. Only one effect renders at a
time: the one picked in the effect menu, which is also the one the editor
panel edits. There is nothing to enable or disable — picking an effect *is*
turning it on.

The effect menu lists both groups of effects. In Basic Mode it is a plain
menu; while the editor panel is open the same button unfolds a glass list laid
out like that menu, with the room to manage the effects as well as pick one:

- **Built-in** effects ship inside the app and are loaded straight from the
  bundle, so the list always matches the installed version. They can be
  activated and their controls adjusted (values are remembered), and in Editor
  Mode their stages and GLSL can be read — but not edited, renamed, reordered
  or deleted. Use **Duplicate to Custom** (the row's context menu in the
  effect list, the stage list's footer, or the editor header) to get an
  editable copy of the effect and its stages.
- **Custom** effects are yours: everything below about adding, editing and
  moving stages applies to them. In the unfolded effect list each one has a
  drag handle to reorder it and a **−** button to delete it (an effect with
  stages asks whether to delete them or move them to another effect), the
  row's context menu duplicates it, and **Add Effect** at the bottom creates
  a new one. Renaming is done in the stage list's header, with the pencil
  next to the effect's name.

Within an effect, stages run top to bottom, each one sampling the previous
stage's output through `uPrev`. The first stage of every effect sees the
scaled (and optionally mirrored) camera frame, identical to
`ceHistory(vUV, 0)`, so nothing carries over from whichever effect was active
before.

Every stage also keeps its output in its own texture, which any stage of the
effect can read with `ceStageTexture()` — by index (shown next to each stage
in the stage list) or by name. A stage reading its own texture gets its previous
frame, which is how feedback effects are built. See
[Stage textures and feedback](#stage-textures-and-feedback).

A stage that never samples `uPrev` does not build on its effect's chain — it
replaces the whole frame. Every stage before it in the same effect is
therefore invisible — unless some stage of the effect reads stage textures —
so the app skips those passes entirely and marks them in the stage list. Their
vision detectors do not run either.

Use Editor Mode to add, remove and duplicate stages (the duplicate lands right
below the original with the same shader and parameter values). Drag a stage by
its row to reorder it within the effect. The stage list only shows the active
effect, so moving a stage into another effect goes through the row's context
menu: **Move to** › the destination, where it lands last.

## Storage layout

Stages live in the app's sandbox container at
`~/Library/Containers/studio.polyglot.CameraEffects/Data/Library/Application Support/CameraEffects/Stages/`,
one folder per stage containing `shader.frag` (GLSL) and `stage.json`
(name + saved parameter values). You can edit them in the app's editor
(recompiles as you type) or in an external editor (hot-reloads on save).

Background images are copied into a `Backgrounds` folder next to `Stages`,
catalogued by `backgrounds.json`; they are separate from the media library
(`Media` and `media-library.json`), so deleting a background never unbinds a
shader's sampler. Which one is in use (absent for None) and the matte setting
are in `config.json` (`backgroundImageID`, `personMatteQuality`).

Which stages belong to which effect — and in what order — lives in
`config.json` next to the `Stages` folder. It is the only place that grouping
exists, so it is written immediately whenever it changes rather than on a
timer, and a `config.json` the app cannot read is set aside as
`config.unreadable.json` instead of being overwritten. A stage folder that no
config claims becomes an effect of its own, named after the folder, so it
stays reachable.

Built-in effects are never copied there. They are read from the app bundle
(`BuiltInEffects/effects.json` plus one folder per stage) on every launch, and
only the parameter values and media picks you change on them are saved, under
`builtInStageOverrides` in `config.json`. Earlier versions seeded copies of the
built-in stages into the `Stages` folder; those copies simply remain as custom
effects.

## Writing stages

Your shader is a GLSL 450 **fragment shader body**. The app injects a prelude
that declares the interface, so you only write `main()` plus an optional
`Params` block. The editor's `{ }` button lists every built-in symbol.

### Built-in interface

| Symbol | Type | Description |
| --- | --- | --- |
| `vUV` | `in vec2` | Fullscreen UV coordinates. (0, 0) is top-left; (1, 1) is bottom-right. |
| `outColor` | `out vec4` | Write the stage output here. |
| `uPrev` | `sampler2D` | Previous stage's output (or the scaled/mirrored camera frame for the first stage of an effect). Not sampling it disables every earlier stage — see [Effects and stages](#effects-and-stages). |
| `uFrames` | `sampler3D` | Last **N** raw camera frames. The z axis is history — prefer `ceHistory()` over manual z indexing. |
| `ceHistory(uv, ago)` | `vec4` | Sample the raw frame from `ago` frames ago (0 = newest). Handles ring-buffer wrapping. |

### Blur helpers

| Symbol | Type | Description |
| --- | --- | --- |
| `ceDiscBlur(tex, uv, radius, taps, falloff)` | `vec4` | Single-pass disc blur of any `sampler2D`. `radius` in pixels; `taps` is quality and cost (16–32 is plenty); `falloff` 0.0 = flat bokeh disc, 1.0 = soft Gaussian-like. Samples sit on a golden-angle spiral rotated per pixel, so few taps read as fine grain, not rings. |
| `ceGauss3x3(tex, uv, spread)` | `vec4` | Exact 3×3 Gaussian from four bilinear reads at half-texel offsets. `spread` = 1.0 is one texel; larger values widen it at the same cost. |
| `ceNoise(pixel)` | `float` | Per-pixel noise in [0, 1) with no visible pattern. Pass `vUV * uResolution`. |

```glsl
void main() {
    outColor = ceDiscBlur(uPrev, vUV, 12.0, 24, 1.0);
}
```

A single pass costs `taps` reads per pixel however wide the blur is, which is
the right trade for moderate radii. For a large, accurate Gaussian, use two
stages instead — one blurring horizontally, the next vertically through
`uPrev` — which needs 2N reads rather than N². And for a very wide, cheap blur
that may take a few frames to settle (backgrounds, glows), feed the result
back: `mix(ceSelfTexture(vUV), ceDiscBlur(uPrev, vUV, 6.0, 8, 1.0), 0.3)`.

### Stage textures and feedback

Each stage of the active effect owns one slice of `uStageTextures`, a
`sampler2DArray` indexed by the stage's position in the effect (the number
shown next to it in the stage list). After a stage has rendered, its result is
copied into its slice, so:

- stages **before** the current one hold **this frame's** output;
- the current stage and every stage **after** it still hold the **previous
  frame's** output.

Reading your own slice therefore gives you a feedback buffer with no extra
setup — there is nothing to configure or toggle. Slices start out transparent
black, and only the active effect's stages occupy GPU memory.

| Symbol | Type | Description |
| --- | --- | --- |
| `ceStageTexture(index, uv)` | `vec4` | Output of stage `index`. Also accepts the stage's **name** as a string literal: `ceStageTexture("Trail Buffer", vUV)`. Out-of-range indices and unknown names read transparent black. |
| `ceSelfTexture(uv)` | `vec4` | This stage's own output from the previous frame. Same as `ceStageTexture(uStageIndex, uv)`. |
| `uStageTextures` | `sampler2DArray` | The raw texture array; `texture(uStageTextures, vec3(uv, float(index)))`. Prefer `ceStageTexture()`, which range-checks. |
| `uStageIndex` | `int` (`CEStages`, binding = 23) | This stage's position in the effect, 0-based. |
| `uStageCount` | `int` (`CEStages`) | Number of stages in the effect. |

GLSL has no strings, so the name form is rewritten by the app before
compiling: each distinct name takes one of `CE_MAX_STAGE_REFS` (8) slots that
the app fills with the stage's current index whenever the effect's layout
changes. Names match a stage's display name first and its folder name second,
case-insensitively. Reordering or renaming never requires a recompile; a name
that matches no stage of the effect (or several) is reported as a warning on
that line and reads transparent black until fixed.

Example — a feedback buffer (`Light Trails` → `Trail Buffer`):

```glsl
void main() {
    vec4 camera = texture(uPrev, vUV);
    outColor = max(ceSelfTexture(vUV) * 0.92, camera);
}
```

Example — compositing two stages by name (`Light Trails` → `Trail Composite`):

```glsl
void main() {
    vec4 camera = ceHistory(vUV, 0);
    vec4 trails = ceStageTexture("Trail Buffer", vUV);
    outColor = vec4(camera.rgb + trails.rgb, camera.a);
}
```

The composite never samples `uPrev`, which on its own would make the buffer
stage dead work; reading it through `ceStageTexture()` keeps it rendering.
Because stage indices can be computed at runtime, an effect in which any stage
reads stage textures renders all of its stages.

### CEContext uniform block (binding = 2)

| Member | Type | Description |
| --- | --- | --- |
| `uResolution` | `vec2` | Output size in pixels (1280 × 720). |
| `uTime` | `float` | Seconds since the capture stream started. |
| `uTimeDelta` | `float` | Seconds since the previous rendered frame. |
| `uFrameCount` | `int` | Depth **N** of `uFrames` (Settings → Frame History). |
| `uHeadIndex` | `int` | z-slice index of the newest raw frame (0 … N − 1). |
| `uFrameNumber` | `int` | Frame counter since the stream started. |

### Vision data (bindings 16–21)

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
| `uFaceLeftEye[4]` | `vec4` (`CEFacePoints`, binding = 21) | Left-eye center of face _i_: xy = vUV position, z = 1 when located, w = half the eye's width (units of `uFaceRects.z`). |
| `uFaceRightEye[4]` | `vec4` (`CEFacePoints`) | Right-eye center, same layout. |
| `uFaceMouth[4]` | `vec4` (`CEFacePoints`) | Mouth center (outer-lip contour), same layout. |
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

`uFaceLeftEye`, `uFaceRightEye`, `uFaceMouth`, and `uFaceMask` all come from the
same facial-landmark pass, so referencing any of them upgrades face detection
from bounding boxes to landmarks. `uFaceRects` on its own keeps using the
cheaper rectangle detector. "Left" and "right" are Vision's own labels for the
landmark regions, matching the `uFaceMask` R and G channels; note that mirroring
swaps which side of the frame they land on.

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

Example — a glow on each eye, sized to the eye itself:

```glsl
void main() {
    outColor = texture(uPrev, vUV);
    for (int i = 0; i < uFaceCount; i++) {
        vec4 eyes[2] = vec4[2](uFaceLeftEye[i], uFaceRightEye[i]);
        for (int e = 0; e < 2; e++) {
            if (eyes[e].z < 0.5) { continue; }
            float radius = max(eyes[e].w * uResolution.x, 2.0);
            float d = distance(vUV * uResolution, eyes[e].xy * uResolution);
            outColor += vec4(1.0, 0.85, 0.2, 0.0) * (1.0 - smoothstep(0.0, radius, d));
        }
    }
}
```

### User-declared uniforms

| Symbol | Type | Description |
| --- | --- | --- |
| `Params` | `std140` block, binding = 3 | Optional stage parameters — become controls in the editor panel's stage controls column. |
| `yourSampler` | `sampler2D`, binding 4–15 | Optional 2D textures assigned from the media library. Accepts `// @metadata(global)`. |

Example stage:

```glsl
layout(std140, binding = 3) uniform Params {
    float amount;   // becomes a slider in the stage controls column
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

`min` / `max` update the controls on every compile. `default` is used only
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

A stage's controls live in the editor panel, so Basic Mode cannot reach them.
Add `global` (or `global=true`) to a parameter's `@metadata` and its control
is listed on the owning **effect** as well as on the stage — which is what the
floating controls pane shows, in both modes. Effects made of several stages
group the borrowed controls under each stage's name.

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
