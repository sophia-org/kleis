## Real provider with supplied lock decisions over private 9P and SEQPACKET.
## ImageBegin and ResourceCancel each receive EAGAIN once. The peer checks
## sealed descriptors and forbids frame demand before source settlement.

import std/[os, posix, times, unittest]

import ../src/kleis/cli
import ../src/kleis/provider

const sdkSource =
  currentSourcePath().parentDir / ".." / "vendor" / "sophia-desktop-sdk" / "source" /
  "src"
{.passC: "-I" & sdkSource.}
{.compile: "support/lock_peer.c".}

type Peer = pointer

proc peerNew(fd: cint, directory: cstring): Peer {.importc: "kleis_peer_new".}
proc peerFree(k: Peer) {.importc: "kleis_peer_free".}
proc peerLock(
  k: Peer, lockEpoch: uint64, outputs: uint16
) {.importc: "kleis_peer_lock".}

proc peerArmAgain(
  k: Peer, endCount, cancelCount: cuint
) {.importc: "kleis_peer_arm_again".}

proc peerHoldUploads(k: Peer, hold: cint) {.importc: "kleis_peer_hold_uploads".}
proc peerReleaseUploads(k: Peer) {.importc: "kleis_peer_release_uploads".}
proc peerPump(k: Peer) {.importc: "kleis_peer_pump".}
proc cancelSubmits(k: Peer): cuint {.importc: "kleis_peer_cancel_submits".}
proc beginSubmits(k: Peer): cuint {.importc: "kleis_peer_begin_submits".}
proc demandSubmits(k: Peer): cuint {.importc: "kleis_peer_demand_submits".}
proc heldUploads(k: Peer): cuint {.importc: "kleis_peer_held_uploads".}
proc negotiated(k: Peer): cint {.importc: "kleis_peer_negotiated".}
proc uploadOpen(k: Peer): cint {.importc: "kleis_peer_upload_open".}
proc caughtUp(k: Peer): cint {.importc: "kleis_peer_caught_up".}

proc candidateSubmits(k: Peer): cuint {.importc: "kleis_peer_candidate_submits".}
proc peerPrefixEvents(k: Peer) {.importc: "kleis_peer_prefix_events".}
proc outputCandidates(
  k: Peer, output: cuint
): cuint {.importc: "kleis_peer_output_candidates".}

proc providerMain(animate: bool) {.thread.} =
  {.cast(gcsafe).}:
    var opts = defaultOptions()
    opts.blank = not animate
    opts.noGpu = true
    try:
      runProvider(opts)
    except CatchableError as error:
      stderr.writeLine("provider test exit: " & error.msg)

type Session = object
  dir: string
  listener: SocketHandle
  fd: cint
  peer: Peer
  thread: Thread[bool]

proc start(name: string, animate = false): Session =
  result.dir = getTempDir() / ("kleis-provider-" & name & "-" & $getpid())
  removeDir(result.dir)
  createDir(result.dir)
  let path = result.dir / "lock.sock"
  result.listener = socket(AF_UNIX, SOCK_STREAM, 0)
  var address: Sockaddr_un
  address.sun_family = TSa_Family(AF_UNIX)
  for i, c in path:
    address.sun_path[i] = c
  doAssert bindSocket(
    result.listener, cast[ptr SockAddr](addr address), SockLen(sizeof(address))
  ) == 0
  doAssert listen(result.listener, 1) == 0
  putEnv("SOPHIA_LOCK_9P_SOCKET", path)
  delEnv("SOPHIA_LOCK_CONFIG")
  for name in ["SOPHIA_SHELL_GPU_MODE", "SOPHIA_SHELL_GPU_RENDER_NODE"]:
    delEnv(name)
  createThread(result.thread, providerMain, animate)
  result.fd = cint(accept(result.listener, nil, nil))
  doAssert result.fd >= 0
  result.peer = peerNew(result.fd, result.dir.cstring)

proc serve(s: Session, ms: int, done: proc(): bool): bool =
  ## Answers the provider until `done` or the deadline.
  let deadline = epochTime() + ms / 1000
  while epochTime() < deadline:
    var fd = TPollfd(fd: s.fd, events: POLLIN)
    discard poll(addr fd, 1, 10)
    s.peer.peerPump()
    if done():
      return true
  done()

proc finish(s: var Session) =
  discard posix.close(s.fd) # the provider fails its next service and exits
  joinThread(s.thread)
  discard posix.close(cint(s.listener))
  s.peer.peerFree()
  removeDir(s.dir)

suite "provider retries every staged submission":
  test "Accepted waits for SourceReleased before demand":
    var s = start("settlement")
    check s.serve(
      3000,
      proc(): bool =
        s.peer.negotiated() != 0,
    )
    s.peer.peerHoldUploads(2)
    s.peer.peerLock(3, 1)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.heldUploads() > 0,
    )
    discard s.serve(
      100,
      proc(): bool =
        false,
    )
    check s.peer.demandSubmits() == 0
    s.peer.peerReleaseUploads()
    check s.serve(
      3000,
      proc(): bool =
        s.peer.demandSubmits() > 0,
    )
    s.finish()

  test "an ImageBegin answered EAGAIN once is retried and settles":
    var s = start("end")
    check s.serve(
      3000,
      proc(): bool =
        s.peer.negotiated() != 0,
    )
    s.peer.peerArmAgain(1, 0)
    s.peer.peerLock(1, 1)
    # Begin, the bytes, End (EAGAIN), End again, Accepted, then the frame is
    # demanded: nothing else in this session could wake a stalled provider.
    let recovered = s.serve(
      3000,
      proc(): bool =
        s.peer.demandSubmits() > 0,
    )
    check s.peer.beginSubmits() == 2
    check recovered
    s.finish()

  test "a Cancel answered EAGAIN once is retried and uploads resume":
    var s = start("cancel")
    check s.serve(
      3000,
      proc(): bool =
        s.peer.negotiated() != 0,
    )
    s.peer.peerArmAgain(0, 1)
    s.peer.peerHoldUploads(1)
    s.peer.peerLock(1, 1)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.heldUploads() > 0,
    )
    # The output goes away while the peer holds source settlement.
    s.peer.peerLock(1, 0)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.caughtUp() != 0,
    )
    let cancelled = s.serve(
      3000,
      proc(): bool =
        s.peer.cancelSubmits() == 2 and s.peer.uploadOpen() == 0,
    )
    check s.peer.cancelSubmits() == 2
    check cancelled
    s.peer.peerReleaseUploads()
    # Once settled, a new output uploads: the SDK is free again.
    check s.serve(
      3000,
      proc(): bool =
        s.peer.caughtUp() != 0,
    )
    s.peer.peerLock(1, 1)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.beginSubmits() == 2,
    )
    s.finish()

  test "coalesced custody, permit and outcome keep rain advancing":
    var s = start("coalesced-progress", animate = true)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.negotiated() != 0,
    )
    s.peer.peerLock(3, 1)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.candidateSubmits() >= 3,
    )
    s.finish()

  test "both outputs progress when receipts follow an earlier visible event":
    var s = start("two-outputs", animate = true)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.negotiated() != 0,
    )
    s.peer.peerPrefixEvents()
    s.peer.peerLock(3, 2)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.outputCandidates(0) >= 3 and s.peer.outputCandidates(1) >= 3,
    )
    s.finish()
