#ifndef KLEIS_MATRIX_GPU_SHIM_H
#define KLEIS_MATRIX_GPU_SHIM_H

#include <stdint.h>

/*
 * Offscreen Matrix rendering on one render node. A device owns the EGL
 * display and context; each target is one output's full-size frame. Every
 * call for a device comes from the one thread that opened it.
 */
struct kleis_matrix_gpu;
struct kleis_matrix_gpu_target;
struct kleis_matrix_gpu_frame;

/*
 * Opens exactly `render_node`, which must be a character device whose device
 * numbers equal `major` and `minor`, through GBM and surfaceless EGL with a
 * GLES 3.0 context. Nothing else is ever tried.
 */
struct kleis_matrix_gpu *kleis_matrix_gpu_open(
	const char *render_node, int64_t major, int64_t minor);

#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
/* Tests only: Mesa's surfaceless platform, with no device. */
struct kleis_matrix_gpu *kleis_matrix_gpu_open_software_test(void);
#endif

/* Whether a GL_RENDERER string names a software rasterizer. */
int32_t kleis_matrix_gpu_is_software_renderer(const char *renderer);

/* "vendor | renderer | version", valid until the device is closed. */
const char *kleis_matrix_gpu_identity(struct kleis_matrix_gpu *gpu);

/*
 * One output: its full size, its own cell size and its glyph atlas (one row
 * of glyph_count cells, one byte of coverage per texel).
 */
struct kleis_matrix_gpu_target *kleis_matrix_gpu_target_create(
	struct kleis_matrix_gpu *gpu,
	int32_t width,
	int32_t height,
	int32_t cell_width,
	int32_t cell_height,
	int32_t glyph_count,
	const uint8_t *atlas_pixels,
	int32_t atlas_width,
	int32_t atlas_height);

/*
 * One frame's readback buffer, of one target size. A frame takes a readback
 * only while it is not mapped.
 */
struct kleis_matrix_gpu_frame *kleis_matrix_gpu_frame_create(
	struct kleis_matrix_gpu *gpu, int32_t width, int32_t height);

/*
 * Renders the target's next frame and starts its readback into `frame`, of
 * the target's size and not mapped. The GPU work is only queued;
 * kleis_matrix_gpu_frame_map or kleis_matrix_gpu_frame_read waits for it.
 */
int32_t kleis_matrix_gpu_target_render(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	struct kleis_matrix_gpu_frame *frame,
	double time_seconds,
	float fall_speed,
	float cycle_speed,
	float raindrop_length,
	float brightness_decay);

/* Clears the target to one opaque colour and starts its readback. */
int32_t kleis_matrix_gpu_target_clear(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	struct kleis_matrix_gpu_frame *frame,
	float red,
	float green,
	float blue);

/* Whether a mapped frame is the frame itself: BGRA readback. */
int32_t kleis_matrix_gpu_hands_off(struct kleis_matrix_gpu *gpu);

/*
 * Waits for the frame's readback and maps it: width * height 0xAARRGGBB words
 * (BGRA8 in little-endian memory), top row first. Only with
 * kleis_matrix_gpu_hands_off. The words stay valid and unchanged until
 * kleis_matrix_gpu_frame_unmap or kleis_matrix_gpu_frame_destroy, on this
 * thread; any thread may read them meanwhile. NULL on failure.
 */
const uint32_t *kleis_matrix_gpu_frame_map(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_frame *frame);

/* Ends a mapping. 0 when its contents were lost or GL failed. */
int32_t kleis_matrix_gpu_frame_unmap(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_frame *frame);

/*
 * Waits for the frame's readback and copies it into `pixels`, as
 * kleis_matrix_gpu_frame_map would show it, on any device.
 */
int32_t kleis_matrix_gpu_frame_read(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_frame *frame,
	uint32_t *pixels);

/* Unmaps it if mapped, then frees it. */
void kleis_matrix_gpu_frame_destroy(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_frame *frame);

#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
/* Tests only: the open device's next render fails, as a GPU fault would. */
void kleis_matrix_gpu_test_fail_next_render(void);
/* Tests only: whether a device is open, from any thread. */
int32_t kleis_matrix_gpu_test_device_open(void);
/* Tests only: devices opened from now read back RGBA and copy, as one without
 * BGRA readback would. */
void kleis_matrix_gpu_test_copy_readback(int32_t copy);
/* Tests only: asymmetric 4x4 marks (top left red, top right green, bottom
 * left blue) on black, and their readback into `frame`. */
int32_t kleis_matrix_gpu_test_marks(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	struct kleis_matrix_gpu_frame *frame);
#endif

void kleis_matrix_gpu_target_destroy(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_target *target);
void kleis_matrix_gpu_close(struct kleis_matrix_gpu *gpu);

/* The calling thread's last failure. */
const char *kleis_matrix_gpu_last_error(void);

#endif
