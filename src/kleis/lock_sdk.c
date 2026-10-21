#include "lock_sdk.h"
#include "lock_auth.h"
#include "sophia_lock_client.h"
#include "sophia_lock_image.h"
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define KLEIS_MSIZE 65536u
#define KLEIS_REQUESTS 16u
#define KLEIS_FIDS 32u
#define KLEIS_FORMATS_BYTES 4096u

struct kleis_lock {
  struct sophia_9p_client wire;
  struct sophia_lc_client client;
  struct sophia_lc_image image;
  void *storage;
  void *formats;
  int relay_fd;
  int endpoint_dir_fd;
  int source_fd;
  struct sophia_ic_metadata source;
  uint64_t source_view;
};

static uint64_t kleis_now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts))
    return 0;
  return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

kleis_lock *kleis_lock_open(int fd, const char *endpoint_dir,
                            uint16_t chord_count, const uint32_t *keysyms,
                            const uint16_t *modifiers) {
  struct sophia_lf_negotiate offer;
  struct sophia_lc_image_config image_config;
  size_t bytes = sophia_9p_storage_bytes(KLEIS_MSIZE, KLEIS_REQUESTS);
  kleis_lock *lock;
  uint16_t i;
  uint32_t root;
  int authenticated;
  if (chord_count > SOPHIA_LF_MAX_CHORDS || !endpoint_dir)
    return NULL;
  lock = calloc(1, sizeof(*lock));
  if (!lock)
    return NULL;
  lock->relay_fd = -1;
  lock->endpoint_dir_fd = -1;
  lock->source_fd = -1;
  lock->storage = malloc(bytes);
  lock->formats = malloc(KLEIS_FORMATS_BYTES);
  memset(&offer, 0, sizeof(offer));
  /* Lock r2 with the sealed grant is required; there is no byte
   * upload fallback in this client. */
  offer.minimum_revision = SOPHIA_LF_REVISION_IMAGE_CHANNEL;
  offer.maximum_revision = SOPHIA_LF_REVISION_IMAGE_CHANNEL;
  offer.capabilities = SOPHIA_LF_CAP_PRESENT | SOPHIA_LF_CAP_IMAGE_SEALED;
  if (chord_count)
    offer.capabilities |= SOPHIA_LF_CAP_CHORDS;
  offer.chord_count = chord_count;
  for (i = 0; i < chord_count; ++i) {
    offer.chords[i].keysym = keysyms[i];
    offer.chords[i].modifiers = modifiers[i];
  }
  if (!lock->storage || !lock->formats ||
      sophia_9p_init(&lock->wire, fd, KLEIS_MSIZE, KLEIS_REQUESTS, KLEIS_FIDS,
                     lock->storage, bytes)) {
    kleis_lock_free(lock);
    return NULL;
  }
  authenticated = kleis_lock_authenticate(&lock->wire, &lock->relay_fd, &root);
  if (authenticated < 0 ||
      (authenticated ? sophia_lc_init_attached(&lock->client, &lock->wire, root, &offer)
                     : sophia_lc_init(&lock->client, &lock->wire, &offer))) {
    kleis_lock_free(lock);
    return NULL;
  }
  lock->endpoint_dir_fd =
      open(endpoint_dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  memset(&image_config, 0, sizeof(image_config));
  /* The adapter derives image bounds from the negotiated lock Limits. */
  image_config.producer.transfer_timeout_ms = 2000;
  image_config.producer.startup_deadline_ms = kleis_now_ms() + 5000;
  image_config.endpoint_dir = lock->endpoint_dir_fd;
  image_config.formats = lock->formats;
  image_config.formats_capacity = KLEIS_FORMATS_BYTES;
  if (lock->endpoint_dir_fd < 0 ||
      sophia_lc_image_init(&lock->image, &image_config) ||
      sophia_lc_image_attach(&lock->client, &lock->image)) {
    kleis_lock_free(lock);
    return NULL;
  }
  return lock;
}
void kleis_lock_free(kleis_lock *lock) {
  if (!lock)
    return;
  if (lock->image.started) {
    struct sophia_ip_offer_info info;
    unsigned cursor = 0;
    sophia_ip_journal_lost(&lock->image.producer);
    while (sophia_ip_offer_next(&lock->image.producer, &cursor, &info))
      (void)sophia_ip_forget(&lock->image.producer, info.offer);
  }
  if (lock->source_fd >= 0)
    close(lock->source_fd);
  if (lock->endpoint_dir_fd >= 0)
    close(lock->endpoint_dir_fd);
  if (lock->relay_fd >= 0)
    close(lock->relay_fd);
  free(lock->formats);
  free(lock->storage);
  free(lock);
}
int kleis_lock_service(kleis_lock *lock) {
  return sophia_lc_service(&lock->client, 1u << 20);
}
short kleis_lock_poll_events(const kleis_lock *lock) {
  return (short)(POLLIN | (sophia_9p_wants_write(&lock->wire) ? POLLOUT : 0));
}
int kleis_lock_state(const kleis_lock *lock) {
  return (int)sophia_lc_state(&lock->client);
}
uint32_t kleis_lock_remote_error(const kleis_lock *lock) {
  return sophia_lc_remote_error(&lock->client);
}

int kleis_lock_event(kleis_lock *lock, kleis_lock_event_t *out) {
  const struct sophia_lf_record *r;
  if (sophia_lc_event(&lock->client, &r))
    return 0;
  memset(out, 0, sizeof(*out));
  out->kind = r->header.kind;
  out->sequence = r->header.sequence;
  switch (r->header.kind) {
  case SOPHIA_LF_OBJECT_PUBLISHED:
    out->object_generation = r->value.published.object_generation;
    break;
  case SOPHIA_LF_RESOURCE_STATUS:
    out->transaction = r->value.resource_status.transaction;
    out->resource_id = r->value.resource_status.resource.id;
    out->resource_generation = r->value.resource_status.resource.generation;
    out->status = r->value.resource_status.status;
    out->reason = r->value.resource_status.reason;
    break;
  case SOPHIA_LF_RESOURCE_RELEASED:
    out->transaction = r->value.resource_released.transaction;
    out->resource_id = r->value.resource_released.resource.id;
    out->resource_generation = r->value.resource_released.resource.generation;
    out->reason = r->value.resource_released.reason;
    break;
  case SOPHIA_LF_CANDIDATE_OUTCOME:
    out->transaction = r->value.candidate_outcome.transaction;
    out->lock_epoch = r->value.candidate_outcome.lock_epoch;
    out->output = r->value.candidate_outcome.output;
    out->allocation = r->value.candidate_outcome.allocation;
    out->candidate_generation = r->value.candidate_outcome.candidate_generation;
    out->status = r->value.candidate_outcome.status;
    out->reason = r->value.candidate_outcome.reason;
    break;
  case SOPHIA_LF_FRAME_PERMIT:
    out->lock_epoch = r->value.frame_permit.lock_epoch;
    out->allocation = r->value.frame_permit.allocation;
    out->allocation_generation = r->value.frame_permit.allocation_generation;
    out->demand = r->value.frame_permit.demand;
    out->pacing_permit = r->value.frame_permit.pacing_permit;
    out->expires_after_ms = r->value.frame_permit.expires_after_ms;
    break;
  case SOPHIA_LF_ENTRY:
    out->lock_epoch = r->value.entry.lock_epoch;
    out->entry = r->value.entry.entry;
    out->empty_after = r->value.entry.empty_after;
    break;
  case SOPHIA_LF_CHORD:
    out->lock_epoch = r->value.chord.lock_epoch;
    out->chord = r->value.chord.chord;
    break;
  default:
    break;
  }
  return 1;
}
int kleis_lock_consume(kleis_lock *lock) {
  return sophia_lc_event_consume(&lock->client);
}

int kleis_lock_object(const kleis_lock *lock, uint64_t *generation,
                      uint16_t *phase, uint64_t *lock_epoch,
                      uint16_t *allocation_count) {
  const struct sophia_lf_lock *l = sophia_lc_lock(&lock->client, generation);
  if (!l)
    return 0;
  *phase = l->phase;
  *lock_epoch = l->lock_epoch;
  *allocation_count = l->allocation_count;
  return 1;
}
int kleis_lock_allocation(const kleis_lock *lock, uint16_t index,
                          kleis_lock_allocation_t *out) {
  const struct sophia_lf_lock *l = sophia_lc_lock(&lock->client, NULL);
  const struct sophia_lf_allocation *a;
  if (!l || index >= l->allocation_count)
    return 0;
  a = &l->allocations[index];
  out->output = a->output;
  out->output_generation = a->output_generation;
  out->allocation = a->allocation;
  out->allocation_generation = a->allocation_generation;
  out->pixel_width = a->pixel_width;
  out->pixel_height = a->pixel_height;
  return 1;
}
int kleis_lock_limits(const kleis_lock *lock, uint16_t *upload_slots,
                      uint64_t *max_resource_bytes) {
  const struct sophia_lf_limits *l = sophia_lc_limits(&lock->client);
  if (!l)
    return 0;
  *upload_slots = l->upload_slots;
  *max_resource_bytes = l->max_resource_bytes;
  return 1;
}

int kleis_lock_demand(kleis_lock *lock, uint64_t transaction,
                      uint64_t lock_epoch, uint64_t allocation,
                      uint64_t allocation_generation, uint64_t demand) {
  struct sophia_lf_record r;
  memset(&r, 0, sizeof(r));
  r.header.kind = SOPHIA_LF_FRAME_DEMAND;
  r.value.frame_demand.transaction = transaction;
  r.value.frame_demand.lock_epoch = lock_epoch;
  r.value.frame_demand.allocation = allocation;
  r.value.frame_demand.allocation_generation = allocation_generation;
  r.value.frame_demand.demand = demand;
  return sophia_lc_submit(&lock->client, &r);
}
int kleis_lock_candidate(kleis_lock *lock, uint64_t transaction,
                         uint64_t lock_epoch, uint64_t output,
                         uint64_t output_generation, uint64_t allocation,
                         uint64_t allocation_generation,
                         uint64_t candidate_generation, uint64_t pacing_permit,
                         uint64_t resource_id, uint64_t resource_generation) {
  struct sophia_lf_record r;
  memset(&r, 0, sizeof(r));
  r.header.kind = SOPHIA_LF_CANDIDATE;
  r.value.candidate.transaction = transaction;
  r.value.candidate.lock_epoch = lock_epoch;
  r.value.candidate.output = output;
  r.value.candidate.output_generation = output_generation;
  r.value.candidate.allocation = allocation;
  r.value.candidate.allocation_generation = allocation_generation;
  r.value.candidate.candidate_generation = candidate_generation;
  r.value.candidate.pacing_permit = pacing_permit;
  r.value.candidate.resource.id = resource_id;
  r.value.candidate.resource.generation = resource_generation;
  return sophia_lc_submit(&lock->client, &r);
}
int kleis_lock_retire(kleis_lock *lock, uint64_t transaction,
                      uint64_t resource_id, uint64_t resource_generation) {
  struct sophia_lf_record r;
  memset(&r, 0, sizeof(r));
  r.header.kind = SOPHIA_LF_RESOURCE_RETIRE;
  r.value.resource_step.transaction = transaction;
  r.value.resource_step.resource.id = resource_id;
  r.value.resource_step.resource.generation = resource_generation;
  return sophia_lc_submit(&lock->client, &r);
}
int kleis_lock_submission(const kleis_lock *lock, uint32_t *stage,
                          uint32_t *submit_error) {
  uint64_t id;
  enum sophia_lc_submission s;
  int r = sophia_lc_submission(&lock->client, &id, &s, submit_error);
  *stage = (uint32_t)s;
  return r;
}
int kleis_lock_submit_retry(kleis_lock *lock) {
  return sophia_lc_submit_retry(&lock->client);
}

int kleis_lock_image_channel(const kleis_lock *lock) {
  struct sophia_ip *p = sophia_lc_image_producer((struct sophia_lc_image *)&lock->image);
  if (!p)
    return 0;
  switch (sophia_ip_channel(p)) {
  case SOPHIA_IPC_READY:
    return 1;
  case SOPHIA_IPC_CLOSED:
    return 2;
  default:
    return 0;
  }
}
int kleis_lock_image_poll_fd(const kleis_lock *lock) {
  return sophia_lc_image_poll_fd(&lock->image);
}
short kleis_lock_image_poll_events(const kleis_lock *lock) {
  return sophia_lc_image_poll_events(&lock->image);
}
int64_t kleis_lock_image_timeout(const kleis_lock *lock, uint64_t now_ms) {
  return sophia_lc_image_timeout(&lock->image, now_ms);
}
int kleis_lock_image_dispatch(kleis_lock *lock, short revents, uint64_t now_ms) {
  int r = sophia_lc_image_dispatch(&lock->image, revents, now_ms);
  struct sophia_ip *p = sophia_lc_image_producer(&lock->image);
  return r < 0 || (p && sophia_ip_path(p) == SOPHIA_IPP_ERROR)
             ? SOPHIA_IPR_ARGUMENT : 0;
}
int kleis_lock_image_begin(kleis_lock *lock, uint64_t now_ms,
                           uint64_t resource_id, uint64_t resource_generation,
                           uint64_t output, uint64_t allocation, uint64_t view,
                           const void *pixels, uint32_t width_px,
                           uint32_t height_px, uint64_t *offer) {
  const struct sophia_lf_lock *l = sophia_lc_lock(&lock->client, NULL);
  struct sophia_ic_metadata m;
  void *map;
  size_t bytes;
  int fd, r;
  if (!l)
    return SOPHIA_IPR_REFUSED;
  memset(&m, 0, sizeof(m));
  m.resource_id = resource_id;
  m.resource_generation = resource_generation;
  /* The lock server admits images under the lock object's epoch and
   * topology, never the connection epoch. */
  m.admission_epoch = l->lock_epoch;
  m.output = output;
  m.allocation = allocation;
  m.topology_generation = l->topology_generation;
  m.source_kind = SOPHIA_IC_SOURCE_SEALED;
  m.source_format = SOPHIA_IC_SEALED_BGRA8_PREMULTIPLIED;
  m.width = width_px;
  m.height = height_px;
  m.stride = width_px * 4u;
  m.plane_count = m.descriptor_count = 1;
  m.logical_bytes = (uint64_t)width_px * height_px * 4u;
  /* A retry keeps the same sealed frame. A changed grant or resource makes
   * that unsent source obsolete; it has never crossed the channel. */
  if (lock->source_fd >= 0 &&
      (lock->source_view != view || memcmp(&lock->source, &m, sizeof(m)))) {
    close(lock->source_fd);
    lock->source_fd = -1;
  }
  if (lock->source_fd < 0) {
    r = sophia_ip_isb_create(width_px, height_px, &fd, &map, &bytes);
    if (r)
      return r;
    memcpy(map, pixels, bytes);
    r = sophia_ip_isb_finish(fd, map, bytes);
    if (r) {
      close(fd);
      return r;
    }
    lock->source_fd = fd;
    lock->source = m;
    lock->source_view = view;
  }
  fd = lock->source_fd;
  r = sophia_lc_image_begin(&lock->image, &m, fd, now_ms, offer);
  if (!r) {
    lock->source_fd = -1;
  } else if (r != SOPHIA_IPR_BUSY && r != SOPHIA_IPR_AGAIN) {
    close(fd);
    lock->source_fd = -1;
  }
  if (r == SOPHIA_IPR_AGAIN)
    r = SOPHIA_IPR_BUSY;
  return r;
}
int kleis_lock_image_offer(const kleis_lock *lock, uint64_t offer,
                           uint32_t *state, uint32_t *status,
                           uint32_t *disposition) {
  struct sophia_ip *p = sophia_lc_image_producer((struct sophia_lc_image *)&lock->image);
  struct sophia_ip_offer_info info;
  int r;
  if (!p)
    return SOPHIA_IPR_REFUSED;
  r = sophia_ip_offer(p, offer, &info);
  if (r)
    return r;
  if (info.deadline_passed && info.state != SOPHIA_IPO_SETTLED)
    return SOPHIA_IPR_REFUSED;
  *state = (uint32_t)info.state;
  *status = (uint32_t)info.status;
  *disposition = info.disposition;
  return 0;
}
int kleis_lock_image_forget(kleis_lock *lock, uint64_t offer) {
  struct sophia_ip *p = sophia_lc_image_producer(&lock->image);
  if (!p)
    return SOPHIA_IPR_REFUSED;
  return sophia_ip_forget(p, offer);
}
int kleis_lock_image_cancel(kleis_lock *lock, uint64_t offer, uint64_t now_ms) {
  return sophia_lc_image_cancel(&lock->image, offer, now_ms);
}
