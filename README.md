# macompiz

Compiz-style window effects on macOS — **wobbly windows**, a **burning** close
animation, **water** ripples, and a rotating **desktop cube** for switching
spaces. Inspired by [this demo](https://x.com/asciidiego/status/2113795531650818065)
by [@asciidiego](https://x.com/asciidiego).

It's a small AppKit + Metal app. The note windows are drawn by the app itself
(faux title bar + a tiny Markdown renderer), and a Metal pipeline distorts each
window's rendered texture in real time. Shaders are compiled **at runtime** from
source, so you only need a Swift toolchain — no full Xcode, no `metal` CLI.

![demo](docs/demo.png)

## What works

| Effect | Trigger |
| --- | --- |
| **Wobbly window** (jelly lag) | Drag a note by its body |
| **Water / aquarium** ripples | Click a note, or `Effects ▸ Splash` (`⌘W`) |
| **Burn to close** | Click the red traffic light |
| **Desktop cube** space switch | `Effects ▸ Next/Prev space` (`⌘]` / `⌘[`) |
| **Markdown notes** | `#`/`##` headings, `**bold**`, `*italic*`, `` `code` `` |

The cube rotates a **real capture of your current desktop** (via
ScreenCaptureKit) away to reveal the next space. When you have more than one
macOS Space, macompiz uses the private **SkyLight** API to enumerate them and
switch for real — masking the switch behind a cover window and capturing the
*actual* destination desktop as the incoming face. If you only have one Space, or
the OS refuses the switch, it falls back to a synthetic desktop. All of this runs
with **SIP enabled**; going further (foreign-app windows, every face live) is the
[SIP route](docs/SIP.md).

## Run

```bash
swift run
```

Requires macOS 14+ and a Swift 6 toolchain (Command Line Tools is enough).

## How it works

- `NoteRenderer` rasterizes a note (title bar + Markdown body) into an `NSImage`.
- `GPU` compiles the Metal library from `Shaders.swift` at launch and uploads
  that image as a texture, plus a deformable triangle grid.
- `NoteMetalView` is a borderless `MTKView` window. The **vertex** shader
  displaces grid points for the wobble (the body lags behind the cursor); the
  **fragment** shader samples the texture with ripple offsets (water) and runs a
  noisy bottom-to-top front for the burn.
- `CubeView` renders two space textures on adjacent cube faces behind a
  perspective camera and rotates 90° to switch — the classic desktop cube.
- `ScreenCapture` grabs the live desktop with **ScreenCaptureKit**
  (`SCScreenshotManager`, a one-shot still) to use as the real outgoing cube
  face. It needs the **Screen Recording** permission; macOS prompts on first use,
  and if it's denied the cube falls back to a synthetic desktop.
- `SkyLight` resolves private `SLS*` symbols with `dlsym` at runtime (nothing
  private is linked at build time) to enumerate Spaces, read the active one, and
  attempt a real Space switch — all from our own process, SIP on. Everything is
  non-destructive; missing symbols or an OS refusal degrade to the synthetic cube.

## Scope & the "real compositor" question

The original demo pokes at the macOS compositor directly. macompiz deliberately
stays in **user space with SIP enabled**: every pixel it distorts is a window it
drew itself, so it needs no entitlements, no injection, and nothing breaks on a
macOS update.

Reaching *other* apps' windows is a different game: on macOS the `WindowServer`
is the compositor and an ordinary app can't restyle another app's windows. The
two established routes are **ScreenCaptureKit** (SIP-friendly, read-only — what
the cube uses to snapshot your desktop) and a **scripting addition loaded into
Dock/WindowServer** with SIP partially disabled, the approach
[yabai](https://github.com/koekeishiya/yabai) documents.

ScreenCaptureKit can only snapshot the space you're *currently* on; genuinely
peeking into other Spaces (to texture every cube face live) needs private
SkyLight APIs. That injection layer is intentionally **not** included here — see
yabai and [saagarjha's Spaces notes](https://news.ycombinator.com/item?id=23241073)
for prior art if you want to go there.

## License

MIT
