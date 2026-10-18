#ifndef AIPLAYER_MPV_SHIM_H
#define AIPLAYER_MPV_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AIPlayerMPV AIPlayerMPV;
typedef void (*AIPlayerMPVUpdateCallback)(void *context);

enum {
    AIPLAYER_MPV_EVENT_START_FILE = 1,
    AIPLAYER_MPV_EVENT_FILE_LOADED = 2,
    AIPLAYER_MPV_EVENT_END_FILE = 3,
    AIPLAYER_MPV_EVENT_SEEK = 4,
    AIPLAYER_MPV_EVENT_PLAYBACK_RESTART = 5
};

enum {
    AIPLAYER_MPV_END_REASON_EOF = 0
};

typedef struct AIPlayerMPVLifecycleEvent {
    int type;
    int error;
    int reason;
    int64_t playlist_entry_id;
} AIPlayerMPVLifecycleEvent;

AIPlayerMPV *aiplayer_mpv_create(void);
void aiplayer_mpv_destroy(AIPlayerMPV *player);
const char *aiplayer_mpv_error(int status);

int aiplayer_mpv_initialize_renderer(AIPlayerMPV *player);
void aiplayer_mpv_shutdown_renderer(AIPlayerMPV *player);
void aiplayer_mpv_set_update_callback(AIPlayerMPV *player, AIPlayerMPVUpdateCallback callback, void *context);
int aiplayer_mpv_render(AIPlayerMPV *player, int framebuffer, int width, int height);
void aiplayer_mpv_report_swap(AIPlayerMPV *player);

int aiplayer_mpv_set_string(AIPlayerMPV *player, const char *name, const char *value);
int aiplayer_mpv_set_double(AIPlayerMPV *player, const char *name, double value);
int aiplayer_mpv_set_flag(AIPlayerMPV *player, const char *name, int value);
char *aiplayer_mpv_get_string(AIPlayerMPV *player, const char *name);
double aiplayer_mpv_get_double(AIPlayerMPV *player, const char *name, double fallback);
int64_t aiplayer_mpv_get_int64(AIPlayerMPV *player, const char *name, int64_t fallback);
int aiplayer_mpv_get_flag(AIPlayerMPV *player, const char *name, int fallback);
void aiplayer_mpv_free_string(char *value);
/* Owned RGBA buffer; caller releases data with aiplayer_mpv_free_frame. */
int aiplayer_mpv_capture_rgba(AIPlayerMPV *player, uint8_t **data, int *width, int *height, int *stride);
void aiplayer_mpv_free_frame(uint8_t *data);

int aiplayer_mpv_command0(AIPlayerMPV *player, const char *command);
int aiplayer_mpv_command1(AIPlayerMPV *player, const char *command, const char *arg1);
int aiplayer_mpv_command2(AIPlayerMPV *player, const char *command, const char *arg1, const char *arg2);
int aiplayer_mpv_command3(AIPlayerMPV *player, const char *command, const char *arg1, const char *arg2, const char *arg3);
int aiplayer_mpv_command4(AIPlayerMPV *player, const char *command, const char *arg1, const char *arg2, const char *arg3, const char *arg4);
int aiplayer_mpv_next_event(AIPlayerMPV *player, AIPlayerMPVLifecycleEvent *output);
int aiplayer_mpv_drain_events(AIPlayerMPV *player, int *ended, int *error);

#ifdef __cplusplus
}
#endif
#endif
