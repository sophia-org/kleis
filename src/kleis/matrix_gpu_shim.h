#ifndef KLEIS_MATRIX_GPU_SHIM_H
#define KLEIS_MATRIX_GPU_SHIM_H

#include <stdint.h>
#include <wayland-client.h>

struct kleis_matrix_gpu;

struct kleis_matrix_gpu *kleis_matrix_gpu_create(
	struct wl_display *display,
	struct wl_surface *surface,
	int32_t width,
	int32_t height,
	int32_t cell_width,
	int32_t cell_height,
	int32_t glyph_count,
	const uint8_t *atlas_pixels,
	int32_t atlas_width,
	int32_t atlas_height);

int32_t kleis_matrix_gpu_resize(struct kleis_matrix_gpu *gpu, int32_t width, int32_t height);

int32_t kleis_matrix_gpu_render(
	struct kleis_matrix_gpu *gpu,
	double time_seconds,
	float fall_speed,
	float cycle_speed,
	float raindrop_length,
	float brightness_decay);

void kleis_matrix_gpu_destroy(struct kleis_matrix_gpu *gpu);
void kleis_matrix_gpu_shutdown(void);
const char *kleis_matrix_gpu_last_error(void);

#endif
