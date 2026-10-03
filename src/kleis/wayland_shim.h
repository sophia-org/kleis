#ifndef KLEIS_WAYLAND_SHIM_H
#define KLEIS_WAYLAND_SHIM_H

#include <stdint.h>
#include <wayland-client.h>
#include <wayland-client-protocol.h>

#include "protocols/ext-session-lock-v1-client-protocol.h"
#include "protocols/single-pixel-buffer-v1-client-protocol.h"
#include "protocols/viewporter-client-protocol.h"
#include "protocols/xdg-shell-client-protocol.h"

const char *kleis_iface_name_wl_compositor(void);
const char *kleis_iface_name_wl_output(void);
const char *kleis_iface_name_wl_seat(void);
const char *kleis_iface_name_wl_shm(void);
const char *kleis_iface_name_ext_session_lock_manager_v1(void);
const char *kleis_iface_name_wp_viewporter(void);
const char *kleis_iface_name_wp_single_pixel_buffer_manager_v1(void);
const char *kleis_iface_name_xdg_wm_base(void);

void *kleis_registry_bind_wl_compositor(struct wl_registry *registry, uint32_t name, uint32_t version);
void *kleis_registry_bind_wl_output(struct wl_registry *registry, uint32_t name, uint32_t version);
void *kleis_registry_bind_wl_seat(struct wl_registry *registry, uint32_t name, uint32_t version);
void *kleis_registry_bind_wl_shm(struct wl_registry *registry, uint32_t name, uint32_t version);
void *kleis_registry_bind_ext_session_lock_manager_v1(struct wl_registry *registry, uint32_t name, uint32_t version);
void *kleis_registry_bind_wp_viewporter(struct wl_registry *registry, uint32_t name, uint32_t version);
void *kleis_registry_bind_wp_single_pixel_buffer_manager_v1(struct wl_registry *registry, uint32_t name, uint32_t version);
void *kleis_registry_bind_xdg_wm_base(struct wl_registry *registry, uint32_t name, uint32_t version);

int kleis_wl_registry_add_listener(struct wl_registry *registry, const void *listener, void *data);
int kleis_wl_seat_add_listener(struct wl_seat *seat, const void *listener, void *data);
int kleis_wl_pointer_add_listener(struct wl_pointer *pointer, const void *listener, void *data);
int kleis_wl_keyboard_add_listener(struct wl_keyboard *keyboard, const void *listener, void *data);
int kleis_wl_buffer_add_listener(struct wl_buffer *buffer, const void *listener, void *data);
int kleis_ext_session_lock_v1_add_listener(struct ext_session_lock_v1 *lock, const void *listener, void *data);
int kleis_ext_session_lock_surface_v1_add_listener(struct ext_session_lock_surface_v1 *surface, const void *listener, void *data);
int kleis_xdg_wm_base_add_listener(struct xdg_wm_base *wm_base, const void *listener, void *data);
int kleis_xdg_surface_add_listener(struct xdg_surface *surface, const void *listener, void *data);
int kleis_xdg_toplevel_add_listener(struct xdg_toplevel *toplevel, const void *listener, void *data);

struct wl_surface *kleis_wl_compositor_create_surface(struct wl_compositor *compositor);
void kleis_wl_compositor_destroy(struct wl_compositor *compositor);
void kleis_wl_surface_destroy(struct wl_surface *surface);
void kleis_wl_surface_attach(struct wl_surface *surface, struct wl_buffer *buffer, int32_t x, int32_t y);
void kleis_wl_surface_damage_buffer(struct wl_surface *surface, int32_t x, int32_t y, int32_t width, int32_t height);
void kleis_wl_surface_commit(struct wl_surface *surface);
void kleis_wl_buffer_destroy(struct wl_buffer *buffer);
void kleis_wl_output_release(struct wl_output *output);
struct wl_shm_pool *kleis_wl_shm_create_pool(struct wl_shm *shm, int32_t fd, int32_t size);
void kleis_wl_shm_destroy(struct wl_shm *shm);
struct wl_buffer *kleis_wl_shm_pool_create_buffer(struct wl_shm_pool *pool, int32_t offset, int32_t width, int32_t height, int32_t stride, uint32_t format);
void kleis_wl_shm_pool_destroy(struct wl_shm_pool *pool);

struct wl_pointer *kleis_wl_seat_get_pointer(struct wl_seat *seat);
struct wl_keyboard *kleis_wl_seat_get_keyboard(struct wl_seat *seat);
void kleis_wl_seat_release(struct wl_seat *seat);
void kleis_wl_pointer_release(struct wl_pointer *pointer);
void kleis_wl_pointer_set_cursor(struct wl_pointer *pointer, uint32_t serial, struct wl_surface *surface, int32_t hotspot_x, int32_t hotspot_y);
void kleis_wl_keyboard_release(struct wl_keyboard *keyboard);

struct ext_session_lock_v1 *kleis_ext_session_lock_manager_v1_lock(struct ext_session_lock_manager_v1 *manager);
void kleis_ext_session_lock_manager_v1_destroy(struct ext_session_lock_manager_v1 *manager);
void kleis_ext_session_lock_v1_destroy(struct ext_session_lock_v1 *lock);
void kleis_ext_session_lock_v1_unlock_and_destroy(struct ext_session_lock_v1 *lock);
struct ext_session_lock_surface_v1 *kleis_ext_session_lock_v1_get_lock_surface(struct ext_session_lock_v1 *lock, struct wl_surface *surface, struct wl_output *output);
void kleis_ext_session_lock_surface_v1_destroy(struct ext_session_lock_surface_v1 *surface);
void kleis_ext_session_lock_surface_v1_ack_configure(struct ext_session_lock_surface_v1 *surface, uint32_t serial);

struct wl_buffer *kleis_wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(struct wp_single_pixel_buffer_manager_v1 *manager, uint32_t r, uint32_t g, uint32_t b, uint32_t a);
void kleis_wp_single_pixel_buffer_manager_v1_destroy(struct wp_single_pixel_buffer_manager_v1 *manager);
struct wp_viewport *kleis_wp_viewporter_get_viewport(struct wp_viewporter *viewporter, struct wl_surface *surface);
void kleis_wp_viewporter_destroy(struct wp_viewporter *viewporter);
void kleis_wp_viewport_destroy(struct wp_viewport *viewport);
void kleis_wp_viewport_set_destination(struct wp_viewport *viewport, int32_t width, int32_t height);

void kleis_xdg_wm_base_destroy(struct xdg_wm_base *wm_base);
void kleis_xdg_wm_base_pong(struct xdg_wm_base *wm_base, uint32_t serial);
struct xdg_surface *kleis_xdg_wm_base_get_xdg_surface(struct xdg_wm_base *wm_base, struct wl_surface *surface);
void kleis_xdg_surface_destroy(struct xdg_surface *surface);
void kleis_xdg_surface_ack_configure(struct xdg_surface *surface, uint32_t serial);
void kleis_xdg_surface_set_window_geometry(struct xdg_surface *surface, int32_t x, int32_t y, int32_t width, int32_t height);
struct xdg_toplevel *kleis_xdg_surface_get_toplevel(struct xdg_surface *surface);
void kleis_xdg_toplevel_destroy(struct xdg_toplevel *toplevel);
void kleis_xdg_toplevel_set_title(struct xdg_toplevel *toplevel, const char *title);
void kleis_xdg_toplevel_set_app_id(struct xdg_toplevel *toplevel, const char *app_id);
void kleis_xdg_toplevel_set_min_size(struct xdg_toplevel *toplevel, int32_t width, int32_t height);

#endif
