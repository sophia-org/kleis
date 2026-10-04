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
 * Renders the target's next frame and starts its readback. The GPU work is
 * only queued; kleis_matrix_gpu_target_read waits for it.
 */
int32_t kleis_matrix_gpu_target_render(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	double time_seconds,
	float fall_speed,
	float cycle_speed,
	float raindrop_length,
	float brightness_decay);

/* Clears the target to one opaque colour and starts its readback. */
int32_t kleis_matrix_gpu_target_clear(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	float red,
	float green,
	float blue);

/*
 * Waits for the readback started last and writes width * height
 * 0xAARRGGBB words (BGRA8 in little-endian memory), top row first.
 */
int32_t kleis_matrix_gpu_target_read(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	uint32_t *pixels);

void kleis_matrix_gpu_target_destroy(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_target *target);
void kleis_matrix_gpu_close(struct kleis_matrix_gpu *gpu);

/* The calling thread's last failure. */
const char *kleis_matrix_gpu_last_error(void);

#endif
