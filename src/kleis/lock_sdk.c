#include "lock_sdk.h"
#include "sophia_lock_client.h"
#include <poll.h>
#include <stdlib.h>
#include <string.h>

#define KLEIS_MSIZE 65536u
#define KLEIS_REQUESTS 16u
#define KLEIS_FIDS 32u

struct kleis_lock {
  struct sophia_9p_client wire;
  struct sophia_lc_client client;
  void *storage;
};

kleis_lock *kleis_lock_open(int fd, uint16_t chord_count,
                            const uint32_t *keysyms, const uint16_t *modifiers) {
  struct sophia_lf_negotiate offer;
  size_t bytes = sophia_9p_storage_bytes(KLEIS_MSIZE, KLEIS_REQUESTS);
  kleis_lock *lock;
  uint16_t i;
  if (chord_count > SOPHIA_LF_MAX_CHORDS)
    return NULL;
  lock = calloc(1, sizeof(*lock));
  if (!lock)
    return NULL;
  lock->storage = malloc(bytes);
  memset(&offer, 0, sizeof(offer));
  offer.minimum_revision = offer.maximum_revision = SOPHIA_LF_REVISION;
  offer.capabilities = SOPHIA_LF_CAP_PRESENT;
  if (chord_count)
    offer.capabilities |= SOPHIA_LF_CAP_CHORDS;
  offer.chord_count = chord_count;
  for (i = 0; i < chord_count; ++i) {
    offer.chords[i].keysym = keysyms[i];
    offer.chords[i].modifiers = modifiers[i];
  }
  if (!lock->storage ||
      sophia_9p_init(&lock->wire, fd, KLEIS_MSIZE, KLEIS_REQUESTS, KLEIS_FIDS,
                     lock->storage, bytes) ||
      sophia_lc_init(&lock->client, &lock->wire, &offer) ||
      sophia_lc_upload_window(&lock->client, 8)) {
    kleis_lock_free(lock);
    return NULL;
  }
  return lock;
}
void kleis_lock_free(kleis_lock *lock) {
  if (!lock)
    return;
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

int kleis_lock_upload_begin(kleis_lock *lock, uint64_t transaction,
                            uint64_t resource_id, uint64_t resource_generation,
                            uint32_t width_px, uint32_t height_px,
                            uint16_t slot) {
  struct sophia_lf_resource_begin b;
  memset(&b, 0, sizeof(b));
  b.transaction = transaction;
  b.resource.id = resource_id;
  b.resource.generation = resource_generation;
  b.width_px = width_px;
  b.height_px = height_px;
  b.slot = slot;
  return sophia_lc_upload_begin(&lock->client, &b);
}
int kleis_lock_upload_chunk(kleis_lock *lock, const void *bytes, size_t n) {
  return sophia_lc_upload_chunk(&lock->client, bytes, n);
}
int kleis_lock_upload_ready(const kleis_lock *lock) {
  return sophia_lc_upload_ready(&lock->client);
}
int kleis_lock_upload_pending(const kleis_lock *lock) {
  return sophia_lc_upload_pending(&lock->client);
}
int kleis_lock_upload_end(kleis_lock *lock) {
  return sophia_lc_upload_end(&lock->client);
}
int kleis_lock_upload_cancel(kleis_lock *lock) {
  return sophia_lc_upload_cancel(&lock->client);
}
