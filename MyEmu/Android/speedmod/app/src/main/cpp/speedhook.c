// MyEmu game speed for the repackaged-APK build. Same scaling as Android/speed/myemu_speed.c.
// The game's own lib (libCQ2ClientEn.so) is integrity-checked by NetDragon's anti-cheat, so we must
// NOT touch its PLT/GOT (a bytehook hook there is detected and the client self-exits). Instead we
// INLINE-hook clock_gettime/gettimeofday inside libc.so with shadowhook: the game lib stays
// byte-for-byte pristine, and we scale only the clock reads whose caller is libCQ2ClientEn.so.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <jni.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>
#include <sys/time.h>
#include <time.h>

#include "shadowhook.h"
#include <android/log.h> // TEMP diagnostics (remove once speed is confirmed)

#define SPEED_PROPERTY "debug.gpu.tls" // matches MyEmu; set with `adb shell setprop debug.gpu.tls N`
#define DEFAULT_SPEED 2.0              // used when the property is unset, so the APK speeds out of the box
#define MIN_SPEED 0.1
#define MAX_SPEED 10.0
#define CLOCK_COUNT 8     // CLOCK_REALTIME (0) .. CLOCK_BOOTTIME (7)
#define CALLER_SLOTS 4096 // distinct call sites; a game has a few hundred
#define GAME_LIB "libCQ2ClientEn.so" // scale ONLY this lib's clock reads; leave anti-cheat/system real

typedef int (*clock_gettime_fn)(clockid_t, struct timespec *);
typedef int (*gettimeofday_fn)(struct timeval *, struct timezone *);

typedef int (*nanosleep_fn)(const struct timespec *, struct timespec *);
typedef int (*clock_nanosleep_fn)(clockid_t, int, const struct timespec *, struct timespec *);

static clock_gettime_fn orig_clock_gettime; // shadowhook trampoline to the real libc impl
static gettimeofday_fn orig_gettimeofday;
static nanosleep_fn orig_nanosleep;
static clock_nanosleep_fn orig_clock_nanosleep;

typedef struct {
    double speed;
    int64_t base_real[CLOCK_COUNT], base_fake[CLOCK_COUNT];
} Epoch;

static Epoch epoch = {.speed = 1.0};
static atomic_uint sequence;
static atomic_uint seen_property_serial;
static atomic_bool ready;
static pthread_mutex_t epoch_lock = PTHREAD_MUTEX_INITIALIZER;

static int scaled_clock(clockid_t id) {
    return id == CLOCK_REALTIME || id == CLOCK_MONOTONIC || id == CLOCK_MONOTONIC_RAW ||
           id == CLOCK_REALTIME_COARSE || id == CLOCK_MONOTONIC_COARSE || id == CLOCK_BOOTTIME;
}

static int64_t real_ns(clockid_t id) {
    struct timespec ts;
    orig_clock_gettime(id, &ts); // trampoline: real libc, never re-enters our proxy
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static int64_t fake_ns(const Epoch *e, clockid_t id, int64_t real) {
    return e->base_fake[id] + (int64_t)((double)(real - e->base_real[id]) * e->speed);
}

static double read_speed(void) {
    char value[PROP_VALUE_MAX] = "";
    if (__system_property_get(SPEED_PROPERTY, value) <= 0) return DEFAULT_SPEED;
    double speed = strtod(value, NULL);
    return speed >= MIN_SPEED && speed <= MAX_SPEED ? speed : DEFAULT_SPEED;
}

static Epoch read_epoch(void) {
    Epoch copy;
    unsigned before, after;
    do {
        before = atomic_load_explicit(&sequence, memory_order_acquire);
        memcpy(&copy, &epoch, sizeof copy);
        atomic_thread_fence(memory_order_acquire);
        after = atomic_load_explicit(&sequence, memory_order_relaxed);
    } while (before != after || (before & 1));
    return copy;
}

// New epoch so time continues from where the game last saw it — no jump when the speed changes.
static void change_speed(double speed) {
    pthread_mutex_lock(&epoch_lock);
    if (epoch.speed != speed) {
        Epoch next = {.speed = speed};
        for (clockid_t id = 0; id < CLOCK_COUNT; id++) {
            if (!scaled_clock(id)) continue;
            int64_t now = real_ns(id);
            next.base_real[id] = now;
            next.base_fake[id] = epoch.base_real[id] ? fake_ns(&epoch, id, now) : now;
        }
        atomic_fetch_add_explicit(&sequence, 1, memory_order_relaxed);
        atomic_thread_fence(memory_order_release);
        memcpy(&epoch, &next, sizeof next);
        atomic_fetch_add_explicit(&sequence, 1, memory_order_release);
    }
    pthread_mutex_unlock(&epoch_lock);
}

static Epoch epoch_now(void) {
    unsigned serial = __system_property_area_serial();
    if (serial != atomic_load_explicit(&seen_property_serial, memory_order_relaxed)) {
        atomic_store_explicit(&seen_property_serial, serial, memory_order_relaxed);
        change_speed(read_speed());
    }
    return read_epoch();
}

// Return addresses already classified: address | 1 for game code, address for everything else.
static atomic_uintptr_t callers[CALLER_SLOTS];

// Scale ALL of the game's own libs (engine + network SDKs), so game time and network/heartbeat
// time stay in sync — scaling only the engine lib desynced them and the server disconnected.
static int is_game_path(const char *path) {
    return path && (strstr(path, "/data/app/") || strstr(path, "/data/data/") ||
                    strstr(path, "/data/user/"));
}

static int called_from_game(uintptr_t caller) {
    if (!caller) return 0;
    size_t slot = (caller >> 2) % CALLER_SLOTS;
    for (size_t probe = 0; probe < CALLER_SLOTS; probe++, slot = (slot + 1) % CALLER_SLOTS) {
        uintptr_t entry = atomic_load_explicit(&callers[slot], memory_order_relaxed);
        if (entry == 0) break;
        if ((entry & ~(uintptr_t)1) == caller) return entry & 1;
    }
    Dl_info info;
    int game = dladdr((void *)caller, &info) && is_game_path(info.dli_fname);
    uintptr_t expected = 0;
    atomic_compare_exchange_strong(&callers[slot], &expected, caller | (uintptr_t)game);
    return game;
}

// Scale a timespec the game produced; leave every other caller (anti-cheat, system) real.
static void scale_timespec(clockid_t id, struct timespec *ts, uintptr_t caller) {
    if (!scaled_clock(id) || !atomic_load_explicit(&ready, memory_order_relaxed)) return;
    (void)caller; // scale EVERY caller: with an inline hook the game's own dt call site doesn't
                  // resolve to /data/app, so filtering by return address skipped the game's clock
    Epoch now = epoch_now();
    if (now.speed == 1.0) return;
    int64_t fake = fake_ns(&now, id, (int64_t)ts->tv_sec * 1000000000 + ts->tv_nsec);
    ts->tv_sec = fake / 1000000000;
    ts->tv_nsec = fake % 1000000000;
}

// shadowhook SHARED-mode proxies: capture the real caller, call the original via the trampoline,
// then pop shadowhook's hub stack before the single return.
static int clock_gettime_proxy(clockid_t id, struct timespec *ts) {
    void *caller = SHADOWHOOK_RETURN_ADDRESS();
    int result = orig_clock_gettime(id, ts);
    if (result == 0 && ts) scale_timespec(id, ts, (uintptr_t)caller);
    SHADOWHOOK_POP_STACK();
    return result;
}

static int gettimeofday_proxy(struct timeval *tv, struct timezone *tz) {
    void *caller = SHADOWHOOK_RETURN_ADDRESS();
    int result = orig_gettimeofday(tv, tz);
    if (result == 0 && tv) {
        struct timespec ts = {.tv_sec = tv->tv_sec, .tv_nsec = (long)tv->tv_usec * 1000};
        scale_timespec(CLOCK_REALTIME, &ts, (uintptr_t)caller);
        tv->tv_sec = ts.tv_sec;
        tv->tv_usec = ts.tv_nsec / 1000;
    }
    SHADOWHOOK_POP_STACK();
    return result;
}

// Sleeps are shortened only for the game-loop lib (libCQ2ClientEn), NOT every game lib: shortening
// the network thread's timers too broke heartbeat pacing and the server disconnected. Clock reads
// stay scaled across all game libs (called_from_game) so the client's worldview stays consistent.
static int caller_in_cocos(void *caller) {
    Dl_info info;
    return caller && dladdr(caller, &info) && info.dli_fname && strstr(info.dli_fname, GAME_LIB);
}

// Scaling the clock is not enough: a frame-capped game loop also SLEEPS between frames, so we
// must shorten the game loop's own sleeps by the same factor or the loop still runs at real rate.
static struct timespec scaled_sleep(const struct timespec *req) {
    struct timespec out = *req;
    Epoch e = epoch_now();
    if (e.speed > 1.0) {
        int64_t ns = (int64_t)(((int64_t)req->tv_sec * 1000000000 + req->tv_nsec) / e.speed);
        out.tv_sec = ns / 1000000000;
        out.tv_nsec = ns % 1000000000;
    }
    return out;
}

static int nanosleep_proxy(const struct timespec *req, struct timespec *rem) {
    void *caller = SHADOWHOOK_RETURN_ADDRESS();
    struct timespec scaled;
    const struct timespec *use = req;
    if (req && atomic_load_explicit(&ready, memory_order_relaxed) && caller_in_cocos(caller)) {
        scaled = scaled_sleep(req);
        __android_log_print(ANDROID_LOG_INFO, "MyEmuSpeed", "cocos nanosleep %lldus -> %lldus",
                            (long long)(req->tv_sec * 1000000 + req->tv_nsec / 1000),
                            (long long)(scaled.tv_sec * 1000000 + scaled.tv_nsec / 1000));
        use = &scaled;
    }
    int result = orig_nanosleep(use, rem);
    SHADOWHOOK_POP_STACK();
    return result;
}

static int clock_nanosleep_proxy(clockid_t id, int flags, const struct timespec *req,
                                 struct timespec *rem) {
    void *caller = SHADOWHOOK_RETURN_ADDRESS();
    struct timespec scaled;
    const struct timespec *use = req;
    if (req && flags == 0 && atomic_load_explicit(&ready, memory_order_relaxed) &&
        caller_in_cocos(caller)) { // flags==0: relative sleep; leave absolute ones alone
        scaled = scaled_sleep(req);
        use = &scaled;
    }
    int result = orig_clock_nanosleep(id, flags, use, rem);
    SHADOWHOOK_POP_STACK();
    return result;
}

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)vm;
    (void)reserved;
    if (shadowhook_init(SHADOWHOOK_MODE_SHARED, false) != 0) return JNI_VERSION_1_6;

    // Inline-hook libc, NOT the game lib, so libCQ2ClientEn's bytes stay intact for integrity checks.
    shadowhook_hook_sym_name("libc.so", "clock_gettime", (void *)clock_gettime_proxy,
                             (void **)&orig_clock_gettime);
    shadowhook_hook_sym_name("libc.so", "gettimeofday", (void *)gettimeofday_proxy,
                             (void **)&orig_gettimeofday);
    if (!orig_clock_gettime) return JNI_VERSION_1_6; // hook failed; stay inert

    change_speed(read_speed());
    atomic_store(&seen_property_serial, __system_property_area_serial());
    atomic_store(&ready, true);
    return JNI_VERSION_1_6;
}
