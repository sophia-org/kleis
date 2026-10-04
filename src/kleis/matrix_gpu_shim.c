#define _GNU_SOURCE
#include "matrix_gpu_shim.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define SOKOL_IMPL
#define SOKOL_GLES3
#include "vendor/sokol_gfx.h"

/*
 * The rain/symbol state pipeline adapts the classic shader structure from
 * Rezmason/matrix (MIT, copyright 2018 Rezmason): update raindrop state,
 * update symbol state, then render glyphs from an atlas.
 *
 * Frames are rendered offscreen: one framebuffer per output, read back into
 * a frame's own pixel-pack buffer behind a fence, so the frame that is waited
 * for is always one whose GPU work was queued earlier. The final pass writes
 * the frame's top row first in memory, so a readback needs no flip and a
 * mapped BGRA buffer is the frame itself.
 */

typedef struct {
	sg_image image;
	sg_view texture_view;
	sg_view attachment_view;
} kleis_state_target;

/* One output. The state targets keep the rain's per-cell history. */
struct kleis_matrix_gpu_target {
	int32_t width;
	int32_t height;
	int32_t cell_width;
	int32_t cell_height;
	int32_t glyph_count;
	int32_t grid_width;
	int32_t grid_height;
	uint32_t frame_count;
	int current_raindrop;
	int current_symbol;
	kleis_state_target raindrop[2];
	kleis_state_target symbol[2];
	sg_image atlas_image;
	sg_view atlas_view;
	int32_t atlas_width;
	int32_t atlas_height;
	GLuint framebuffer;
	GLuint color;
};

/* One frame's readback: its pack buffer, the fence of the readback queued
 * into it, and its mapping while mapped. */
struct kleis_matrix_gpu_frame {
	int32_t width;
	int32_t height;
	GLuint pack_buffer;
	GLsync fence;
	const uint32_t *mapped;
};

struct kleis_matrix_gpu {
	int fd;
	struct gbm_device *gbm;
	EGLDisplay display;
	EGLContext context;
	bool bgra_readback;
	int targets;
	int frames;

	char identity[256];
};

typedef struct {
	float grid_time[4];
	float timing[4];
} kleis_state_params;

typedef struct {
	float surface_cell[4];
	float atlas_time[4];
	float grid_params[4];
} kleis_final_params;

/* sokol_gfx is one per process; so is an open device. */
static struct kleis_matrix_gpu *g_device = NULL;
static bool g_sokol_ready = false;
static sg_pipeline g_raindrop_pipeline;
static sg_shader g_raindrop_shader;
static sg_pipeline g_symbol_pipeline;
static sg_shader g_symbol_shader;
static sg_pipeline g_final_pipeline;
static sg_shader g_final_shader;
static sg_sampler g_atlas_sampler;
static sg_sampler g_state_sampler;
static _Thread_local char g_last_error[256];
#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
/* Set by tests on their own thread, read by the device's. */
static bool g_test_fail_next_render = false;
static bool g_test_copy_readback = false;
static int32_t g_test_device_open = 0;
#endif

static const char *fullscreen_vertex_source =
	"#version 300 es\n"
	"out vec2 uv;\n"
	"void main() {\n"
	"  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
	"  uv = p;\n"
	"  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
	"}\n";

static const char *raindrop_fragment_source =
	"#version 300 es\n"
	"precision highp float;\n"
	"in vec2 uv;\n"
	"out vec4 frag_color;\n"
	"uniform vec4 grid_time;\n"
	"uniform vec4 timing;\n"
	"uniform sampler2D previous_raindrop;\n"
	"const float PI = 3.14159265359;\n"
	"const float SQRT_2 = 1.4142135623730951;\n"
	"const float SQRT_5 = 2.23606797749979;\n"
	"float randomFloat(vec2 p) {\n"
	"  float dt = dot(p, vec2(12.9898, 78.233));\n"
	"  return fract(sin(mod(dt, PI)) * 43758.5453123);\n"
	"}\n"
	"float wobble(float x) {\n"
	"  return x + 0.3 * sin(SQRT_2 * x) + 0.2 * sin(SQRT_5 * x);\n"
	"}\n"
	"float rainBrightness(float t, vec2 cell) {\n"
	"  float fall_speed = max(timing.x, 0.001);\n"
	"  float raindrop_length = max(timing.z, 0.05);\n"
	"  float column_time_offset = randomFloat(vec2(cell.x, 0.0)) * 1000.0;\n"
	"  float column_speed_offset = randomFloat(vec2(cell.x + 0.1, 0.0)) * 0.5 + 0.5;\n"
	"  float column_time = column_time_offset + t * fall_speed * column_speed_offset;\n"
	"  float glyph_y = max(grid_time.y, 1.0) - cell.y - 1.0;\n"
	"  float rain_time = (glyph_y * 0.01 + column_time) / raindrop_length;\n"
	"  rain_time = wobble(rain_time);\n"
	"  return 1.0 - fract(rain_time);\n"
	"}\n"
	"void main() {\n"
	"  vec2 grid = max(grid_time.xy, vec2(1.0));\n"
	"  float t = grid_time.z;\n"
	"  float frame = grid_time.w;\n"
	"  vec2 cell = vec2(floor(gl_FragCoord.x), grid.y - floor(gl_FragCoord.y) - 1.0);\n"
	"  vec2 prev_uv = gl_FragCoord.xy / grid;\n"
	"  vec4 prev = texture(previous_raindrop, prev_uv);\n"
	"  float brightness = rainBrightness(t, cell);\n"
	"  float brightness_below = rainBrightness(t, cell + vec2(0.0, 1.0));\n"
	"  float cursor = (brightness > brightness_below) ? 1.0 : 0.0;\n"
	"  if (frame > 0.5) {\n"
	"    brightness = mix(prev.r, brightness, clamp(timing.w, 0.0, 1.0));\n"
	"  }\n"
	"  frag_color = vec4(clamp(brightness, 0.0, 1.0), cursor, 1.0, 1.0);\n"
	"}\n";

static const char *symbol_fragment_source =
	"#version 300 es\n"
	"precision highp float;\n"
	"in vec2 uv;\n"
	"out vec4 frag_color;\n"
	"uniform vec4 grid_time;\n"
	"uniform vec4 timing;\n"
	"uniform sampler2D previous_symbol;\n"
	"uniform sampler2D raindrop_state;\n"
	"const float PI = 3.14159265359;\n"
	"float randomFloat(vec2 p) {\n"
	"  float dt = dot(p, vec2(12.9898, 78.233));\n"
	"  return fract(sin(mod(dt, PI)) * 43758.5453123);\n"
	"}\n"
	"void main() {\n"
	"  vec2 grid = max(grid_time.xy, vec2(1.0));\n"
	"  float time = grid_time.z;\n"
	"  float frame = grid_time.w;\n"
	"  float glyph_count = max(timing.w, 1.0);\n"
	"  vec2 cell = vec2(floor(gl_FragCoord.x), grid.y - floor(gl_FragCoord.y) - 1.0);\n"
	"  vec2 state_uv = gl_FragCoord.xy / grid;\n"
	"  vec4 prev = texture(previous_symbol, state_uv);\n"
	"  float age = prev.g;\n"
	"  float symbol = floor(clamp(prev.r, 0.0, 0.99999) * glyph_count);\n"
	"  if (frame <= 0.5) {\n"
	"    age = randomFloat(state_uv + vec2(0.5));\n"
	"    symbol = floor(glyph_count * randomFloat(state_uv));\n"
	"  }\n"
	"  float cycle_rate = max(timing.y, 0.001);\n"
	"  age += cycle_rate;\n"
	"  if (age >= 1.0) {\n"
	"    symbol = floor(glyph_count * randomFloat(state_uv + vec2(time)));\n"
	"    age = fract(age);\n"
	"  }\n"
	"  frag_color = vec4((symbol + 0.5) / glyph_count, age, 0.0, 1.0);\n"
	"}\n";

static const char *final_fragment_source =
	"#version 300 es\n"
	"precision highp float;\n"
	"in vec2 uv;\n"
	"out vec4 frag_color;\n"
	"uniform vec4 surface_cell;\n"
	"uniform vec4 atlas_time;\n"
	"uniform vec4 grid_params;\n"
	"uniform sampler2D raindrop_state;\n"
	"uniform sampler2D symbol_state;\n"
	"uniform sampler2D glyph_tex;\n"
	"void main() {\n"
	"  float surface_w = surface_cell.x;\n"
	"  float surface_h = surface_cell.y;\n"
	"  float cell_w = max(surface_cell.z, 1.0);\n"
	"  float cell_h = max(surface_cell.w, 1.0);\n"
	"  float glyph_count = max(atlas_time.z, 1.0);\n"
	"  vec2 grid = max(grid_params.xy, vec2(1.0));\n"
	/* Window row 0, the first row a readback writes, is the frame's top. */
	"  vec2 top_pixel = gl_FragCoord.xy;\n"
	"  if (top_pixel.x < 0.0 || top_pixel.y < 0.0 || top_pixel.x >= surface_w || top_pixel.y >= surface_h) { discard; }\n"
	"  vec2 cell = floor(top_pixel / vec2(cell_w, cell_h));\n"
	"  if (cell.x < 0.0 || cell.y < 0.0 || cell.x >= grid.x || cell.y >= grid.y) { discard; }\n"
	"  vec2 local = fract(top_pixel / vec2(cell_w, cell_h));\n"
	"  vec2 state_uv = vec2((cell.x + 0.5) / grid.x, 1.0 - ((cell.y + 0.5) / grid.y));\n"
	"  vec4 rain = texture(raindrop_state, state_uv);\n"
	"  vec4 symbol_sample = texture(symbol_state, state_uv);\n"
	"  float symbol = clamp(floor(clamp(symbol_sample.r, 0.0, 0.99999) * glyph_count), 0.0, glyph_count - 1.0);\n"
	"  vec2 atlas_size = max(atlas_time.xy, vec2(1.0));\n"
	"  vec2 glyph_size = max(vec2(atlas_size.x / glyph_count, atlas_size.y), vec2(1.0));\n"
	"  vec2 glyph_texel = clamp(local * glyph_size, vec2(0.5), glyph_size - vec2(0.5));\n"
	"  vec2 glyph_uv = vec2((symbol * glyph_size.x + glyph_texel.x) / atlas_size.x, glyph_texel.y / atlas_size.y);\n"
	"  float alpha = texture(glyph_tex, glyph_uv).r;\n"
	"  float brightness = rain.r * 1.1 - 0.5;\n"
	"  if (brightness <= 0.0 || alpha <= 0.01) { discard; }\n"
	"  vec3 trail = vec3(0.0, 0.82, 0.04) * brightness;\n"
	"  vec3 cursor = vec3(0.86, 1.0, 0.86) * max(brightness, 0.55);\n"
	"  vec3 color = mix(trail, cursor, step(0.5, rain.g));\n"
	"  frag_color = vec4(color * alpha, 1.0);\n"
	"}\n";

static void set_error(const char *message) {
	snprintf(g_last_error, sizeof(g_last_error), "%s", message);
}

static void sokol_logger(const char *tag, uint32_t level, uint32_t item, const char *message, uint32_t line, const char *filename, void *user_data) {
	(void)tag;
	(void)level;
	(void)item;
	(void)filename;
	(void)user_data;
	if (message) {
		snprintf(g_last_error, sizeof(g_last_error), "sokol:%u: %s", line, message);
	}
}

static bool resource_valid(void) {
	if (sg_query_shader_state(g_raindrop_shader) != SG_RESOURCESTATE_VALID) {
		set_error("matrix raindrop shader failed");
		return false;
	}
	if (sg_query_shader_state(g_symbol_shader) != SG_RESOURCESTATE_VALID) {
		set_error("matrix symbol shader failed");
		return false;
	}
	if (sg_query_shader_state(g_final_shader) != SG_RESOURCESTATE_VALID) {
		set_error("matrix final shader failed");
		return false;
	}
	if (sg_query_pipeline_state(g_raindrop_pipeline) != SG_RESOURCESTATE_VALID) {
		set_error("matrix raindrop pipeline failed");
		return false;
	}
	if (sg_query_pipeline_state(g_symbol_pipeline) != SG_RESOURCESTATE_VALID) {
		set_error("matrix symbol pipeline failed");
		return false;
	}
	if (sg_query_pipeline_state(g_final_pipeline) != SG_RESOURCESTATE_VALID) {
		set_error("matrix final pipeline failed");
		return false;
	}
	return true;
}

static void destroy_global_resources(void) {
	if (g_raindrop_pipeline.id != SG_INVALID_ID) {
		sg_destroy_pipeline(g_raindrop_pipeline);
		g_raindrop_pipeline = (sg_pipeline){0};
	}
	if (g_symbol_pipeline.id != SG_INVALID_ID) {
		sg_destroy_pipeline(g_symbol_pipeline);
		g_symbol_pipeline = (sg_pipeline){0};
	}
	if (g_final_pipeline.id != SG_INVALID_ID) {
		sg_destroy_pipeline(g_final_pipeline);
		g_final_pipeline = (sg_pipeline){0};
	}
	if (g_raindrop_shader.id != SG_INVALID_ID) {
		sg_destroy_shader(g_raindrop_shader);
		g_raindrop_shader = (sg_shader){0};
	}
	if (g_symbol_shader.id != SG_INVALID_ID) {
		sg_destroy_shader(g_symbol_shader);
		g_symbol_shader = (sg_shader){0};
	}
	if (g_final_shader.id != SG_INVALID_ID) {
		sg_destroy_shader(g_final_shader);
		g_final_shader = (sg_shader){0};
	}
	if (g_atlas_sampler.id != SG_INVALID_ID) {
		sg_destroy_sampler(g_atlas_sampler);
		g_atlas_sampler = (sg_sampler){0};
	}
	if (g_state_sampler.id != SG_INVALID_ID) {
		sg_destroy_sampler(g_state_sampler);
		g_state_sampler = (sg_sampler){0};
	}
}

static void destroy_state_target(kleis_state_target *target) {
	if (target->attachment_view.id != SG_INVALID_ID) {
		sg_destroy_view(target->attachment_view);
	}
	if (target->texture_view.id != SG_INVALID_ID) {
		sg_destroy_view(target->texture_view);
	}
	if (target->image.id != SG_INVALID_ID) {
		sg_destroy_image(target->image);
	}
	*target = (kleis_state_target){0};
}

static void destroy_state(struct kleis_matrix_gpu_target *gpu) {
	for (int i = 0; i < 2; i++) {
		destroy_state_target(&gpu->raindrop[i]);
		destroy_state_target(&gpu->symbol[i]);
	}
	gpu->grid_width = 0;
	gpu->grid_height = 0;
	gpu->frame_count = 0;
	gpu->current_raindrop = 0;
	gpu->current_symbol = 0;
}

static kleis_state_target make_state_target(int32_t width, int32_t height, const char *label) {
	kleis_state_target target = {0};
	target.image = sg_make_image(&(sg_image_desc){
		.usage = {
			.color_attachment = true,
			.immutable = true,
		},
		.width = width,
		.height = height,
		.pixel_format = SG_PIXELFORMAT_RGBA8,
		.sample_count = 1,
		.label = label,
	});
	target.texture_view = sg_make_view(&(sg_view_desc){
		.texture = {
			.image = target.image,
		},
		.label = "matrix-state-texture-view",
	});
	target.attachment_view = sg_make_view(&(sg_view_desc){
		.color_attachment = {
			.image = target.image,
		},
		.label = "matrix-state-attachment-view",
	});
	return target;
}

static bool state_target_valid(const kleis_state_target *target) {
	return sg_query_image_state(target->image) == SG_RESOURCESTATE_VALID &&
		sg_query_view_state(target->texture_view) == SG_RESOURCESTATE_VALID &&
		sg_query_view_state(target->attachment_view) == SG_RESOURCESTATE_VALID;
}

static void clear_state_target(kleis_state_target *target) {
	sg_begin_pass(&(sg_pass){
		.action = {
			.colors = {
				[0] = {
					.load_action = SG_LOADACTION_CLEAR,
					.clear_value = { 0.0f, 0.0f, 0.0f, 1.0f },
				},
			},
		},
		.attachments = {
			.colors = { [0] = target->attachment_view },
		},
		.label = "matrix-clear-state-pass",
	});
	sg_end_pass();
}

static bool ensure_state(struct kleis_matrix_gpu_target *gpu) {
	int32_t grid_width = gpu->width / gpu->cell_width;
	int32_t grid_height = gpu->height / gpu->cell_height;
	if (grid_width < 1) {
		grid_width = 1;
	}
	if (grid_height < 1) {
		grid_height = 1;
	}
	if (gpu->grid_width == grid_width && gpu->grid_height == grid_height) {
		return true;
	}

	destroy_state(gpu);
	gpu->grid_width = grid_width;
	gpu->grid_height = grid_height;
	gpu->raindrop[0] = make_state_target(grid_width, grid_height, "matrix-raindrop-a");
	gpu->raindrop[1] = make_state_target(grid_width, grid_height, "matrix-raindrop-b");
	gpu->symbol[0] = make_state_target(grid_width, grid_height, "matrix-symbol-a");
	gpu->symbol[1] = make_state_target(grid_width, grid_height, "matrix-symbol-b");
	for (int i = 0; i < 2; i++) {
		if (!state_target_valid(&gpu->raindrop[i]) || !state_target_valid(&gpu->symbol[i])) {
			set_error("matrix state target creation failed");
			destroy_state(gpu);
			return false;
		}
		clear_state_target(&gpu->raindrop[i]);
		clear_state_target(&gpu->symbol[i]);
	}
	gpu->frame_count = 0;
	gpu->current_raindrop = 0;
	gpu->current_symbol = 0;
	return true;
}

static sg_shader_desc raindrop_shader_desc(void) {
	sg_shader_desc desc = {0};
	desc.vertex_func.source = fullscreen_vertex_source;
	desc.fragment_func.source = raindrop_fragment_source;
	desc.uniform_blocks[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.uniform_blocks[0].size = sizeof(kleis_state_params);
	desc.uniform_blocks[0].layout = SG_UNIFORMLAYOUT_STD140;
	desc.uniform_blocks[0].glsl_uniforms[0] = (sg_glsl_shader_uniform){ .type = SG_UNIFORMTYPE_FLOAT4, .array_count = 1, .glsl_name = "grid_time" };
	desc.uniform_blocks[0].glsl_uniforms[1] = (sg_glsl_shader_uniform){ .type = SG_UNIFORMTYPE_FLOAT4, .array_count = 1, .glsl_name = "timing" };
	desc.views[0].texture.stage = SG_SHADERSTAGE_FRAGMENT;
	desc.views[0].texture.image_type = SG_IMAGETYPE_2D;
	desc.views[0].texture.sample_type = SG_IMAGESAMPLETYPE_FLOAT;
	desc.samplers[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.samplers[0].sampler_type = SG_SAMPLERTYPE_FILTERING;
	desc.texture_sampler_pairs[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.texture_sampler_pairs[0].view_slot = 0;
	desc.texture_sampler_pairs[0].sampler_slot = 0;
	desc.texture_sampler_pairs[0].glsl_name = "previous_raindrop";
	desc.label = "matrix-raindrop-shader";
	return desc;
}

static sg_shader_desc symbol_shader_desc(void) {
	sg_shader_desc desc = {0};
	desc.vertex_func.source = fullscreen_vertex_source;
	desc.fragment_func.source = symbol_fragment_source;
	desc.uniform_blocks[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.uniform_blocks[0].size = sizeof(kleis_state_params);
	desc.uniform_blocks[0].layout = SG_UNIFORMLAYOUT_STD140;
	desc.uniform_blocks[0].glsl_uniforms[0] = (sg_glsl_shader_uniform){ .type = SG_UNIFORMTYPE_FLOAT4, .array_count = 1, .glsl_name = "grid_time" };
	desc.uniform_blocks[0].glsl_uniforms[1] = (sg_glsl_shader_uniform){ .type = SG_UNIFORMTYPE_FLOAT4, .array_count = 1, .glsl_name = "timing" };
	desc.views[0].texture.stage = SG_SHADERSTAGE_FRAGMENT;
	desc.views[0].texture.image_type = SG_IMAGETYPE_2D;
	desc.views[0].texture.sample_type = SG_IMAGESAMPLETYPE_FLOAT;
	desc.views[1].texture.stage = SG_SHADERSTAGE_FRAGMENT;
	desc.views[1].texture.image_type = SG_IMAGETYPE_2D;
	desc.views[1].texture.sample_type = SG_IMAGESAMPLETYPE_FLOAT;
	desc.samplers[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.samplers[0].sampler_type = SG_SAMPLERTYPE_FILTERING;
	desc.texture_sampler_pairs[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.texture_sampler_pairs[0].view_slot = 0;
	desc.texture_sampler_pairs[0].sampler_slot = 0;
	desc.texture_sampler_pairs[0].glsl_name = "previous_symbol";
	desc.texture_sampler_pairs[1].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.texture_sampler_pairs[1].view_slot = 1;
	desc.texture_sampler_pairs[1].sampler_slot = 0;
	desc.texture_sampler_pairs[1].glsl_name = "raindrop_state";
	desc.label = "matrix-symbol-shader";
	return desc;
}

static sg_shader_desc final_shader_desc(void) {
	sg_shader_desc desc = {0};
	desc.vertex_func.source = fullscreen_vertex_source;
	desc.fragment_func.source = final_fragment_source;
	desc.uniform_blocks[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.uniform_blocks[0].size = sizeof(kleis_final_params);
	desc.uniform_blocks[0].layout = SG_UNIFORMLAYOUT_STD140;
	desc.uniform_blocks[0].glsl_uniforms[0] = (sg_glsl_shader_uniform){ .type = SG_UNIFORMTYPE_FLOAT4, .array_count = 1, .glsl_name = "surface_cell" };
	desc.uniform_blocks[0].glsl_uniforms[1] = (sg_glsl_shader_uniform){ .type = SG_UNIFORMTYPE_FLOAT4, .array_count = 1, .glsl_name = "atlas_time" };
	desc.uniform_blocks[0].glsl_uniforms[2] = (sg_glsl_shader_uniform){ .type = SG_UNIFORMTYPE_FLOAT4, .array_count = 1, .glsl_name = "grid_params" };
	for (int i = 0; i < 3; i++) {
		desc.views[i].texture.stage = SG_SHADERSTAGE_FRAGMENT;
		desc.views[i].texture.image_type = SG_IMAGETYPE_2D;
		desc.views[i].texture.sample_type = SG_IMAGESAMPLETYPE_FLOAT;
	}
	desc.samplers[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.samplers[0].sampler_type = SG_SAMPLERTYPE_FILTERING;
	desc.samplers[1].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.samplers[1].sampler_type = SG_SAMPLERTYPE_FILTERING;
	desc.texture_sampler_pairs[0].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.texture_sampler_pairs[0].view_slot = 0;
	desc.texture_sampler_pairs[0].sampler_slot = 0;
	desc.texture_sampler_pairs[0].glsl_name = "raindrop_state";
	desc.texture_sampler_pairs[1].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.texture_sampler_pairs[1].view_slot = 1;
	desc.texture_sampler_pairs[1].sampler_slot = 0;
	desc.texture_sampler_pairs[1].glsl_name = "symbol_state";
	desc.texture_sampler_pairs[2].stage = SG_SHADERSTAGE_FRAGMENT;
	desc.texture_sampler_pairs[2].view_slot = 2;
	desc.texture_sampler_pairs[2].sampler_slot = 1;
	desc.texture_sampler_pairs[2].glsl_name = "glyph_tex";
	desc.label = "matrix-final-shader";
	return desc;
}

static sg_pipeline make_pipeline(sg_shader shader, sg_pixel_format color_format, const char *label) {
	return sg_make_pipeline(&(sg_pipeline_desc){
		.shader = shader,
		.primitive_type = SG_PRIMITIVETYPE_TRIANGLES,
		.depth = {
			.pixel_format = SG_PIXELFORMAT_NONE,
		},
		.colors = {
			[0] = {
				.pixel_format = color_format,
			},
		},
		.sample_count = 1,
		.label = label,
	});
}

static bool init_sokol(void) {
	if (g_sokol_ready) {
		return true;
	}

	sg_setup(&(sg_desc){
		.environment = {
			.defaults = {
				.color_format = SG_PIXELFORMAT_RGBA8,
				.depth_format = SG_PIXELFORMAT_NONE,
				.sample_count = 1,
			},
		},
		.logger = {
			.func = sokol_logger,
		},
	});
	if (!sg_isvalid()) {
		set_error("sg_setup failed");
		return false;
	}

	g_atlas_sampler = sg_make_sampler(&(sg_sampler_desc){
		.min_filter = SG_FILTER_LINEAR,
		.mag_filter = SG_FILTER_LINEAR,
		.wrap_u = SG_WRAP_CLAMP_TO_EDGE,
		.wrap_v = SG_WRAP_CLAMP_TO_EDGE,
		.label = "matrix-glyph-sampler",
	});
	g_state_sampler = sg_make_sampler(&(sg_sampler_desc){
		.min_filter = SG_FILTER_NEAREST,
		.mag_filter = SG_FILTER_NEAREST,
		.wrap_u = SG_WRAP_CLAMP_TO_EDGE,
		.wrap_v = SG_WRAP_CLAMP_TO_EDGE,
		.label = "matrix-state-sampler",
	});

	sg_shader_desc rd = raindrop_shader_desc();
	sg_shader_desc sd = symbol_shader_desc();
	sg_shader_desc fd = final_shader_desc();
	g_raindrop_shader = sg_make_shader(&rd);
	g_symbol_shader = sg_make_shader(&sd);
	g_final_shader = sg_make_shader(&fd);
	g_raindrop_pipeline = make_pipeline(g_raindrop_shader, SG_PIXELFORMAT_RGBA8, "matrix-raindrop-pipeline");
	g_symbol_pipeline = make_pipeline(g_symbol_shader, SG_PIXELFORMAT_RGBA8, "matrix-symbol-pipeline");
	g_final_pipeline = make_pipeline(g_final_shader, SG_PIXELFORMAT_RGBA8, "matrix-final-pipeline");

	if (sg_query_sampler_state(g_atlas_sampler) != SG_RESOURCESTATE_VALID ||
			sg_query_sampler_state(g_state_sampler) != SG_RESOURCESTATE_VALID ||
			!resource_valid()) {
		destroy_global_resources();
		sg_shutdown();
		set_error(g_last_error[0] == '\0' ? "matrix gpu resource creation failed" : g_last_error);
		return false;
	}

	g_sokol_ready = true;
	return true;
}

static void render_state_pass(sg_pipeline pipeline, kleis_state_target *target, sg_bindings bindings, kleis_state_params *params, const char *label) {
	sg_begin_pass(&(sg_pass){
		.action = {
			.colors = {
				[0] = {
					.load_action = SG_LOADACTION_DONTCARE,
				},
			},
		},
		.attachments = {
			.colors = { [0] = target->attachment_view },
		},
		.label = label,
	});
	sg_apply_pipeline(pipeline);
	sg_apply_bindings(&bindings);
	sg_apply_uniforms(0, &(sg_range){ .ptr = params, .size = sizeof(*params) });
	sg_draw(0, 3, 1);
	sg_end_pass();
}

static void destroy_device(struct kleis_matrix_gpu *gpu) {
	if (gpu->display != EGL_NO_DISPLAY) {
		eglMakeCurrent(gpu->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		if (gpu->context != EGL_NO_CONTEXT) {
			eglDestroyContext(gpu->display, gpu->context);
		}
		eglTerminate(gpu->display);
	}
	if (gpu->gbm) {
		gbm_device_destroy(gpu->gbm);
	}
	if (gpu->fd >= 0) {
		close(gpu->fd);
	}
	free(gpu);
}

static bool has_extension(const char *extensions, const char *name) {
	size_t length = strlen(name);
	for (const char *at = extensions; at && (at = strstr(at, name)) != NULL; at += length) {
		if ((at == extensions || at[-1] == ' ') && (at[length] == ' ' || at[length] == '\0')) {
			return true;
		}
	}
	return false;
}

int32_t kleis_matrix_gpu_is_software_renderer(const char *renderer) {
	static const char *const software[] = {
		"llvmpipe", "softpipe", "swrast", "Software Rasterizer", "SwiftShader",
	};
	if (!renderer) {
		return 1;
	}
	for (size_t i = 0; i < sizeof(software) / sizeof(software[0]); i++) {
		if (strstr(renderer, software[i])) {
			return 1;
		}
	}
	return 0;
}

/*
 * A GLES 3.0 context made current with no surface, then sokol on it. A
 * granted render node must give a hardware renderer: Mesa can fall back to
 * a software one on a node whose driver it cannot load.
 */
static bool start_context(struct kleis_matrix_gpu *gpu, bool allow_software) {
	if (!eglInitialize(gpu->display, NULL, NULL)) {
		set_error("eglInitialize failed");
		gpu->display = EGL_NO_DISPLAY;
		return false;
	}
	const char *extensions = eglQueryString(gpu->display, EGL_EXTENSIONS);
	if (!has_extension(extensions, "EGL_KHR_surfaceless_context")) {
		set_error("EGL_KHR_surfaceless_context is not supported");
		return false;
	}
	if (!eglBindAPI(EGL_OPENGL_ES_API)) {
		set_error("eglBindAPI failed");
		return false;
	}
	EGLConfig config = EGL_NO_CONFIG_KHR;
	if (!has_extension(extensions, "EGL_KHR_no_config_context")) {
		const EGLint attrs[] = {
			EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
			EGL_NONE
		};
		EGLint count = 0;
		if (!eglChooseConfig(gpu->display, attrs, &config, 1, &count) || count < 1) {
			set_error("eglChooseConfig found no GLES 3 configuration");
			return false;
		}
	}
	const EGLint context_attrs[] = {
		EGL_CONTEXT_MAJOR_VERSION, 3,
		EGL_CONTEXT_MINOR_VERSION, 0,
		EGL_NONE
	};
	gpu->context = eglCreateContext(gpu->display, config, EGL_NO_CONTEXT, context_attrs);
	if (gpu->context == EGL_NO_CONTEXT) {
		set_error("eglCreateContext failed");
		return false;
	}
	if (!eglMakeCurrent(gpu->display, EGL_NO_SURFACE, EGL_NO_SURFACE, gpu->context)) {
		set_error("eglMakeCurrent failed");
		return false;
	}
	const char *renderer = (const char *)glGetString(GL_RENDERER);
	if (!allow_software && kleis_matrix_gpu_is_software_renderer(renderer)) {
		set_error("the render node offers only a software renderer");
		return false;
	}
	const char *gl_extensions = (const char *)glGetString(GL_EXTENSIONS);
	gpu->bgra_readback = has_extension(gl_extensions, "GL_EXT_read_format_bgra");
#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
	if (__atomic_load_n(&g_test_copy_readback, __ATOMIC_ACQUIRE)) {
		gpu->bgra_readback = false;
	}
#endif
	snprintf(gpu->identity, sizeof(gpu->identity), "%s | %s | %s",
		(const char *)glGetString(GL_VENDOR),
		renderer,
		(const char *)glGetString(GL_VERSION));
	return init_sokol();
}

static struct kleis_matrix_gpu *new_device(void) {
	if (g_device) {
		set_error("a matrix gpu device is already open");
		return NULL;
	}
	struct kleis_matrix_gpu *gpu = calloc(1, sizeof(*gpu));
	if (!gpu) {
		set_error("calloc failed");
		return NULL;
	}
	gpu->fd = -1;
	gpu->display = EGL_NO_DISPLAY;
	gpu->context = EGL_NO_CONTEXT;
	return gpu;
}

struct kleis_matrix_gpu *kleis_matrix_gpu_open(
	const char *render_node,
	int64_t major,
	int64_t minor) {
	if (!render_node || render_node[0] != '/') {
		set_error("the render node must be an absolute path");
		return NULL;
	}
	struct kleis_matrix_gpu *gpu = new_device();
	if (!gpu) {
		return NULL;
	}
	gpu->fd = open(render_node, O_RDWR | O_CLOEXEC | O_NOCTTY);
	if (gpu->fd < 0) {
		set_error("the granted render node could not be opened");
		destroy_device(gpu);
		return NULL;
	}
	/* The node opened must be the device the grant names. */
	struct stat status;
	if (fstat(gpu->fd, &status) != 0 || !S_ISCHR(status.st_mode) ||
			(int64_t)major(status.st_rdev) != major || (int64_t)minor(status.st_rdev) != minor) {
		set_error("the render node is not the granted device");
		destroy_device(gpu);
		return NULL;
	}
	gpu->gbm = gbm_create_device(gpu->fd);
	if (!gpu->gbm) {
		set_error("gbm_create_device failed");
		destroy_device(gpu);
		return NULL;
	}
	gpu->display = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gpu->gbm, NULL);
	if (gpu->display == EGL_NO_DISPLAY) {
		set_error("eglGetPlatformDisplay(GBM) failed");
		destroy_device(gpu);
		return NULL;
	}
	if (!start_context(gpu, false)) {
		destroy_device(gpu);
		return NULL;
	}
	g_device = gpu;
#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
	__atomic_store_n(&g_test_device_open, 1, __ATOMIC_RELEASE);
#endif
	return gpu;
}

#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
struct kleis_matrix_gpu *kleis_matrix_gpu_open_software_test(void) {
	/* Software rendering only: a test must never reach a device. */
	const char *previous = getenv("LIBGL_ALWAYS_SOFTWARE");
	setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
	struct kleis_matrix_gpu *gpu = new_device();
	if (!gpu) {
		return NULL;
	}
	gpu->display = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
	if (gpu->display == EGL_NO_DISPLAY) {
		set_error("eglGetPlatformDisplay(surfaceless) failed");
		destroy_device(gpu);
		return NULL;
	}
	bool started = start_context(gpu, true);
	if (!previous) {
		unsetenv("LIBGL_ALWAYS_SOFTWARE");
	}
	if (!started) {
		destroy_device(gpu);
		return NULL;
	}
	g_device = gpu;
#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
	__atomic_store_n(&g_test_device_open, 1, __ATOMIC_RELEASE);
#endif
	return gpu;
}
#endif

const char *kleis_matrix_gpu_identity(struct kleis_matrix_gpu *gpu) {
	return gpu ? gpu->identity : "";
}

static void destroy_target_gl(struct kleis_matrix_gpu_target *target) {
	if (target->framebuffer) {
		glDeleteFramebuffers(1, &target->framebuffer);
		target->framebuffer = 0;
	}
	if (target->color) {
		glDeleteRenderbuffers(1, &target->color);
		target->color = 0;
	}
}

struct kleis_matrix_gpu_target *kleis_matrix_gpu_target_create(
	struct kleis_matrix_gpu *gpu,
	int32_t width,
	int32_t height,
	int32_t cell_width,
	int32_t cell_height,
	int32_t glyph_count,
	const uint8_t *atlas_pixels,
	int32_t atlas_width,
	int32_t atlas_height) {
	if (!gpu || gpu != g_device || !g_sokol_ready || width <= 0 || height <= 0 ||
			width > 16384 || height > 16384 || cell_width <= 0 || cell_height <= 0 ||
			glyph_count <= 0 || !atlas_pixels || atlas_width <= 0 || atlas_height <= 0) {
		set_error("invalid matrix gpu target");
		return NULL;
	}
	struct kleis_matrix_gpu_target *target = calloc(1, sizeof(*target));
	if (!target) {
		set_error("calloc failed");
		return NULL;
	}
	target->width = width;
	target->height = height;
	target->cell_width = cell_width;
	target->cell_height = cell_height;
	target->glyph_count = glyph_count;
	target->atlas_width = atlas_width;
	target->atlas_height = atlas_height;
	sg_image_data atlas_data = {0};
	atlas_data.mip_levels[0].ptr = atlas_pixels;
	atlas_data.mip_levels[0].size = (size_t)atlas_width * (size_t)atlas_height;
	target->atlas_image = sg_make_image(&(sg_image_desc){
		.width = atlas_width,
		.height = atlas_height,
		.pixel_format = SG_PIXELFORMAT_R8,
		.data = atlas_data,
		.label = "matrix-glyph-atlas",
	});
	target->atlas_view = sg_make_view(&(sg_view_desc){
		.texture = { .image = target->atlas_image },
		.label = "matrix-glyph-atlas-view",
	});
	bool atlas_valid = sg_query_image_state(target->atlas_image) == SG_RESOURCESTATE_VALID &&
		sg_query_view_state(target->atlas_view) == SG_RESOURCESTATE_VALID;
	sg_reset_state_cache();
	glGenRenderbuffers(1, &target->color);
	glBindRenderbuffer(GL_RENDERBUFFER, target->color);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
	glGenFramebuffers(1, &target->framebuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, target->framebuffer);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, target->color);
	GLenum complete = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glBindRenderbuffer(GL_RENDERBUFFER, 0);
	if (!atlas_valid || complete != GL_FRAMEBUFFER_COMPLETE || glGetError() != GL_NO_ERROR || !ensure_state(target)) {
		if (g_last_error[0] == '\0' || !atlas_valid || complete != GL_FRAMEBUFFER_COMPLETE) {
			set_error("matrix gpu target allocation failed");
		}
		kleis_matrix_gpu_target_destroy(gpu, target);
		return NULL;
	}
	gpu->targets++;
	return target;
}

/* A frame the readback can go into now: this device's, the target's size,
 * and not mapped (the GPU writes a pack buffer only while it is unmapped). */
static bool frame_ready_for(struct kleis_matrix_gpu *gpu,
		struct kleis_matrix_gpu_target *target, struct kleis_matrix_gpu_frame *frame) {
	if (!gpu || gpu != g_device || !target || !frame || frame->mapped ||
			frame->width != target->width || frame->height != target->height) {
		set_error("the matrix gpu frame cannot take this readback");
		return false;
	}
	return true;
}

/* Queue the framebuffer's pixels into the frame's pack buffer behind a fence. */
static int32_t start_readback(struct kleis_matrix_gpu *gpu,
		struct kleis_matrix_gpu_target *target, struct kleis_matrix_gpu_frame *frame) {
	sg_reset_state_cache();
	if (frame->fence) {
		glDeleteSync(frame->fence);
		frame->fence = NULL;
	}
	glBindFramebuffer(GL_READ_FRAMEBUFFER, target->framebuffer);
	glBindBuffer(GL_PIXEL_PACK_BUFFER, frame->pack_buffer);
	glPixelStorei(GL_PACK_ALIGNMENT, 4);
	glReadPixels(0, 0, target->width, target->height,
		gpu->bgra_readback ? GL_BGRA_EXT : GL_RGBA, GL_UNSIGNED_BYTE, 0);
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
	frame->fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
	glFlush();
	if (!frame->fence || glGetError() != GL_NO_ERROR) {
		set_error("matrix gpu readback could not start");
		return 0;
	}
	return 1;
}

int32_t kleis_matrix_gpu_target_render(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	struct kleis_matrix_gpu_frame *frame,
	double time_seconds,
	float fall_speed,
	float cycle_speed,
	float raindrop_length,
	float brightness_decay) {
	if (!gpu || gpu != g_device || !target || !g_sokol_ready) {
		set_error("matrix gpu renderer is not initialized");
		return 0;
	}
	if (!frame_ready_for(gpu, target, frame)) {
		return 0;
	}
#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
	if (__atomic_exchange_n(&g_test_fail_next_render, false, __ATOMIC_ACQ_REL)) {
		set_error("a test failed this render");
		return 0;
	}
#endif
	if (!ensure_state(target)) {
		return 0;
	}

	sg_reset_state_cache();
	kleis_state_params state_params = {
		.grid_time = { (float)target->grid_width, (float)target->grid_height, (float)time_seconds, (float)target->frame_count },
		.timing = { fall_speed, cycle_speed, raindrop_length, brightness_decay },
	};
	int raindrop_src = target->current_raindrop;
	int raindrop_dst = 1 - raindrop_src;
	render_state_pass(
		g_raindrop_pipeline,
		&target->raindrop[raindrop_dst],
		(sg_bindings){
			.views = { [0] = target->raindrop[raindrop_src].texture_view },
			.samplers = { [0] = g_state_sampler },
		},
		&state_params,
		"matrix-raindrop-pass");
	target->current_raindrop = raindrop_dst;

	kleis_state_params symbol_params = {
		.grid_time = { (float)target->grid_width, (float)target->grid_height, (float)time_seconds, (float)target->frame_count },
		.timing = { fall_speed, cycle_speed, raindrop_length, (float)target->glyph_count },
	};
	int symbol_src = target->current_symbol;
	int symbol_dst = 1 - symbol_src;
	render_state_pass(
		g_symbol_pipeline,
		&target->symbol[symbol_dst],
		(sg_bindings){
			.views = {
				[0] = target->symbol[symbol_src].texture_view,
				[1] = target->raindrop[target->current_raindrop].texture_view,
			},
			.samplers = { [0] = g_state_sampler },
		},
		&symbol_params,
		"matrix-symbol-pass");
	target->current_symbol = symbol_dst;

	kleis_final_params final_params = {
		.surface_cell = { (float)target->width, (float)target->height, (float)target->cell_width, (float)target->cell_height },
		.atlas_time = { (float)target->atlas_width, (float)target->atlas_height, (float)target->glyph_count, (float)time_seconds },
		.grid_params = { (float)target->grid_width, (float)target->grid_height, 0.0f, 0.0f },
	};
	sg_begin_pass(&(sg_pass){
		.action = {
			.colors = {
				[0] = {
					.load_action = SG_LOADACTION_CLEAR,
					.clear_value = { 0.0f, 0.0f, 0.0f, 1.0f },
				},
			},
		},
		.swapchain = {
			.width = target->width,
			.height = target->height,
			.sample_count = 1,
			.color_format = SG_PIXELFORMAT_RGBA8,
			.depth_format = SG_PIXELFORMAT_NONE,
			.gl = { .framebuffer = target->framebuffer },
		},
		.label = "matrix-final-pass",
	});
	sg_apply_pipeline(g_final_pipeline);
	sg_apply_bindings(&(sg_bindings){
		.views = {
			[0] = target->raindrop[target->current_raindrop].texture_view,
			[1] = target->symbol[target->current_symbol].texture_view,
			[2] = target->atlas_view,
		},
		.samplers = {
			[0] = g_state_sampler,
			[1] = g_atlas_sampler,
		},
	});
	sg_apply_uniforms(0, &(sg_range){ .ptr = &final_params, .size = sizeof(final_params) });
	sg_draw(0, 3, 1);
	sg_end_pass();
	sg_commit();
	target->frame_count++;
	return start_readback(gpu, target, frame);
}

int32_t kleis_matrix_gpu_target_clear(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	struct kleis_matrix_gpu_frame *frame,
	float red,
	float green,
	float blue) {
	if (!gpu || gpu != g_device || !target) {
		set_error("matrix gpu renderer is not initialized");
		return 0;
	}
	if (!frame_ready_for(gpu, target, frame)) {
		return 0;
	}
	sg_reset_state_cache();
	glBindFramebuffer(GL_FRAMEBUFFER, target->framebuffer);
	/* sokol leaves its own scissor and write masks behind. */
	glDisable(GL_SCISSOR_TEST);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	glViewport(0, 0, target->width, target->height);
	glClearColor(red, green, blue, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	return start_readback(gpu, target, frame);
}

struct kleis_matrix_gpu_frame *kleis_matrix_gpu_frame_create(
	struct kleis_matrix_gpu *gpu, int32_t width, int32_t height) {
	if (!gpu || gpu != g_device || width <= 0 || height <= 0 || width > 16384 || height > 16384) {
		set_error("invalid matrix gpu frame");
		return NULL;
	}
	struct kleis_matrix_gpu_frame *frame = calloc(1, sizeof(*frame));
	if (!frame) {
		set_error("calloc failed");
		return NULL;
	}
	frame->width = width;
	frame->height = height;
	sg_reset_state_cache();
	glGenBuffers(1, &frame->pack_buffer);
	glBindBuffer(GL_PIXEL_PACK_BUFFER, frame->pack_buffer);
	glBufferData(GL_PIXEL_PACK_BUFFER, (GLsizeiptr)width * height * 4, NULL, GL_STREAM_READ);
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	gpu->frames++;
	if (!frame->pack_buffer || glGetError() != GL_NO_ERROR) {
		set_error("matrix gpu frame allocation failed");
		kleis_matrix_gpu_frame_destroy(gpu, frame);
		return NULL;
	}
	return frame;
}

int32_t kleis_matrix_gpu_hands_off(struct kleis_matrix_gpu *gpu) {
	return gpu && gpu == g_device && gpu->bgra_readback;
}

/* Waits for the frame's readback; a stuck GPU fails over to the CPU. */
static bool wait_readback(struct kleis_matrix_gpu_frame *frame) {
	if (!frame->fence) {
		set_error("no matrix gpu readback is pending");
		return false;
	}
	/* A second is far beyond any frame. */
	GLenum waited = glClientWaitSync(frame->fence, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ull);
	glDeleteSync(frame->fence);
	frame->fence = NULL;
	if (waited != GL_ALREADY_SIGNALED && waited != GL_CONDITION_SATISFIED) {
		set_error("matrix gpu readback did not complete");
		return false;
	}
	return true;
}

static const uint32_t *map_frame(struct kleis_matrix_gpu_frame *frame) {
	sg_reset_state_cache();
	glBindBuffer(GL_PIXEL_PACK_BUFFER, frame->pack_buffer);
	const uint32_t *mapped = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0,
		(GLsizeiptr)frame->width * frame->height * 4, GL_MAP_READ_BIT);
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	if (!mapped || glGetError() != GL_NO_ERROR) {
		set_error("matrix gpu readback could not be mapped");
		return NULL;
	}
	frame->mapped = mapped;
	return mapped;
}

const uint32_t *kleis_matrix_gpu_frame_map(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_frame *frame) {
	if (!gpu || gpu != g_device || !frame || frame->mapped || !gpu->bgra_readback) {
		set_error("this matrix gpu frame cannot be handed over");
		return NULL;
	}
	if (!wait_readback(frame)) {
		return NULL;
	}
	return map_frame(frame);
}

int32_t kleis_matrix_gpu_frame_unmap(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_frame *frame) {
	if (!gpu || gpu != g_device || !frame || !frame->mapped) {
		set_error("the matrix gpu frame is not mapped");
		return 0;
	}
	sg_reset_state_cache();
	glBindBuffer(GL_PIXEL_PACK_BUFFER, frame->pack_buffer);
	GLboolean kept = glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	frame->mapped = NULL;
	if (!kept || glGetError() != GL_NO_ERROR) {
		set_error("the matrix gpu frame's contents were lost while mapped");
		return 0;
	}
	return 1;
}

int32_t kleis_matrix_gpu_frame_read(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_frame *frame,
	uint32_t *pixels) {
	if (!gpu || gpu != g_device || !frame || frame->mapped || !pixels) {
		set_error("no matrix gpu readback can be copied");
		return 0;
	}
	if (!wait_readback(frame)) {
		return 0;
	}
	const uint32_t *mapped = map_frame(frame);
	if (!mapped) {
		return 0;
	}
	/* Rows are already top first. */
	size_t count = (size_t)frame->width * frame->height;
	if (gpu->bgra_readback) {
		memcpy(pixels, mapped, count * 4);
	} else {
		const uint8_t *bytes = (const uint8_t *)mapped;
		for (size_t i = 0; i < count; i++) {
			const uint8_t *p = bytes + i * 4;
			pixels[i] = ((uint32_t)p[3] << 24) | ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2];
		}
	}
	return kleis_matrix_gpu_frame_unmap(gpu, frame);
}

void kleis_matrix_gpu_frame_destroy(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_frame *frame) {
	if (!frame) {
		return;
	}
	if (gpu && gpu == g_device) {
		sg_reset_state_cache();
		if (frame->mapped) {
			glBindBuffer(GL_PIXEL_PACK_BUFFER, frame->pack_buffer);
			glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
			glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
		}
		if (frame->fence) {
			glDeleteSync(frame->fence);
		}
		if (frame->pack_buffer) {
			glDeleteBuffers(1, &frame->pack_buffer);
		}
		if (gpu->frames > 0) {
			gpu->frames--;
		}
	}
	free(frame);
}

#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
void kleis_matrix_gpu_test_fail_next_render(void) {
	__atomic_store_n(&g_test_fail_next_render, true, __ATOMIC_RELEASE);
}

int32_t kleis_matrix_gpu_test_device_open(void) {
	return __atomic_load_n(&g_test_device_open, __ATOMIC_ACQUIRE);
}

void kleis_matrix_gpu_test_copy_readback(int32_t copy) {
	__atomic_store_n(&g_test_copy_readback, copy != 0, __ATOMIC_RELEASE);
}

/* Black, with 4x4 marks at the frame's top left (red), top right (green) and
 * bottom left (blue), then its readback: window row 0 is the frame's top. */
int32_t kleis_matrix_gpu_test_marks(
	struct kleis_matrix_gpu *gpu,
	struct kleis_matrix_gpu_target *target,
	struct kleis_matrix_gpu_frame *frame) {
	if (!frame_ready_for(gpu, target, frame) || target->width < 8 || target->height < 8) {
		return 0;
	}
	sg_reset_state_cache();
	glBindFramebuffer(GL_FRAMEBUFFER, target->framebuffer);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	glViewport(0, 0, target->width, target->height);
	glDisable(GL_SCISSOR_TEST);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glEnable(GL_SCISSOR_TEST);
	const struct { int32_t x, y; float r, g, b; } marks[] = {
		{ 0, 0, 1, 0, 0 },
		{ target->width - 4, 0, 0, 1, 0 },
		{ 0, target->height - 4, 0, 0, 1 },
	};
	for (size_t i = 0; i < 3; i++) {
		glScissor(marks[i].x, marks[i].y, 4, 4);
		glClearColor(marks[i].r, marks[i].g, marks[i].b, 1);
		glClear(GL_COLOR_BUFFER_BIT);
	}
	glDisable(GL_SCISSOR_TEST);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	return start_readback(gpu, target, frame);
}
#endif

void kleis_matrix_gpu_target_destroy(
	struct kleis_matrix_gpu *gpu, struct kleis_matrix_gpu_target *target) {
	if (!target) {
		return;
	}
	if (gpu && gpu == g_device && g_sokol_ready) {
		destroy_state(target);
		destroy_target_gl(target);
		if (target->atlas_view.id != SG_INVALID_ID) {
			sg_destroy_view(target->atlas_view);
		}
		if (target->atlas_image.id != SG_INVALID_ID) {
			sg_destroy_image(target->atlas_image);
		}
		if (gpu->targets > 0) {
			gpu->targets--;
		}
	}
	free(target);
}

void kleis_matrix_gpu_close(struct kleis_matrix_gpu *gpu) {
	if (!gpu || gpu != g_device) {
		return;
	}
	if (g_sokol_ready) {
		destroy_global_resources();
		sg_shutdown();
		g_sokol_ready = false;
	}
	g_device = NULL;
#ifdef KLEIS_MATRIX_GPU_SOFTWARE_TEST
	__atomic_store_n(&g_test_device_open, 0, __ATOMIC_RELEASE);
#endif
	destroy_device(gpu);
}

const char *kleis_matrix_gpu_last_error(void) {
	if (g_last_error[0] == '\0') {
		return "unknown matrix gpu error";
	}
	return g_last_error;
}
