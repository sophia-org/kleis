# Provisioned launch authentication

The t317 installation review found that this lock provider still selected plain
attach, which the new authenticated Session owner correctly refuses. The client
now vendors signed C SDK `e28fecd3e63133268d21538cf5107611ca0c6f31` and drives
its launch helper before giving the admitted root to the existing lock client.
Kleis owns fd discovery, bounded polling and lifetime; the SDK owns the exchange.
Failure never retries plain attach. No rendering or unlock authority changes.

`nimble --offline test` passed 142 checks with two explicit skips; the new
scripted startup test separately passed success, relay/role refusals, descriptor
bounds and the five-second silent-peer deadline. Formatting and strict C syntax
checks passed. A rebuilt normal executable passed the external overlay
`tests/authenticated_owner.rs` against Sophia `8fc62dd48`: the real protected
lock owner, coordinator, Factotum export and afid dispatch admitted it at epochs
1 and 2, with connected liveness and retirement between launches. Session's
trusted Factotum channel and the locked object are supplied. Rendering is CPU
with no physical display, and no pixels or unlock behavior are qualified.

Evidence package `t317-kleis-install-01` lives under the operator's development
evidence directory. It records the complete changed-file inventory, binary
path/hash, logs and overlay runner; binaries are not copied. Three initial
overlay failures are retained: missing endpoint environment, an incorrect
synchronous-retirement expectation and an inappropriate successful-exit check
for a deliberately terminated child. The final owner run passes one exact test.
The overlay leaves Sophia source unchanged; its compiled Session package is
cleaned under the cargo-slot lease afterward.

This closes the installed provider's startup compatibility gap. Whole-desktop
assembly and attended lock rendering remain separate installation checks.
