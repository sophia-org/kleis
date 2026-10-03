#ifndef KLEIS_LOCK_SDK_H
#define KLEIS_LOCK_SDK_H
/* A flat face of the C desktop SDK's lock client for Nim: it owns the
 * caller-allocated SDK objects and copies records out of their unions. */
#include <stddef.h>
#include <stdint.h>

typedef struct kleis_lock kleis_lock;

/* The parts of one event kleis reads. Fields a kind does not carry are 0. */
typedef struct {
  uint16_t kind;
  uint64_t sequence;
  uint64_t lock_epoch;
  uint64_t transaction;
  uint64_t allocation, allocation_generation;
  uint64_t demand, pacing_permit;
  uint32_t expires_after_ms;
  uint64_t resource_id, resource_generation;
  uint16_t status, reason;
  uint64_t candidate_generation, output;
  uint16_t entry, empty_after;
  uint16_t chord;
  uint64_t object_generation;
} kleis_lock_event_t;

typedef struct {
  uint64_t output, output_generation, allocation, allocation_generation;
  uint32_t pixel_width, pixel_height;
} kleis_lock_allocation_t;

/* Takes a connected, nonblocking fd. NULL on failure; fd stays the caller's. */
kleis_lock *kleis_lock_open(int fd, uint16_t chord_keysym_count,
                            const uint32_t *keysyms, const uint16_t *modifiers);
void kleis_lock_free(kleis_lock *);
/* 0 or a terminal SDK result. */
int kleis_lock_service(kleis_lock *);
short kleis_lock_poll_events(const kleis_lock *);
/* sophia_lc_state: 0 bootstrap, 1 ready, 2 refused, 3 stale, 4 failed. */
int kleis_lock_state(const kleis_lock *);
uint32_t kleis_lock_remote_error(const kleis_lock *);
/* 1 with an event copied out, 0 with none. */
int kleis_lock_event(kleis_lock *, kleis_lock_event_t *);
int kleis_lock_consume(kleis_lock *);
/* The lock object as of the last presented ObjectPublished; 0 before one. */
int kleis_lock_object(const kleis_lock *, uint64_t *generation, uint16_t *phase,
                      uint64_t *lock_epoch, uint16_t *allocation_count);
int kleis_lock_allocation(const kleis_lock *, uint16_t index,
                          kleis_lock_allocation_t *);
/* Limits: upload slots and the per-resource byte ceiling. */
int kleis_lock_limits(const kleis_lock *, uint16_t *upload_slots,
                      uint64_t *max_resource_bytes);
/* Submissions: 0, BUSY (2) or an error. */
int kleis_lock_demand(kleis_lock *, uint64_t transaction, uint64_t lock_epoch,
                      uint64_t allocation, uint64_t allocation_generation,
                      uint64_t demand);
int kleis_lock_candidate(kleis_lock *, uint64_t transaction,
                         uint64_t lock_epoch, uint64_t output,
                         uint64_t output_generation, uint64_t allocation,
                         uint64_t allocation_generation,
                         uint64_t candidate_generation, uint64_t pacing_permit,
                         uint64_t resource_id, uint64_t resource_generation);
int kleis_lock_retire(kleis_lock *, uint64_t transaction, uint64_t resource_id,
                      uint64_t resource_generation);
/* Stage of the latest submission (sophia_lc_submission) and its errno. */
int kleis_lock_submission(const kleis_lock *, uint32_t *stage,
                          uint32_t *submit_error);
int kleis_lock_submit_retry(kleis_lock *);
int kleis_lock_upload_begin(kleis_lock *, uint64_t transaction,
                            uint64_t resource_id, uint64_t resource_generation,
                            uint32_t width_px, uint32_t height_px,
                            uint16_t slot);
int kleis_lock_upload_chunk(kleis_lock *, const void *, size_t);
int kleis_lock_upload_ready(const kleis_lock *);
int kleis_lock_upload_pending(const kleis_lock *);
int kleis_lock_upload_end(kleis_lock *);
int kleis_lock_upload_cancel(kleis_lock *);
#endif
