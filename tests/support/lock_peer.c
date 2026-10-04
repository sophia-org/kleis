/* A scripted Sophia lock-file peer for kleis provider tests: the C SDK's own
 * test peer (vendored lock_client_test.c, unmodified) served over the
 * connection the provider opened, plus one-shot faults this file adds. */
/* glibc's lockf() macros (F_LOCK and friends) collide with the peer's file
 * names outside strict C99; the peer uses neither lockf nor them. */
#include <unistd.h>
#undef F_ULOCK
#undef F_LOCK
#undef F_TLOCK
#undef F_TEST
#define main kleis_sdk_lock_client_test_main
#include "../../vendor/sophia-desktop-sdk/source/src/tests/lock_client_test.c"
#undef main

struct kleis_peer {
  struct peer peer;
  unsigned again_end, again_cancel;   /* EAGAIN for the next End / Cancel */
  unsigned end_submits, cancel_submits, begin_submits, demand_submits;
};

struct kleis_peer *kleis_peer_new(int fd) {
  struct kleis_peer *k = calloc(1, sizeof(*k));
  struct sophia_lf_record l;
  assert(k);
  k->peer.fd = fd;
  k->peer.api = "sophia-lock-files version=1 epoch=7\n";
  memset(&l, 0, sizeof(l));
  l.header.kind = SOPHIA_LF_LIMITS;
  l.header.epoch = EPOCH;
  l.value.limits = limits;
  assert(!sophia_lf_encode(k->peer.limits, sizeof(k->peer.limits), &l,
                           &k->peer.limits_size));
  publish(&k->peer, SOPHIA_LF_UNLOCKED, 0, 0);
  return k;
}

void kleis_peer_free(struct kleis_peer *k) { free(k); }

/* A new lock object: locked under `lock_epoch` with `outputs` 4x2 outputs. */
void kleis_peer_lock(struct kleis_peer *k, uint64_t lock_epoch, uint16_t outputs) {
  publish(&k->peer, SOPHIA_LF_LOCKED, lock_epoch, outputs);
  events(&k->peer);
}

void kleis_peer_arm_again(struct kleis_peer *k, unsigned end, unsigned cancel) {
  k->again_end = end;
  k->again_cancel = cancel;
}

void kleis_peer_hold_uploads(struct kleis_peer *k, int hold) {
  k->peer.hold_upload = (unsigned)hold;
}

/* Answers every held upload write, in order. */
void kleis_peer_release_uploads(struct kleis_peer *k) {
  unsigned i;
  for (i = 0; i < k->peer.held_uploads; ++i)
    release_upload_reply(&k->peer, i);
  k->peer.held_uploads = 0;
  k->peer.hold_upload = 0;
}

/* The SDK peer's pump, with faults chosen by record kind: a submit write is
 * inspected before the peer decides it, against the transaction it names. */
static void classify(struct kleis_peer *k, const uint8_t *m) {
  struct sophia_lf_record c;
  uint32_t fid = (uint32_t)get(m + 7, 4);
  if (m[4] != 118 || fid >= 256 || k->peer.files[fid] != F_SUBMIT ||
      sophia_lf_decode(k->peer.tx, k->peer.tx_size, &c))
    return;
  switch (c.header.kind) {
  case SOPHIA_LF_RESOURCE_END:
    ++k->end_submits;
    if (k->again_end) {
      --k->again_end;
      k->peer.submit_again = 1;
    }
    break;
  case SOPHIA_LF_RESOURCE_CANCEL:
    ++k->cancel_submits;
    if (k->again_cancel) {
      --k->again_cancel;
      k->peer.submit_again = 1;
    }
    break;
  case SOPHIA_LF_RESOURCE_BEGIN:
    ++k->begin_submits;
    break;
  case SOPHIA_LF_FRAME_DEMAND:
    ++k->demand_submits;
    break;
  default:
    break;
  }
}

void kleis_peer_pump(struct kleis_peer *k) {
  struct peer *p = &k->peer;
  for (;;) {
    ssize_t n = recv(p->fd, p->input + p->used, sizeof(p->input) - p->used,
                     MSG_DONTWAIT);
    if (n < 0) {
      assert(errno == EAGAIN || errno == EWOULDBLOCK);
      break;
    }
    if (!n)
      break;
    p->used += (size_t)n;
    while (p->used >= 4 && get(p->input, 4) <= p->used) {
      size_t bytes = (size_t)get(p->input, 4);
      classify(k, p->input);
      request(p, p->input);
      p->used -= bytes;
      memmove(p->input, p->input + bytes, p->used);
    }
  }
  events(p);
}

unsigned kleis_peer_end_submits(const struct kleis_peer *k) { return k->end_submits; }
unsigned kleis_peer_cancel_submits(const struct kleis_peer *k) { return k->cancel_submits; }
unsigned kleis_peer_begin_submits(const struct kleis_peer *k) { return k->begin_submits; }
unsigned kleis_peer_demand_submits(const struct kleis_peer *k) { return k->demand_submits; }
unsigned kleis_peer_upload_ends(const struct kleis_peer *k) { return k->peer.upload_ends; }
unsigned kleis_peer_held_uploads(const struct kleis_peer *k) { return k->peer.held_uploads; }
int kleis_peer_negotiated(const struct kleis_peer *k) { return (int)k->peer.negotiated; }
int kleis_peer_upload_open(const struct kleis_peer *k) { return k->peer.upload_fid != 0; }
/* Every event the peer journaled has been acknowledged by the provider. */
int kleis_peer_caught_up(const struct kleis_peer *k) {
  return k->peer.acked == k->peer.sequence;
}
