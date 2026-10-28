// MyEmu game speed: loaded into one game at launch (LD_PRELOAD via Android's wrap.<package>
// property). The game's own code (libraries under /data/app or its data folder) sees time run at
// the speed in the debug.myemu.speed property; Android's own code keeps real time. The same
// technique as Game Killer's speed feature: scale clock_gettime and gettimeofday for game code.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>
#include <sys/time.h>
#include <time.h>

#define SPEED_PROPERTY "debug.myemu.speed"
#define MIN_SPEED 0.1
#define MAX_SPEED 10.0
#define CLOCK_COUNT 8      // CLOCK_REALTIME (0) .. CLOCK_BOOTTIME (7)
#define CALLER_SLOTS 4096  // distinct call sites; a game has a few hundred

typedef int (*clock_gettime_fn)(clockid_t, struct timespec *);
typedef int (*gettimeofday_fn)(struct timeval *, struct timezone *);

static clock_gettime_fn real_clock_gettime;
static gettimeofday_fn real_gettimeofday;

// Fake time for each clock = base_fake + (real - base_real) * speed. No heap: Android's allocator
// reads the clock while it starts up. Writers bump `sequence` around a change (seqlock), readers
// retry if it moved.
typedef struct {
    double speed;
    int64_t base_real[CLOCK_COUNT], base_fake[CLOCK_COUNT];
} Epoch;

static Epoch epoch = {.speed = 1.0};
static atomic_uint sequence;
static atomic_uint seen_property_serial;
static atomic_bool ready; // set by the constructor; until then time passes through untouched
static pthread_mutex_t epoch_lock = PTHREAD_MUTEX_INITIALIZER;

static int scaled_clock(clockid_t id) {
    return id == CLOCK_REALTIME || id == CLOCK_MONOTONIC || id == CLOCK_MONOTONIC_RAW ||
           id == CLOCK_REALTIME_COARSE || id == CLOCK_MONOTONIC_COARSE || id == CLOCK_BOOTTIME;
}

static int64_t real_ns(clockid_t id) {
    struct timespec ts;
    real_clock_gettime(id, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static int64_t fake_ns(const Epoch *epoch, clockid_t id, int64_t real) {
    return epoch->base_fake[id] + (int64_t)((double)(real - epoch->base_real[id]) * epoch->speed);
}

static double read_speed(void) {
    char value[PROP_VALUE_MAX] = "";
    if (__system_property_get(SPEED_PROPERTY, value) <= 0) return 1.0;
    double speed = strtod(value, NULL);
    return speed >= MIN_SPEED && speed <= MAX_SPEED ? speed : 1.0;
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

// Starts a new epoch where each clock continues from the time the game last saw, so time never
// jumps when the speed changes.
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

// Any property change bumps Android's global serial; only then is the speed read again.
static Epoch epoch_now(void) {
    unsigned serial = __system_property_area_serial();
    if (serial != atomic_load_explicit(&seen_property_serial, memory_order_relaxed)) {
        atomic_store_explicit(&seen_property_serial, serial, memory_order_relaxed);
        change_speed(read_speed());
    }
    return read_epoch();
}

// Return addresses already looked up: address | 1 for game code, address for Android's own.
static atomic_uintptr_t callers[CALLER_SLOTS];

static int is_game_path(const char *path) {
    return path && (strstr(path, "/data/app/") || strstr(path, "/data/data/") || strstr(path, "/data/user/"));
}

// shortcut: dladdr isn't async-signal-safe; a game reading the clock in a signal handler from a
// call site never seen before could stall. Upgrade to a /proc/self/maps range table if one does.
static int called_from_game(uintptr_t caller) {
    size_t slot = (caller >> 2) % CALLER_SLOTS;
    for (size_t probe = 0; probe < CALLER_SLOTS; probe++, slot = (slot + 1) % CALLER_SLOTS) {
        uintptr_t entry = atomic_load_explicit(&callers[slot], memory_order_relaxed);
        if (entry == 0) break;
        if ((entry & ~(uintptr_t)1) == caller) return entry & 1;
    }
    Dl_info info;
    int game = dladdr((void *)caller, &info) && is_game_path(info.dli_fname);
    uintptr_t expected = 0;
    atomic_compare_exchange_strong(&callers[slot], &expected, caller | (uintptr_t)game); // full: just don't cache
    return game;
}

// Resolved on first use: Android reads the clock before this library's constructor runs.
static void resolve(void) {
    if (!real_clock_gettime) real_clock_gettime = (clock_gettime_fn)dlsym(RTLD_NEXT, "clock_gettime");
    if (!real_gettimeofday) real_gettimeofday = (gettimeofday_fn)dlsym(RTLD_NEXT, "gettimeofday");
}

static int scaled_now(clockid_t id, struct timespec *ts, uintptr_t caller) {
    resolve();
    int result = real_clock_gettime(id, ts);
    if (result != 0 || !scaled_clock(id) || !atomic_load_explicit(&ready, memory_order_relaxed)) return result;
    Epoch now = epoch_now();
    if (now.speed == 1.0 || !called_from_game(caller)) return result;
    int64_t fake = fake_ns(&now, id, (int64_t)ts->tv_sec * 1000000000 + ts->tv_nsec);
    ts->tv_sec = fake / 1000000000;
    ts->tv_nsec = fake % 1000000000;
    return 0;
}

int clock_gettime(clockid_t id, struct timespec *ts) {
    return scaled_now(id, ts, (uintptr_t)__builtin_return_address(0));
}

int gettimeofday(struct timeval *tv, struct timezone *tz) {
    resolve();
    if (!tv) return real_gettimeofday(tv, tz);
    struct timespec ts;
    int result = scaled_now(CLOCK_REALTIME, &ts, (uintptr_t)__builtin_return_address(0));
    if (result != 0) return real_gettimeofday(tv, tz);
    if (tz) real_gettimeofday(NULL, tz);
    tv->tv_sec = ts.tv_sec;
    tv->tv_usec = ts.tv_nsec / 1000;
    return 0;
}

__attribute__((constructor)) static void load(void) {
    resolve();
    change_speed(read_speed());
    atomic_store(&seen_property_serial, __system_property_area_serial());
    atomic_store(&ready, true);
}
