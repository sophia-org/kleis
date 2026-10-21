/* Supplied Session decisions over 9P and real sealed FD transfer; no native proof. */
#define _GNU_SOURCE
#include <unistd.h>
#undef F_ULOCK
#undef F_LOCK
#undef F_TLOCK
#undef F_TEST
#define main kleis_sdk_image_test_main
#include "../../vendor/sophia-desktop-sdk/source/src/tests/lock_image_test.c"
#undef main
struct kleis_peer {
  struct peer peer;
  struct set discovery;
  struct image_rig channel;
  unsigned again_begin, again_cancel, begin_submits, cancel_submits;
  unsigned candidate_submits, candidates_by_output[2], prefix_events;
  unsigned demand_submits, admitted, cancelled, sources, released, hold;
  uint64_t lock_epoch;
  int ready, accepted_status;
};
struct kleis_peer *kleis_peer_new(int fd, const char *dir) {
  struct kleis_peer *k = calloc(1, sizeof(*k));
  struct sophia_lf_record l;
  struct sockaddr_un a;
  assert(k);
  k->peer.fd = fd;
  k->peer.api = "sophia-lock-files version=1 epoch=7\n";
  k->peer.revision = 2;
  make_set(&k->discovery, SOPHIA_IC_KIND_BIT_SEALED);
  k->peer.image_data[0] = (const uint8_t *)k->discovery.text;
  k->peer.image_data[1] = k->discovery.limits;
  k->peer.image_data[2] = k->discovery.formats;
  k->peer.image_bytes[0] = k->discovery.text_bytes;
  k->peer.image_bytes[1] = k->discovery.limits_bytes;
  k->peer.image_bytes[2] = k->discovery.formats_bytes;
  memset(&l, 0, sizeof(l));
  l.header.kind = SOPHIA_LF_LIMITS;
  l.header.epoch = EPOCH;
  l.value.limits = limits;
  assert(!sophia_lf_encode(k->peer.limits, sizeof(k->peer.limits), &l, &k->peer.limits_size));
  k->channel.owner = -1;
  k->channel.listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
  assert(snprintf(a.sun_path, sizeof(a.sun_path), "%s/image.sock", dir) < (int)sizeof(a.sun_path));
  assert(!bind(k->channel.listener, (struct sockaddr *)&a, sizeof(a)));
  assert(!listen(k->channel.listener, 1));
  publish(&k->peer, SOPHIA_LF_UNLOCKED, 0, 0);
  return k;
}
void kleis_peer_free(struct kleis_peer *k) {
  if (k->channel.owner >= 0) close(k->channel.owner);
  close(k->channel.listener); free(k);
}
void kleis_peer_lock(struct kleis_peer *k, uint64_t epoch, uint16_t outputs) {
  k->lock_epoch = epoch;
  publish(&k->peer, SOPHIA_LF_LOCKED, epoch, outputs); events(&k->peer);
}
void kleis_peer_arm_again(struct kleis_peer *k, unsigned begin, unsigned cancel) {
  k->again_begin = begin; k->again_cancel = cancel;
}
void kleis_peer_hold_uploads(struct kleis_peer *k, int hold) { k->hold = (unsigned)hold; }
static void release_source(struct kleis_peer *k, int cancelled) {
  const struct sophia_ic_metadata *m = &k->peer.image_begin.value.image;
  struct sophia_ic_record r;
  if (!k->accepted_status)
    peer_status(&k->peer, m->offer, m->resource_id, cancelled ? 4 : 2, 0);
  memset(&r, 0, sizeof(r)); r.header.kind = SOPHIA_IC_SOURCE_RELEASED;
  r.value.released.offer = m->offer;
  r.value.released.resource_id = m->resource_id;
  r.value.released.resource_generation = m->resource_generation;
  r.value.released.disposition = cancelled ? SOPHIA_IC_CANCELLED : SOPHIA_IC_RETAINED;
  image_record(&k->peer, &r); ++k->released;
}
void kleis_peer_release_uploads(struct kleis_peer *k) {
  k->hold = 0;
  if (k->sources > k->released) release_source(k, 0);
  events(&k->peer);
}
void kleis_peer_prefix_events(struct kleis_peer *k) { k->prefix_events = 1; }
static void classify(struct kleis_peer *k, const uint8_t *m) {
  uint32_t fid = (uint32_t)get(m + 7, 4);
  uint16_t kind;
  if (m[4] != 118 || fid >= 256 || k->peer.files[fid] != F_SUBMIT) return;
  kind = (uint16_t)get(k->peer.tx + 6, 2);
  if (k->prefix_events && (kind == SOPHIA_LF_FRAME_DEMAND || kind == SOPHIA_LF_CANDIDATE)) {
    struct sophia_lf_record r;
    memset(&r, 0, sizeof r);
    r.value.resource_released.transaction = 999;
    r.value.resource_released.resource.id = 999;
    r.value.resource_released.resource.generation = 1;
    event(&k->peer, SOPHIA_LF_RESOURCE_RELEASED, &r);
  }
  if (kind == SOPHIA_IC_IMAGE_BEGIN) {
    ++k->begin_submits;
    if (k->again_begin) { --k->again_begin; k->peer.submit_again = 1; }
  } else if (kind == SOPHIA_LF_RESOURCE_CANCEL) {
    ++k->cancel_submits;
    if (k->again_cancel) { --k->again_cancel; k->peer.submit_again = 1; }
  } else if (kind == SOPHIA_LF_FRAME_DEMAND) {
    assert(k->released && !k->hold); ++k->demand_submits;
  } else if (kind == SOPHIA_LF_CANDIDATE) {
    struct sophia_lf_record candidate;
    assert(!sophia_lf_decode(k->peer.tx, k->peer.tx_size, &candidate));
    assert(candidate.value.candidate.output >= 1 && candidate.value.candidate.output <= 2);
    ++k->candidates_by_output[candidate.value.candidate.output - 1];
    ++k->candidate_submits;
  } else assert(kind != SOPHIA_LF_RESOURCE_BEGIN && kind != SOPHIA_LF_RESOURCE_END);
}
static void image_progress(struct kleis_peer *k) {
  struct peer *p = &k->peer;
  struct sophia_ic_record r;
  uint8_t packet[201]; int fd; ssize_t n;
  if (p->image_begins > k->admitted) {
    k->accepted_status = 0;
    const struct sophia_ic_metadata *m = &p->image_begin.value.image;
    assert(m->admission_epoch == k->lock_epoch && m->admission_epoch != EPOCH);
    assert(m->width == 4 && m->height == 2 && m->stride == 16 && m->logical_bytes == 32);
    assert(m->output >= 1 && m->output <= 2 && m->allocation == 40 + m->output && m->topology_generation == 9);
    r = p->image_begin; r.header.kind = SOPHIA_IC_IMAGE_ADMITTED;
    image_record(p, &r); ++k->admitted;
  }
  if (k->channel.owner < 0) {
    k->channel.owner = accept4(k->channel.listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (k->channel.owner < 0) { assert(errno == EAGAIN || errno == EWOULDBLOCK); return; }
  }
  n = owner_receive(&k->channel, packet, sizeof(packet), &fd);
  if (n > 0) {
    if (!k->ready) {
      assert(n == 40 && fd == -1 && get(packet + 6, 2) == SOPHIA_IC_HELLO);
      peer_channel(p, SOPHIA_IC_CHANNEL_READY, SOPHIA_IC_KIND_BIT_SEALED); k->ready = 1;
    } else {
      struct stat st; uint8_t pixels[32]; unsigned i;
      assert(n == 200 && fd >= 0 && get(packet + 6, 2) == SOPHIA_IC_SOURCE);
      assert((fcntl(fd, F_GET_SEALS) & SEALS) == SEALS);
      assert(!fstat(fd, &st) && st.st_size == 32 && pread(fd, pixels, 32, 0) == 32);
      for (i = 0; i < 32; i += 4)
        assert(pixels[i] <= pixels[i+3] && pixels[i+1] <= pixels[i+3] && pixels[i+2] <= pixels[i+3]);
      close(fd); ++k->sources;
      if (!k->hold) release_source(k, 0);
      else if (k->hold == 2) {
        peer_status(p, p->image_begin.value.image.offer,
                    p->image_begin.value.image.resource_id, 2, 0);
        k->accepted_status = 1;
      }
    }
  } else if (n < 0) assert(errno == EAGAIN || errno == EWOULDBLOCK);
  if (p->image_cancels > k->cancelled) { release_source(k, 1); ++k->cancelled; }
}
void kleis_peer_pump(struct kleis_peer *k) {
  struct peer *p = &k->peer;
  for (;;) {
    ssize_t n = recv(p->fd, p->input + p->used, sizeof(p->input) - p->used, MSG_DONTWAIT);
    if (n < 0) { assert(errno == EAGAIN || errno == EWOULDBLOCK); break; }
    if (!n) break;
    p->used += (size_t)n;
    while (p->used >= 4 && get(p->input, 4) <= p->used) {
      size_t bytes = (size_t)get(p->input, 4);
      classify(k, p->input); request(p, p->input);
      p->used -= bytes; memmove(p->input, p->input + bytes, p->used);
    }
  }
  image_progress(k); events(p);
}
unsigned kleis_peer_cancel_submits(const struct kleis_peer *k) { return k->cancel_submits; }
unsigned kleis_peer_begin_submits(const struct kleis_peer *k) { return k->begin_submits; }
unsigned kleis_peer_demand_submits(const struct kleis_peer *k) { return k->demand_submits; }
unsigned kleis_peer_held_uploads(const struct kleis_peer *k) { return k->sources - k->released; }
int kleis_peer_negotiated(const struct kleis_peer *k) { return (int)k->peer.negotiated; }
int kleis_peer_upload_open(const struct kleis_peer *k) { return k->admitted > k->released; }
int kleis_peer_caught_up(const struct kleis_peer *k) { return k->peer.acked == k->peer.sequence; }

unsigned kleis_peer_candidate_submits(const struct kleis_peer *k) { return k->candidate_submits; }

unsigned kleis_peer_output_candidates(const struct kleis_peer *k, unsigned output) { assert(output < 2); return k->candidates_by_output[output]; }
