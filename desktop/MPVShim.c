#include "MPVShim.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

struct AIPlayerMPV {
    mpv_handle *handle;
    mpv_render_context *render;
    AIPlayerMPVUpdateCallback update_callback;
    void *update_context;
    int64_t current_playlist_entry_id;
};

static void *get_proc_address(void *context, const char *name) {
    (void)context;
    return dlsym(RTLD_DEFAULT, name);
}

static void render_update(void *context) {
    AIPlayerMPV *player = context;
    if (player && player->update_callback) {
        player->update_callback(player->update_context);
    }
}

AIPlayerMPV *aiplayer_mpv_create(void) {
    AIPlayerMPV *player = calloc(1, sizeof(*player));
    if (!player) return NULL;
    player->handle = mpv_create();
    if (!player->handle) {
        free(player);
        return NULL;
    }
    mpv_set_option_string(player->handle, "config", "no");
    mpv_set_option_string(player->handle, "terminal", "no");
    mpv_set_option_string(player->handle, "input-default-bindings", "no");
    mpv_set_option_string(player->handle, "input-vo-keyboard", "no");
    mpv_set_option_string(player->handle, "idle", "yes");
    mpv_set_option_string(player->handle, "keep-open", "yes");
    mpv_set_option_string(player->handle, "vo", "libmpv");
    /* libmpv otherwise renders ahead and blocks the GL queue until display
       time. Keep audio-clock scheduling but remove that look-ahead wait so
       current-frame GIF readback does not miss its sampling deadline. */
    mpv_set_option_string(player->handle, "video-timing-offset", "0");
    /* Copy-back keeps hardware acceleration without opaque VideoToolbox frames
       that libmpv's screenshot/OCR/GIF software conversion cannot read. */
    mpv_set_option_string(player->handle, "hwdec", "auto-copy");
    /* Bounded session cache: keep watched packets for backward seeks without
       refetching remote segments. Disk cache is deliberately disabled: mpv's
       append-only disk file is NOT bounded by demuxer-max-(back-)bytes. */
    if (mpv_set_option_string(player->handle, "cache", "yes") < 0 ||
        mpv_set_option_string(player->handle, "cache-on-disk", "no") < 0 ||
        mpv_set_option_string(player->handle, "demuxer-seekable-cache", "yes") < 0 ||
        mpv_set_option_string(player->handle, "demuxer-max-bytes", "134217728") < 0 ||
        mpv_set_option_string(player->handle, "demuxer-max-back-bytes", "536870912") < 0) {
        mpv_terminate_destroy(player->handle);
        free(player);
        return NULL;
    }
    if (mpv_initialize(player->handle) < 0) {
        mpv_terminate_destroy(player->handle);
        free(player);
        return NULL;
    }
    return player;
}

void aiplayer_mpv_destroy(AIPlayerMPV *player) {
    if (!player) return;
    if (player->render) {
        mpv_render_context_set_update_callback(player->render, NULL, NULL);
        mpv_render_context_free(player->render);
    }
    if (player->handle) mpv_terminate_destroy(player->handle);
    free(player);
}

const char *aiplayer_mpv_error(int status) {
    return mpv_error_string(status);
}

int aiplayer_mpv_initialize_renderer(AIPlayerMPV *player) {
    if (!player || !player->handle) return MPV_ERROR_UNINITIALIZED;
    if (player->render) return 0;
    mpv_opengl_init_params gl = { get_proc_address, NULL };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    int status = mpv_render_context_create(&player->render, player->handle, params);
    if (status >= 0) mpv_render_context_set_update_callback(player->render, render_update, player);
    return status;
}

void aiplayer_mpv_shutdown_renderer(AIPlayerMPV *player) {
    if (!player || !player->render) return;
    mpv_render_context_set_update_callback(player->render, NULL, NULL);
    player->update_callback = NULL;
    player->update_context = NULL;
    mpv_render_context_free(player->render);
    player->render = NULL;
}

void aiplayer_mpv_set_update_callback(AIPlayerMPV *player, AIPlayerMPVUpdateCallback callback, void *context) {
    if (!player) return;
    player->update_callback = callback;
    player->update_context = context;
}

int aiplayer_mpv_render(AIPlayerMPV *player, int framebuffer, int width, int height) {
    if (!player || !player->render) return MPV_ERROR_UNINITIALIZED;
    mpv_opengl_fbo fbo = { framebuffer, width, height, 0 };
    int flip = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    return mpv_render_context_render(player->render, params);
}

void aiplayer_mpv_report_swap(AIPlayerMPV *player) {
    if (player && player->render) mpv_render_context_report_swap(player->render);
}

int aiplayer_mpv_set_string(AIPlayerMPV *player, const char *name, const char *value) {
    return mpv_set_property_string(player->handle, name, value);
}
int aiplayer_mpv_set_double(AIPlayerMPV *player, const char *name, double value) {
    return mpv_set_property(player->handle, name, MPV_FORMAT_DOUBLE, &value);
}
int aiplayer_mpv_set_flag(AIPlayerMPV *player, const char *name, int value) {
    return mpv_set_property(player->handle, name, MPV_FORMAT_FLAG, &value);
}
char *aiplayer_mpv_get_string(AIPlayerMPV *player, const char *name) {
    return mpv_get_property_string(player->handle, name);
}
double aiplayer_mpv_get_double(AIPlayerMPV *player, const char *name, double fallback) {
    double value = fallback;
    return mpv_get_property(player->handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : fallback;
}
int64_t aiplayer_mpv_get_int64(AIPlayerMPV *player, const char *name, int64_t fallback) {
    int64_t value = fallback;
    return mpv_get_property(player->handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : fallback;
}
int aiplayer_mpv_get_flag(AIPlayerMPV *player, const char *name, int fallback) {
    int value = fallback;
    return mpv_get_property(player->handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value : fallback;
}
void aiplayer_mpv_free_string(char *value) { mpv_free(value); }

int aiplayer_mpv_capture_rgba(AIPlayerMPV *player, uint8_t **data, int *width, int *height, int *stride) {
    if (!player || !player->handle || !data || !width || !height || !stride) return MPV_ERROR_INVALID_PARAMETER;
    *data = NULL;
    const char *args[] = { "screenshot-raw", "subtitles", "bgra", NULL };
    mpv_node result = {0};
    int status = mpv_command_ret(player->handle, args, &result);
    if (status < 0) return status;
    int64_t w = 0, h = 0, pitch = 0;
    mpv_byte_array *bytes = NULL;
    const char *format = NULL;
    if (result.format == MPV_FORMAT_NODE_MAP) {
        mpv_node_list *map = result.u.list;
        for (int i = 0; i < map->num; i++) {
            mpv_node *value = &map->values[i];
            if (value->format == MPV_FORMAT_INT64) {
                if (!strcmp(map->keys[i], "w")) w = value->u.int64;
                if (!strcmp(map->keys[i], "h")) h = value->u.int64;
                if (!strcmp(map->keys[i], "stride")) pitch = value->u.int64;
            } else if (!strcmp(map->keys[i], "data") && value->format == MPV_FORMAT_BYTE_ARRAY) bytes = value->u.ba;
            else if (!strcmp(map->keys[i], "format") && value->format == MPV_FORMAT_STRING) format = value->u.string;
        }
    }
    status = MPV_ERROR_COMMAND;
    if (w > 0 && h > 0 && w <= 32768 && h <= 32768 && pitch >= w * 4 && pitch <= 32768 * 8 &&
        bytes && bytes->data && bytes->size >= (size_t)(pitch * h) && format && !strcmp(format, "bgra")) {
        size_t size = (size_t)w * (size_t)h * 4;
        uint8_t *copy = malloc(size);
        if (copy) {
            for (int y = 0; y < h; y++) memcpy(copy + (size_t)y * w * 4, (uint8_t *)bytes->data + (size_t)y * pitch, (size_t)w * 4);
            *data = copy; *width = (int)w; *height = (int)h; *stride = (int)w * 4;
            status = 0;
        } else status = MPV_ERROR_NOMEM;
    }
    mpv_free_node_contents(&result);
    return status;
}
void aiplayer_mpv_free_frame(uint8_t *data) { free(data); }

static int command(AIPlayerMPV *player, const char **args) {
    return mpv_command(player->handle, args);
}
int aiplayer_mpv_command0(AIPlayerMPV *player, const char *name) {
    const char *args[] = { name, NULL };
    return command(player, args);
}
int aiplayer_mpv_command1(AIPlayerMPV *player, const char *name, const char *arg1) {
    const char *args[] = { name, arg1, NULL };
    return command(player, args);
}
int aiplayer_mpv_command2(AIPlayerMPV *player, const char *name, const char *arg1, const char *arg2) {
    const char *args[] = { name, arg1, arg2, NULL };
    return command(player, args);
}
int aiplayer_mpv_command3(AIPlayerMPV *player, const char *name, const char *arg1, const char *arg2, const char *arg3) {
    const char *args[] = { name, arg1, arg2, arg3, NULL };
    return command(player, args);
}
int aiplayer_mpv_command4(AIPlayerMPV *player, const char *name, const char *arg1, const char *arg2, const char *arg3, const char *arg4) {
    const char *args[] = { name, arg1, arg2, arg3, arg4, NULL };
    return command(player, args);
}

int aiplayer_mpv_next_event(AIPlayerMPV *player, AIPlayerMPVLifecycleEvent *output) {
    if (!player || !player->handle || !output) return 0;
    for (;;) {
        mpv_event *event = mpv_wait_event(player->handle, 0);
        if (!event || event->event_id == MPV_EVENT_NONE) return 0;
        memset(output, 0, sizeof(*output));
        switch (event->event_id) {
        case MPV_EVENT_START_FILE: {
            mpv_event_start_file *start = event->data;
            player->current_playlist_entry_id = start ? start->playlist_entry_id : 0;
            output->type = AIPLAYER_MPV_EVENT_START_FILE;
            output->playlist_entry_id = player->current_playlist_entry_id;
            return 1;
        }
        case MPV_EVENT_FILE_LOADED:
            output->type = AIPLAYER_MPV_EVENT_FILE_LOADED;
            output->playlist_entry_id = player->current_playlist_entry_id;
            return 1;
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *end = event->data;
            output->type = AIPLAYER_MPV_EVENT_END_FILE;
            if (end) {
                output->error = end->error;
                output->reason = end->reason;
                output->playlist_entry_id = end->playlist_entry_id;
            }
            return 1;
        }
        case MPV_EVENT_SEEK:
            output->type = AIPLAYER_MPV_EVENT_SEEK;
            return 1;
        case MPV_EVENT_PLAYBACK_RESTART:
            output->type = AIPLAYER_MPV_EVENT_PLAYBACK_RESTART;
            return 1;
        default:
            break;
        }
    }
}

int aiplayer_mpv_drain_events(AIPlayerMPV *player, int *ended, int *error) {
    int found = 0;
    if (ended) *ended = 0;
    if (error) *error = 0;
    AIPlayerMPVLifecycleEvent event;
    while (aiplayer_mpv_next_event(player, &event)) {
        if (event.type == AIPLAYER_MPV_EVENT_START_FILE || event.type == AIPLAYER_MPV_EVENT_FILE_LOADED ||
            event.type == AIPLAYER_MPV_EVENT_SEEK || event.type == AIPLAYER_MPV_EVENT_PLAYBACK_RESTART) {
            found = 1;
            if (ended) *ended = 0;
            if (error) *error = 0;
        } else if (event.type == AIPLAYER_MPV_EVENT_END_FILE) {
            found = 1;
            if (ended && event.reason == MPV_END_FILE_REASON_EOF) *ended = 1;
            if (error && event.error < 0) *error = event.error;
        }
    }
    return found;
}
