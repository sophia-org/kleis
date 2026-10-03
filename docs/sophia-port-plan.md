# kleis on Sophia: native port plan

Status: plan. Depends on Sophia t294 (lock provider role and the
`sophia-lock-files-v1` 9P contract, being drafted) and t295 (C desktop SDK lock
client). Direction is set by Sophia ADR w0seozxx and plan 8jcykhdc.

## Role

On Sophia, kleis is a lock provider only: a separately admitted, sandboxed
renderer. Sophia Session owns lock state and the unlock verdict. Engine draws an
opaque cover on every head and puts kleis's images on top only where it holds an
exact presented candidate for that head and lock epoch. Session's
`sophia-factotum` checks the password through PAM. kleis never sees password
characters, never decides unlock, and if it dies the cover stays and unlock still
works.

kleis receives per-output allocations for the current lock epoch over the 9P
file contract, uploads premultiplied BGRA pixels, presents candidates, and
receives character-free events: Insert, Delete, Clear, Submit, Checking, Failed,
Unlocked, plus opaque IDs for UI chords it registered at negotiation (for
example Alt-B to toggle matrix and blank). It is built on Sophia's C desktop SDK
(vendored, as Hagia and Narthex do for their Nim clients).

## Decision: no Wayland build alongside

kleis is Sophia-native. `lockme` remains the Wayland locker and keeps the
Wayland path. Carrying both in one tree would keep `wayland.nim`, the PAM child
and the password buffer alive for a mode that no longer matches the security
model, and every shared-code change would need two proofs. The common code
(config, CLI, Matrix rendering, font) is small enough to stay in step by
copying fixes between the two repositories when needed. This tree already
carries the Wayland code today (the rename was source-only); phase 1 deletes it.

## Module map

| Module | Fate | Notes |
| --- | --- | --- |
| `kleis.nim` | replace | New entry point: connect, negotiate, run the provider loop. |
| `cli.nim` | keep | Drop `--dev-mode`/`--dev-window`/`--check-protocols`; add flags the provider config needs. |
| `config.nim` | keep | Same KDL; discovery paths unchanged. Sophia's `lock-provider { config }` may point at it. |
| `matrix.nim` | keep | Rain state and frame timing are renderer-independent. |
| `matrix_render.nim` | keep | CPU renderer; writes premultiplied BGRA into the upload buffer. Check channel order and alpha against the contract. |
| `font64x128.nim`, `scripts/generate-cntr-font.py`, `third_party/cntr-font` | keep | CNTR attribution unchanged. |
| `matrix_gpu.nim`, `matrix_gpu_shim.*`, `vendor/sokol_gfx.h` | defer | Later phase; see GPU below. Compiled out of the first Sophia build. |
| `password.nim` | drop | Page-aligned `mlock`ed buffer moves into Session's secret buffer. |
| `auth.nim` and the PAM child | drop | Hardening (`mlockall`, dumpability, closed fds, no faillock) lives in `sophia-factotum`. `pam.d/kleis*` leaves with it; Sophia ships `sophia-lock`. |
| `wayland.nim`, `wayland_shim.*`, `protocols/` | drop | Replaced by an SDK shim and a thin Nim wrapper. |
| `preview.nim` | drop, then replace | The xdg-shell dev window goes. A small headless harness (render N frames of a given config to a PNG or raw file) replaces it for visual checks, and a fake lock peer replaces it for protocol checks. |
| `tests/test_password.nim` | drop | Nothing left to test. |
| `tests/test_cli.nim`, `test_config.nim`, `test_matrix.nim` | keep | Adjust for flag changes. |

New: `sophia.nim` (wrapper over the C SDK lock client: allocation, upload,
present, event stream) and `ui.nim` (state machine below), with a vendored SDK
under `vendor/`, pinned and checksummed.

## Behaviour mapping

Today the palette and fail colour are driven by key presses in `wayland.nim`.
On Sophia they are driven by edit and status events:

- Insert and Delete advance the input palette (the same rotation as now, wrapping
  after the last entry). Without characters, the palette is the only per-key
  feedback; it reveals nothing beyond the key count change the event already
  conveys.
- Failed switches to the fail colour; Checking may show a neutral state.
- Clear, Unlocked-to-locked transitions and idle return to the init colour.
- Submit shows Checking until Failed or Unlocked arrives; kleis does not time it out.
- Idle-timeout blanking stays local: any event resets the idle clock; on expiry
  kleis presents a blank candidate, and any event restores rain. Blank is a
  rendering choice; the Engine cover is already opaque.
- A registered chord ID (Alt-B) toggles matrix and blank locally. Chords must
  include a non-Shift modifier and never reach the secret.
- Per-output rendering uses the allocation size, scale and epoch from the
  contract; hotplug while locked arrives as new allocations, and a frame for a
  stale epoch is dropped by kleis before sending.

## Phases

1. Strip and split. Delete Wayland, PAM, password and preview code, vendor the
   C SDK once t295 publishes it, and keep the pure modules building and tested.
   Needs: nothing from Sophia beyond a pinned SDK commit for the vendor step.
2. Renderer to buffer. Make `matrix_render` write into a caller-supplied BGRA
   buffer of the allocation's stride; add the headless harness. Needs: t294
   buffer layout (stride, format, alpha) in the draft contract.
3. Provider connection. Negotiate, receive allocations, upload, present, handle
   epoch changes and reconnection with a fresh connection epoch; fake peer for
   tests. Needs: t294 codec and role endpoint (`SOPHIA_LOCK_9P_SOCKET`),
   admission and protection-domain role; t295 C lock client.
4. Events and UI. Event stream into the state machine above; chord
   registration; idle blanking. Needs: t294 event records and chord ID rules.
5. Operator integration. Executable and config selection through
   `session { lock-provider { executable; config; gpu } }`, supervised restart,
   crash and stall behaviour verified to leave the cover. Needs: t294 supervision;
   t297 attended acceptance (two outputs, hotplug while locked, VT round trip,
   provider kill, wrong and right password) which Sophia runs, with kleis
   supplying the exact build.
6. GPU, later. Only after phases 1-5 are accepted: an explicit render-node
   grant (denied by default) with GPU render and CPU readback into the upload
   buffer, following Lom's model. Needs: a Sophia render-node grant for the lock
   role and its permission decision; the readback path must not change what
   leaves kleis (still premultiplied BGRA in the allocation).

## Not changing

Matrix look, fonts, config format and CLI names stay, so existing configs work.
License, copyright and the CNTR attribution are unchanged. The lock model's
security claims belong to Sophia, not kleis; the README should say that kleis on
Sophia holds no secret.

## Open questions

- Exact pixel format, stride and cursor/damage rules (t294 byte layouts).
- Lock budget limits per output, which cap the largest buffer kleis can hold.
- Whether config reload is needed while locked (proposal: read once at start).
