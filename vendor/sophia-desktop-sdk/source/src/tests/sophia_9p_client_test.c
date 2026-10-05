#include "../sophia_9p_client.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct fixture {
    int fd[2];
    struct sophia_9p_client c;
    uint8_t *memory;
};
static void put(uint8_t *p, uint64_t v, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}
static unsigned get16(const uint8_t *p) { return p[0] + 256u * p[1]; }
static unsigned get32(const uint8_t *p) { return get16(p) + 65536u * get16(p + 2); }
static uint16_t request(struct fixture *f, unsigned type)
{
    uint8_t b[65536];
    size_t n, at = 0;
    ssize_t r;
    {
        int status = sophia_9p_service(&f->c, 65536);
        if (status)
            fprintf(stderr, "service before request type=%u: %d errno=%d fd=%d\n", type, status,
                    errno, f->c.fd);
        assert(!status);
    }
    while (at < 4) {
        r = recv(f->fd[1], b + at, 4 - at, MSG_DONTWAIT);
        assert(r > 0);
        at += (size_t)r;
    }
    n = get32(b);
    assert(n <= sizeof(b));
    while (at < n) {
        r = recv(f->fd[1], b + at, n - at, MSG_DONTWAIT);
        assert(r > 0);
        at += (size_t)r;
    }
    assert(b[4] == type);
    return (uint16_t)get16(b + 5);
}
static void answer(struct fixture *f, unsigned type, uint16_t tag, const void *body, size_t n)
{
    uint8_t b[65536];
    size_t at = 0;
    ssize_t r;
    put(b, n + 7, 4);
    b[4] = (uint8_t)type;
    put(b + 5, tag, 2);
    if (n)
        memcpy(b + 7, body, n);
    while (at < n + 7) {
        r = send(f->fd[1], b + at, n + 7 - at, MSG_DONTWAIT);
        assert(r > 0);
        at += (size_t)r;
    }
}
static struct sophia_9p_reply take(struct fixture *f, unsigned type)
{
    struct sophia_9p_reply r;
    assert(!sophia_9p_service(&f->c, 65536));
    assert(!sophia_9p_peek(&f->c, &r));
    assert(r.type == type);
    assert(!sophia_9p_consume(&f->c, r.handle));
    return r;
}
static void init(struct fixture *f, unsigned requests, unsigned fids)
{
    struct sophia_9p_handle h;
    uint8_t b[14];
    size_t n = sophia_9p_storage_bytes(4096, (uint16_t)requests);
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, f->fd));
    f->memory = malloc(n);
    assert(f->memory);
    assert(
        !sophia_9p_init(&f->c, f->fd[0], 4096, (uint16_t)requests, (uint16_t)fids, f->memory, n));
    assert(!sophia_9p_version(&f->c, &h));
    assert(request(f, 100) == UINT16_MAX);
    put(b, 4096, 4);
    put(b + 4, 8, 2);
    memcpy(b + 6, "9P2000.L", 8);
    answer(f, 101, UINT16_MAX, b, 14);
    take(f, 101);
}
static void finish(struct fixture *f)
{
    close(f->fd[0]);
    close(f->fd[1]);
    free(f->memory);
}
static uint32_t attach(struct fixture *f)
{
    struct sophia_9p_handle h;
    uint32_t fid;
    uint8_t q[13] = {0x80};
    uint16_t tag;
    assert(!sophia_9p_attach(&f->c, "", "", &h, &fid));
    tag = request(f, 104);
    answer(f, 105, tag, q, sizeof(q));
    take(f, 105);
    return fid;
}
static void held_completions_and_tag_wrap(void)
{
    struct fixture f;
    struct sophia_9p_handle held, h;
    struct sophia_9p_reply r;
    uint8_t count[4] = {0};
    uint16_t retained, tag;
    unsigned i;
    init(&f, 2, 2);
    assert(!sophia_9p_write(&f.c, 0, 0, NULL, 0, &held));
    retained = request(&f, 118);
    answer(&f, 119, retained, count, 4);
    assert(!sophia_9p_service(&f.c, 65536));
    for (i = 0; i < 65536; i++) {
        assert(!sophia_9p_write(&f.c, 0, 0, NULL, 0, &h));
        tag = request(&f, 118);
        assert(tag != retained);
        answer(&f, 119, tag, count, 4);
        assert(!sophia_9p_service(&f.c, 65536));
        assert(!sophia_9p_peek(&f.c, &r));
        assert(r.handle.serial == held.serial);
        assert(sophia_9p_write(&f.c, 0, 0, NULL, 0, &h) == SOPHIA_9P_BUSY);
        /* Explicit handles can consume out of FIFO; the held oldest reply stays. */
        assert(!sophia_9p_consume(&f.c, h));
    }
    assert(!sophia_9p_consume(&f.c, held));
    assert(sophia_9p_consume(&f.c, held) == SOPHIA_9P_ARGUMENT);
    finish(&f);
}
static void flush_fids_and_capacity(void)
{
    struct fixture f;
    struct sophia_9p_handle h, fl;
    uint32_t fid;
    uint16_t tag, ft;
    uint8_t q[13] = {0x80};
    const char *name = "x";
    init(&f, 1, 1);
    assert(!sophia_9p_attach(&f.c, "", "", &h, &fid));
    tag = request(&f, 104);
    assert(f.c.fid_count == 1);
    assert(!sophia_9p_flush(&f.c, h, &fl));
    ft = request(&f, 108);
    answer(&f, 109, ft, NULL, 0);
    take(&f, 109);
    assert(!f.c.fid_count);
    fid = attach(&f);
    assert(f.c.fid_count == 1);
    assert(!sophia_9p_clunk(&f.c, fid, &h));
    assert(sophia_9p_flush(&f.c, h, &fl) == SOPHIA_9P_ARGUMENT);
    tag = request(&f, 120);
    answer(&f, 121, tag, NULL, 0);
    take(&f, 121);
    assert(!f.c.fid_count);
    /* A reply that beats Rflush preserves the attach's server-side effect. */
    assert(!sophia_9p_attach(&f.c, "", "", &h, &fid));
    tag = request(&f, 104);
    assert(!sophia_9p_flush(&f.c, h, &fl));
    ft = request(&f, 108);
    answer(&f, 105, tag, q, 13);
    take(&f, 105);
    assert(f.c.fid_count == 1);
    assert(sophia_9p_read(&f.c, fid, 0, 1, &h) == SOPHIA_9P_BUSY);
    answer(&f, 109, ft, NULL, 0);
    take(&f, 109);
    assert(f.c.fid_count == 1);
    finish(&f);
    init(&f, 1, 2);
    fid = attach(&f);
    assert(!sophia_9p_walk(&f.c, fid, &name, 1, &h, &fid));
    request(&f, 110);
    assert(f.c.fid_count == 2);
    assert(!sophia_9p_flush(&f.c, h, &fl));
    ft = request(&f, 108);
    answer(&f, 109, ft, NULL, 0);
    take(&f, 109);
    assert(f.c.fid_count == 1);
    finish(&f);
}
static void walk_shape_and_failures(void)
{
    unsigned bad;
    for (bad = 0; bad < 3; bad++) {
        struct fixture f;
        struct sophia_9p_handle h;
        uint32_t fid;
        uint16_t tag;
        const char *names[2] = {"one", "two"};
        uint8_t b[15] = {0};
        init(&f, 2, 2);
        fid = attach(&f);
        assert(!sophia_9p_walk(&f.c, fid, names, 2, &h, &fid));
        tag = request(&f, 110);
        if (bad == 0) {
            put(b, 65535, 2);
            answer(&f, 111, tag, b, 2);
        }
        if (bad == 1)
            answer(&f, 111, tag, b, 2);
        if (bad == 2) {
            put(b, 1, 2);
            b[2] = 0x80;
            answer(&f, 111, tag, b, 15);
        }
        if (bad < 2) {
            assert(sophia_9p_service(&f.c, 65536) == SOPHIA_9P_INVALID);
            assert(sophia_9p_read(&f.c, fid, 0, 1, &h) == SOPHIA_9P_INVALID);
        } else {
            take(&f, 111);
            assert(f.c.fid_count == 1);
        }
        finish(&f);
    }
}
static void preflight_and_errors(void)
{
    struct fixture f;
    struct sophia_9p_handle h;
    uint32_t fid;
    uint16_t tag;
    uint8_t error[4] = {13};
    init(&f, 1, 1);
    /* No read from this non-dereferenceable pointer is permitted before size refusal. */
    assert(sophia_9p_write(&f.c, 0, 0, (void *)(uintptr_t)1, 64u * 1024u * 1024u, &h) ==
           SOPHIA_9P_ARGUMENT);
    assert(!sophia_9p_attach(&f.c, "", "", &h, &fid));
    tag = request(&f, 104);
    answer(&f, 7, tag, error, 4);
    assert(take(&f, 7).error == 13);
    assert(!f.c.fid_count);
    assert(!sophia_9p_read(&f.c, 0, 0, 0, &h));
    tag = request(&f, 116);
    memset(error, 0, sizeof(error));
    answer(&f, 117, tag, error, 4);
    assert(!sophia_9p_service(&f.c, 65536));
    assert(sophia_9p_read(&f.c, 0, 0, 0, &h) == SOPHIA_9P_BUSY);
    take(&f, 117);
    finish(&f);
}
static void outstanding_read_fragmented_reply_and_eof(void)
{
    struct fixture f;
    struct sophia_9p_handle rd, wr;
    struct sophia_9p_reply reply;
    uint8_t b[11] = {11, 0, 0, 0, 119, 0, 0, 1, 0, 0, 0};
    uint16_t rt, wt;
    size_t i;
    init(&f, 2, 2);
    assert(!sophia_9p_read(&f.c, 0, 0, 100, &rd));
    rt = request(&f, 116);
    assert(!sophia_9p_write(&f.c, 1, 0, "x", 1, &wr));
    wt = request(&f, 118);
    put(b + 5, wt, 2);
    for (i = 0; i < sizeof(b); i++) {
        assert(send(f.fd[1], b + i, 1, 0) == 1);
        assert(!sophia_9p_service(&f.c, 1));
        if (i + 1 < sizeof(b))
            assert(sophia_9p_peek(&f.c, &reply) == SOPHIA_9P_AGAIN);
    }
    assert(!sophia_9p_peek(&f.c, &reply));
    assert(reply.handle.serial == wr.serial);
    assert(!sophia_9p_consume(&f.c, wr));
    b[4] = 117;
    put(b + 5, rt, 2);
    put(b + 7, 0, 4);
    assert(send(f.fd[1], b, sizeof(b), 0) == (ssize_t)sizeof(b));
    assert(!shutdown(f.fd[1], SHUT_WR));
    assert(!sophia_9p_service(&f.c, 4096));
    assert(!sophia_9p_peek(&f.c, &reply));
    assert(reply.handle.serial == rd.serial);
    assert(!sophia_9p_consume(&f.c, rd));
    assert(sophia_9p_service(&f.c, 4096) == SOPHIA_9P_CLOSED);
    finish(&f);
}
static void reply_shape_poisoning(void)
{
    unsigned test;
    for (test = 0; test < 5; test++) {
        struct fixture f;
        struct sophia_9p_handle h;
        uint16_t tag;
        uint8_t b[5] = {0};
        init(&f, 1, 1);
        assert(!sophia_9p_write(&f.c, 0, 0, "x", 1, &h));
        tag = request(&f, 118);
        if (test == 0) {
            b[0] = 2;
            answer(&f, 119, tag, b, 4);
        }
        if (test == 1)
            answer(&f, 119, tag, b, 5);
        if (test == 2)
            answer(&f, 117, tag, b, 4);
        if (test == 3)
            answer(&f, 119, (uint16_t)(tag + 1), b, 4);
        if (test == 4) {
            answer(&f, 119, tag, b, 4);
            answer(&f, 119, tag, b, 4);
        }
        assert(sophia_9p_service(&f.c, 4096) == SOPHIA_9P_INVALID);
        assert(sophia_9p_peek(&f.c, &(struct sophia_9p_reply){0}) == SOPHIA_9P_INVALID);
        finish(&f);
    }
}
/* One Twrite of the largest payload, sent five bytes per service pass so that
 * one pass spans the header and the payload. Returns the bytes on the wire. */
static size_t sent_in_steps(struct fixture *f, int borrow, const uint8_t *data, size_t count,
                            uint8_t *wire, size_t room)
{
    struct sophia_9p_handle h;
    uint8_t ok[4] = {0};
    size_t at = 0, steps = 0;
    ssize_t r;
    if (borrow)
        assert(!sophia_9p_write_borrowed(&f->c, 1, 9, data, count, &h));
    else
        assert(!sophia_9p_write(&f->c, 1, 9, data, count, &h));
    while (at < 23 + count) {
        assert(!sophia_9p_service(&f->c, 5));
        r = recv(f->fd[1], wire + at, room - at, MSG_DONTWAIT);
        assert(r > 0 && r <= 5);
        at += (size_t)r;
        steps++;
    }
    assert(steps == (23 + count + 4) / 5);
    put(ok, count, 4);
    answer(f, 119, (uint16_t)get16(wire + 5), ok, 4);
    assert(take(f, 119).count == count);
    return at;
}
static void borrowed_write_sends_the_copied_bytes(void)
{
    static uint8_t data[4096 - 23], copied[4096], borrowed[4096];
    struct fixture f;
    struct sophia_9p_handle h;
    size_t i, n;
    for (i = 0; i < sizeof(data); i++)
        data[i] = (uint8_t)(i * 7 + 3);
    init(&f, 2, 2);
    n = sent_in_steps(&f, 0, data, sizeof(data), copied, sizeof(copied));
    assert(n == 4096 && sent_in_steps(&f, 1, data, sizeof(data), borrowed, sizeof(borrowed)) == n);
    /* Identical but for the tag. */
    assert(!memcmp(copied, borrowed, 5) && !memcmp(copied + 7, borrowed + 7, n - 7));
    assert(sophia_9p_write_borrowed(&f.c, 1, 0, data, sizeof(data) + 1, &h) ==
           SOPHIA_9P_ARGUMENT);
    assert(sophia_9p_write_borrowed(&f.c, 1, 0, NULL, 1, &h) == SOPHIA_9P_ARGUMENT);
    finish(&f);
}
/* Versioned at `msize` with the client's send buffer as small as the kernel
 * allows, so a large request meets real backpressure. */
static void init_small_send(struct fixture *f, uint32_t msize)
{
    struct sophia_9p_handle h;
    uint8_t b[14];
    int small = 1;
    size_t n = sophia_9p_storage_bytes(msize, 2);
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, f->fd));
    assert(!setsockopt(f->fd[0], SOL_SOCKET, SO_SNDBUF, &small, sizeof(small)));
    f->memory = malloc(n);
    assert(f->memory);
    assert(!sophia_9p_init(&f->c, f->fd[0], msize, 2, 2, f->memory, n));
    assert(!sophia_9p_version(&f->c, &h));
    assert(request(f, 100) == UINT16_MAX);
    put(b, msize, 4);
    put(b + 4, 8, 2);
    memcpy(b + 6, "9P2000.L", 8);
    answer(f, 101, UINT16_MAX, b, 14);
    take(f, 101);
}
static uint8_t *pattern(size_t n)
{
    uint8_t *p = malloc(n);
    size_t i;
    assert(p);
    for (i = 0; i < n; i++)
        p[i] = (uint8_t)(i * 13 + 5);
    return p;
}
/* Bytes the peer can read now, appended at `at`. */
static size_t drain(struct fixture *f, uint8_t *wire, size_t at, size_t room)
{
    ssize_t r;
    while ((r = recv(f->fd[1], wire + at, room - at, MSG_DONTWAIT)) > 0)
        at += (size_t)r;
    return at;
}
/* A borrowed request larger than the send buffer stops at EAGAIN partway and
 * resumes as the peer reads, sending exactly the copied request's bytes. */
static void borrowed_write_survives_backpressure(void)
{
    enum { MSIZE = 65536, COUNT = MSIZE - 23 };
    static uint8_t wire[MSIZE];
    struct fixture f;
    struct sophia_9p_handle h;
    uint8_t *data = pattern(COUNT), ok[4];
    size_t at = 0, stalls = 0, i;
    init_small_send(&f, MSIZE);
    assert(!sophia_9p_write_borrowed(&f.c, 1, 0, data, COUNT, &h));
    while (at < MSIZE) {
        assert(!sophia_9p_service(&f.c, MSIZE));
        if (sophia_9p_wants_write(&f.c))
            stalls++;
        at = drain(&f, wire, at, sizeof(wire));
    }
    assert(stalls > 0);
    assert(get32(wire) == MSIZE && wire[4] == 118 && get32(wire + 19) == COUNT);
    for (i = 0; i < COUNT; i++)
        assert(wire[23 + i] == data[i]);
    put(ok, COUNT, 4);
    answer(&f, 119, (uint16_t)get16(wire + 5), ok, 4);
    assert(take(&f, 119).count == COUNT);
    free(data);
    finish(&f);
}
/* Flushed while partly sent: the request is still sent whole before its
 * Tflush, and after Rflush its bytes are never read again (freed here, so a
 * sanitizer build sees any later read). */
static void flush_of_a_partly_sent_borrowed_write(void)
{
    static uint8_t wire[8192];
    struct fixture f;
    struct sophia_9p_handle h, fh;
    struct sophia_9p_reply r;
    uint8_t *data = pattern(4096 - 23);
    size_t at;
    init(&f, 2, 2);
    assert(!sophia_9p_write_borrowed(&f.c, 1, 0, data, 4096 - 23, &h));
    assert(!sophia_9p_service(&f.c, 10));
    at = drain(&f, wire, 0, sizeof(wire));
    assert(at == 10);
    assert(!sophia_9p_flush(&f.c, h, &fh));
    while (at < 4096 + 9) {
        assert(!sophia_9p_service(&f.c, 4096));
        at = drain(&f, wire, at, sizeof(wire));
    }
    assert(at == 4096 + 9 && !memcmp(wire + 23, data, 4096 - 23));
    assert(wire[4096 + 4] == 108 && get16(wire + 4096 + 7) == get16(wire + 5));
    answer(&f, 109, (uint16_t)get16(wire + 4096 + 5), NULL, 0);
    assert(!sophia_9p_service(&f.c, 4096));
    assert(!sophia_9p_peek(&f.c, &r) && r.type == 109);
    free(data);
    assert(!sophia_9p_consume(&f.c, r.handle));
    assert(!sophia_9p_service(&f.c, 4096));
    assert(!sophia_9p_wants_write(&f.c));
    finish(&f);
}
/* The peer goes away with the request partly sent: the terminal wire error
 * ends the borrow, and the client never touches the bytes again. */
static void terminal_close_with_borrowed_bytes_unsent(void)
{
    struct fixture f;
    struct sophia_9p_handle h;
    uint8_t *data = pattern(4096 - 23);
    int r;
    init(&f, 2, 2);
    assert(!sophia_9p_write_borrowed(&f.c, 1, 0, data, 4096 - 23, &h));
    assert(!sophia_9p_service(&f.c, 10));
    close(f.fd[1]);
    r = sophia_9p_service(&f.c, 4096);
    assert(r == SOPHIA_9P_IO || r == SOPHIA_9P_CLOSED);
    free(data);
    assert(sophia_9p_service(&f.c, 4096) == r);
    assert(sophia_9p_write_borrowed(&f.c, 1, 0, "x", 1, &h) == r);
    close(f.fd[0]);
    free(f.memory);
}
/* A reply to a borrowed request still being sent is a protocol violation:
 * the connection fails and the borrow ends with it. */
static void early_reply_to_a_queued_borrowed_write(void)
{
    enum { MSIZE = 65536, COUNT = MSIZE - 23 };
    static uint8_t wire[MSIZE];
    struct fixture f;
    struct sophia_9p_handle h;
    uint8_t *data = pattern(COUNT), ok[4] = {1, 0, 0, 0};
    size_t at;
    int r = 0;
    init_small_send(&f, MSIZE);
    assert(!sophia_9p_write_borrowed(&f.c, 1, 0, data, COUNT, &h));
    assert(!sophia_9p_service(&f.c, MSIZE));
    assert(sophia_9p_wants_write(&f.c));
    at = drain(&f, wire, 0, 23);
    assert(at >= 7);
    answer(&f, 119, (uint16_t)get16(wire + 5), ok, 4);
    while (!r)
        r = sophia_9p_service(&f.c, MSIZE);
    assert(r == SOPHIA_9P_INVALID);
    free(data);
    assert(sophia_9p_service(&f.c, MSIZE) == SOPHIA_9P_INVALID);
    finish(&f);
}
int main(void)
{
    puts("tag wrap");
    fflush(stdout);
    held_completions_and_tag_wrap();
    puts("flush");
    fflush(stdout);
    flush_fids_and_capacity();
    walk_shape_and_failures();
    preflight_and_errors();
    outstanding_read_fragmented_reply_and_eof();
    reply_shape_poisoning();
    borrowed_write_sends_the_copied_bytes();
    borrowed_write_survives_backpressure();
    flush_of_a_partly_sent_borrowed_write();
    terminal_close_with_borrowed_bytes_unsent();
    early_reply_to_a_queued_borrowed_write();
    puts("sophia_9p_client: R4-1..R4-7 controls passed");
    return 0;
}
