## The real provider loop against the C SDK's scripted lock-file peer. Sophia
## may answer any submission with EAGAIN when its inbound queue is full; the
## provider must retry it whoever submitted it. Here End and Cancel, which the
## upload path submits itself, each get EAGAIN once. The view is blank and the
## GPU unused, so no animation or other event can unstick a stalled provider.

import std/[os, posix, times, unittest]

import ../src/kleis/cli
import ../src/kleis/provider

const sdkSource =
  currentSourcePath().parentDir / ".." / "vendor" / "sophia-desktop-sdk" / "source" /
  "src"
{.passC: "-I" & sdkSource.}
{.compile: "support/lock_peer.c".}

type Peer = pointer

proc peerNew(fd: cint): Peer {.importc: "kleis_peer_new".}
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
proc endSubmits(k: Peer): cuint {.importc: "kleis_peer_end_submits".}
proc cancelSubmits(k: Peer): cuint {.importc: "kleis_peer_cancel_submits".}
proc beginSubmits(k: Peer): cuint {.importc: "kleis_peer_begin_submits".}
proc demandSubmits(k: Peer): cuint {.importc: "kleis_peer_demand_submits".}
proc uploadEnds(k: Peer): cuint {.importc: "kleis_peer_upload_ends".}
proc heldUploads(k: Peer): cuint {.importc: "kleis_peer_held_uploads".}
proc negotiated(k: Peer): cint {.importc: "kleis_peer_negotiated".}
proc uploadOpen(k: Peer): cint {.importc: "kleis_peer_upload_open".}
proc caughtUp(k: Peer): cint {.importc: "kleis_peer_caught_up".}

proc providerMain() {.thread.} =
  {.cast(gcsafe).}:
    var opts = defaultOptions()
    opts.blank = true
    opts.noGpu = true
    try:
      runProvider(opts)
    except CatchableError:
      discard # the peer closed the connection: the test is over

type Session = object
  dir: string
  listener: SocketHandle
  fd: cint
  peer: Peer
  thread: Thread[void]

proc start(name: string): Session =
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
  createThread(result.thread, providerMain)
  result.fd = cint(accept(result.listener, nil, nil))
  doAssert result.fd >= 0
  result.peer = peerNew(result.fd)

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
  test "an End answered EAGAIN once is retried and the upload completes":
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
    check s.peer.beginSubmits() == 1
    check s.peer.endSubmits() == 2
    check s.peer.uploadEnds() == 1
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
    # The output goes away mid-upload: the provider cancels. The held write
    # drains first, then Cancel meets EAGAIN once.
    s.peer.peerLock(1, 0)
    check s.serve(
      3000,
      proc(): bool =
        s.peer.caughtUp() != 0,
    )
    s.peer.peerReleaseUploads()
    let cancelled = s.serve(
      3000,
      proc(): bool =
        s.peer.cancelSubmits() == 2 and s.peer.uploadOpen() == 0,
    )
    check s.peer.cancelSubmits() == 2
    check cancelled
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
    check s.peer.endSubmits() == 0
    s.finish()
