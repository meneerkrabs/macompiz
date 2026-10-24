# The SIP route — affecting *other* apps' windows

macompiz runs entirely in user space with SIP **enabled**. It distorts windows it
drew itself, captures the desktop read-only with ScreenCaptureKit, and talks to
SkyLight (`SLS*`) only for Space queries and an *attempted* active-Space switch.
That's everything you can do safely.

To go further — give an arbitrary app's window real opacity/shadow/transform,
live-texture *every* cube face from other Spaces, or create stable Spaces — you
need code running somewhere that is allowed to issue privileged WindowServer
transactions. A normal process can't: on macOS the `WindowServer` is the
compositor and it only accepts those requests from trusted clients. This page
documents the established architecture so you can build on it; macompiz itself
deliberately does **not** ship it.

## How the privileged route works (the yabai model)

[yabai](https://github.com/koekeishiya/yabai) is the reference. The shape:

1. **Partially disable SIP.** From Recovery, `csrutil` is set so that loading an
   unsigned *scripting addition* into a system app is permitted. On Apple Silicon
   this also involves allowing non-Apple arm64e ABI. The exact flags and the
   per-release caveats are maintained in yabai's wiki, which is the only source
   worth trusting because it changes with every macOS version:
   - <https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection>
   - <https://github.com/koekeishiya/yabai/wiki/Installing-yabai-(latest-release)#configure-scripting-addition>

2. **Load a scripting addition into Dock.app.** `Dock.app` is a trusted
   WindowServer client. A scripting addition (`.osax`) loaded into it can relay
   privileged `SLS*` calls that your own process is refused. yabai's addition
   lives in [`src/osax`](https://github.com/koekeishiya/yabai/tree/master/src/osax)
   — it's open source and the thing to read and adapt.

3. **Talk to the addition over a local socket.** Your app sends commands; the
   in-Dock addition executes the privileged compositor ops and returns results.

## What it unlocks

- Per-window opacity, shadow, and sticky/all-spaces flags for *foreign* apps.
- Creating/destroying Spaces and moving windows between them without the stock
  Mission Control animation.
- Driving the real transition that a cube like this one would wrap.

## The costs (read before you do it)

- **It weakens your Mac's security posture.** Partial SIP disable is a real
  reduction in the protections that stop untrusted code from touching the system.
  Only do it on a machine you own and understand the trade-off on.
- **It breaks on macOS updates.** Offsets, symbols, and SIP semantics shift
  between releases; expect to reinstall the addition (and sometimes re-check the
  SIP flags) after each update.
- **It can destabilize `WindowServer`/`Dock`.** Bugs in a scripting addition can
  crash the whole session.

## Why macompiz doesn't include an injector

Hand-rolling a bespoke payload that injects into a privileged Apple daemon is the
single most fragile and most abuse-shaped artifact in this space, and it would
break your system on the next update. The responsible path is to reuse yabai's
audited, open-source scripting addition rather than reproduce one here. If you
want macompiz to drive real cross-Space/cross-app compositing, wire it to a
yabai-style addition over a socket and keep the privileged code in that
well-reviewed component.
