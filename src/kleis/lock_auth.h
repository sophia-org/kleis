#ifndef KLEIS_LOCK_AUTH_H
#define KLEIS_LOCK_AUTH_H
#include "sophia_9p_client.h"

/* Bounded startup only. 0 means no provisioned channel, 1 an authenticated
 * root, -1 failure. Once adopted, relay_fd belongs to the caller even on
 * failure and must remain open for the lock connection's lifetime. */
int kleis_lock_authenticate(struct sophia_9p_client *role, int *relay_fd,
                            uint32_t *root);
#endif
