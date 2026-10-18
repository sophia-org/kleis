# kleis

A Matrix rain lock provider for Sophia. Session starts kleis in its lock
provider sandbox and owns authentication, keyboard input and the opaque cover.
kleis receives character-free UI events and per-output pixel allocations. It
never receives a password and cannot unlock the session. If it stops or fails,
Sophia keeps the cover and authentication available.

kleis began as the Wayland locker `lockme`. This tree now uses Sophia's C
desktop SDK and lock file contract; the old Wayland and PAM commands do not
apply. The lock contract and SDK API are experimental.

## Build and checks

Requires Linux, Nim 2.2 or newer, Nimble, a C compiler, pkg-config, nimkdl 2.1
or newer, and GBM, EGL and GLES3 development headers. The pkg-config modules
are `gbm`, `egl` and `glesv2`. Dependencies must be available locally for the
offline commands.

Session's `SOPHIA_LAUNCH_AUTH_FD` selects the C SDK's launch-authentication
conversation before lock-file negotiation. Startup polls both transports under
the SDK's five-second deadline and lends the authenticated root to the lock
client. The generation channel stays open, close-on-exec, until teardown.
Malformed descriptors and failed verification refuse startup; they never fall
back to plain attach. Supplied-admission tests without the descriptor retain
their separate plain-attach path.

```sh
nimble --offline build
nimble --offline test
nimble fmtCheck
```

`nimble installBin` installs the binary and creates the example configuration
only if none exists. It does not install a PAM stack or activate a lock.
Sophia's profile selects the executable, configuration and GPU policy. Use
Sophia's `session:lock` action to lock. The selected provider is supervised by
Session; running kleis alone without its endpoint is an error.

## Rendering

With an explicit direct GPU grant, kleis opens exactly the granted render
node, checks its device identity and creates an offscreen GBM/EGL GLES3
context. The Matrix shaders render at each allocation's full pixel size.
A fenced PBO readback produces top-first, opaque BGRA pixels for the existing
lock upload contract. A software Mesa renderer is not accepted as GPU
acceleration. There is no alternate device search.

Without a grant, with `no-gpu #true`, or after a GPU failure, rendering uses
the CPU. The renderer choice or fallback reason is reported once. `--no-gpu`
prevents EGL initialization; it does not remove linked libraries.

One worker owns rendering and readback. The provider thread handles the
socket and UI events independently. Each output has two bounded pixel slots;
a borrowed frame remains immutable until copied into a sealed source. The GPU also
holds a native-size renderbuffer, a PBO and grid textures per output. Removed
or resized outputs release their resources once outstanding leases finish.

Uploads require lock r2 and the sealed-image grant. Each frame is copied into
one sealed memfd and offered over the image channel. Outputs take turns.
Obsolete rain can be cancelled, while a started feedback color finishes and
further edits coalesce. Busy admission retains the sealed source; ImageBegin
and Cancel retry through the SDK. Presentation waits for Accepted and
SourceReleased(Retained). Missing readiness or unsettled transfer expiry fails
the connection; there is no byte-upload fallback.
Animation uses monotonic elapsed time without catch-up bursts.

## Configuration

Sophia supplies the selected configuration as `SOPHIA_LOCK_CONFIG`; the
sandbox has no HOME. CLI options override file values. See
[examples/config.kdl](examples/config.kdl) and `kleis --help`.

Matrix rain is the default. Typing cycles the input palette; failed
authentication shows the failure color. Alt-B toggles Matrix and blank.
`blank #true` starts blank. `idle-timeout` blanks after that many seconds
without UI activity (default 300; 0 never blanks), stopping all rendering
while unattended. `matrix-fps` sets
the rain's frame rate (1-120, default 30); each frame is rendered and uploaded,
so a lower rate and an idle timeout save power on a laptop.

```kdl
no-gpu #false
matrix-fps 30
matrix-cell-scale 2.0
matrix-fall-speed 0.3
matrix-cycle-speed 0.03
matrix-raindrop-length 0.75
matrix-brightness-decay 1.0
```

`matrix-cell-scale "auto"` fits about 80 columns independently on each output:
2560 pixels gives 32-pixel cells; 1920 gives 24-pixel cells. A numeric scale
sets cells in multiples of eight pixels, so 2.0 gives 16-pixel cells on both.
This changes glyph size, not framebuffer resolution. Frame interval controls
how often frames are requested; the transport and presentation cadence can
limit delivery. The remaining four settings control motion, glyph changes,
trail length and fading on both backends.

| UI state | Default color |
| --- | --- |
| Blank | Black `0x000000` |
| First input | Indigo `0x4B0082` |
| Second input | Royal blue `0x003366` |
| Third input | Green `0x006400` |
| Authentication failure | Crimson `0x8B0000` |

Configuration is read at startup. Change the profile or configuration through
Sophia's supported release/session flow, then start a new provider/session.

## Development and evidence

Unit tests cover UI state, output fairness, slot custody, topology changes,
animation timing and fallback. Software EGL tests are compiled only with
`kleisGpuSoftwareTest`; production never enables that path. An explicit
`KLEIS_GPU_TEST_RENDER_NODE` opts the worker test into an offscreen real-device
check. Sophia owns the real lock-service and end-to-end authentication tests.
Headless renderer or service throughput does not prove physical lock cadence.

`nimble render` builds the legacy CPU preview utility `tools/kleis_render`.
It can write a PPM without a session; its step-based animation is a visual aid,
not a timing test of the worker. The native port history is in
[docs/sophia-port-plan.md](docs/sophia-port-plan.md).

## Attribution

The glyph atlas uses CNTR's `KoineGreek.ttf`, copyright 2012–2023 Alan Bunning /
Center for New Testament Restoration, distributed under CC BY-SA 4.0. The
checked-in source is under `third_party/cntr-font`; `nimble regenFont` uses
Python, Pillow and fontTools. The Matrix shaders adapt Rezmason's MIT-licensed
Matrix rain renderer. Existing source and third-party notices are preserved.
