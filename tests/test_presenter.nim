import std/unittest

import ../src/kleis/presenter

proc alloc(output: uint64, generation = 1'u64): Allocation =
  Allocation(
    output: output,
    outputGeneration: 1,
    allocation: 40 + output,
    allocationGeneration: generation,
    width: 4,
    height: 2,
  )

proc take(p: var Presenter, kind: ActionKind): Action =
  result = p.next()
  check result.kind == kind
  p.applied(result)

suite "presenter":
  test "nothing happens until a lock grants an output":
    var p = initPresenter()
    check p.next().kind == akNone

  test "upload, demand, offer, present, then retire the replaced image":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1)])
    let up = p.take(akUpload)
    check p.next().kind == akNone # one upload at a time, nothing else to do
    p.uploadStatus(up.resource, 1)
    p.uploadStatus(up.resource, 2)
    let demand = p.take(akDemand)
    p.permit(41, 1, demand.demand, 77)
    let offer = p.take(akCandidate)
    check offer.resource == up.resource
    p.outcome(41, offer.candidateGeneration, 2)
    check p.outputs[0].shown == up.resource and p.retiring.len == 0
    # The next frame replaces it; the first image is retired once presented.
    p.markDirty()
    let up2 = p.take(akUpload)
    p.uploadStatus(up2.resource, 2)
    let d2 = p.take(akDemand)
    p.permit(41, 1, d2.demand, 78)
    let o2 = p.take(akCandidate)
    p.outcome(41, o2.candidateGeneration, 2)
    let retire = p.take(akRetire)
    check retire.resource == up.resource
    check p.outputs[0].shown == up2.resource

  test "a permitted candidate goes before anything else":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1), alloc(2)])
    let up = p.take(akUpload)
    p.uploadStatus(up.resource, 2)
    let d = p.take(akDemand)
    p.retiring.add 99 # some retirement is waiting
    p.permit(41, 1, d.demand, 7)
    check p.next().kind == akCandidate

  test "transactions, demands, resources and candidates only increase":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1)])
    var last = 0'u64
    for _ in 0 ..< 3:
      p.markDirty()
      let up = p.take(akUpload)
      check up.transaction > last
      last = up.transaction
      p.uploadStatus(up.resource, 2)
      let d = p.take(akDemand)
      check d.transaction > last
      last = d.transaction
      p.permit(41, 1, d.demand, 1)
      let o = p.take(akCandidate)
      check o.transaction > last
      last = o.transaction
      p.outcome(41, o.candidateGeneration, 2)
      while p.next().kind == akRetire:
        let r = p.take(akRetire)
        check r.transaction > last
        last = r.transaction

  test "a stale image is dropped before it is offered":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1)])
    let up = p.take(akUpload)
    p.uploadStatus(up.resource, 2)
    p.markDirty()
    let drop = p.take(akDropReady)
    check drop.resource == up.resource
    check p.next().kind == akUpload

  test "a rejected or superseded candidate is offered again":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1)])
    let up = p.take(akUpload)
    p.uploadStatus(up.resource, 2)
    let d = p.take(akDemand)
    p.permit(41, 1, d.demand, 1)
    let o = p.take(akCandidate)
    p.outcome(41, o.candidateGeneration, 3)
    check p.next().kind == akDemand

  test "a permit for another demand or allocation is ignored":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1)])
    let up = p.take(akUpload)
    p.uploadStatus(up.resource, 2)
    let d = p.take(akDemand)
    p.permit(41, 1, d.demand + 1, 1)
    p.permit(41, 2, d.demand, 1)
    p.permit(42, 1, d.demand, 1)
    check p.next().kind == akNone

  test "a new lock epoch voids the offer; a dropped output is retired":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1), alloc(2)])
    let up = p.take(akUpload)
    p.uploadStatus(up.resource, 2)
    let d = p.take(akDemand)
    p.permit(41, 1, d.demand, 1)
    let o = p.take(akCandidate)
    p.outcome(41, o.candidateGeneration, 2)
    # A new lock keeps output 1 and drops output 2 (still uploading nothing).
    p.setLock(true, 6, [alloc(1)])
    check p.outputs.len == 1 and p.outputs[0].shown == up.resource
    check p.outputs[0].dirty
    # The topology changes again: output 1's allocation is replaced.
    p.setLock(true, 6, [alloc(1, generation = 2)])
    check p.outputs.len == 1 and p.outputs[0].shown == 0
    check p.take(akRetire).resource == up.resource

  test "an output that goes away mid-upload cancels it, and a late accept is retired":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1)])
    let up = p.take(akUpload)
    p.setLock(true, 5, [alloc(2)])
    check p.cancelUpload
    check p.next().kind == akRetire or p.next().kind == akNone
    p.uploadStatus(up.resource, 2) # it completed before the cancel
    check not p.cancelUpload
    check up.resource in p.retiring

  test "unlocking stops drawing and retires every image":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1)])
    let up = p.take(akUpload)
    p.uploadStatus(up.resource, 2)
    p.setLock(false, 5, [])
    check p.outputs.len == 0
    check p.take(akRetire).resource == up.resource
    check p.next().kind == akNone

  test "a refused record blocks its output until the next lock object":
    var p = initPresenter()
    p.setLock(true, 5, [alloc(1)])
    let up = p.next()
    p.refused(up)
    check p.next().kind == akNone
    p.setLock(true, 5, [alloc(1)])
    check p.next().kind == akUpload
