// MyEmu game speed on Windows (x86_64 Android), where games' ARM code runs in Google's translator
// (libndk_translation, Berberis). The Mac's LD_PRELOAD library can't be used: a wrapped app starts
// without the translator, and zygote ignores LD_PRELOAD (secure exec). So this library is the native
// bridge (ro.dalvik.vm.native.bridge=libgpu_tls.so): it loads the real translator, hands Android its
// interface, and patches the translator's imports so guest clock reads come here. The guest libc
// reaches the host clock through trampolines the translator looks up with dlsym (measured: ~4000
// reads/s in Xerion, all that way), plus clock_gettime and syscall directly. Only translated code
// reads the clock through those, so the game's ARM code sees time at debug.gpu.tls speed while
// Android's own code keeps real time; only the process named by debug.gpu.tlsp is scaled.
// Same clock math as MyEmu/Android/speed/myemu_speed.c. Build: build.ps1 next to this file.
#define _GNU_SOURCE
#include <android/log.h>
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/system_properties.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

uint32_t __system_property_area_serial(void);

#define SPEED_PROPERTY "debug.gpu.tls"
#define PACKAGE_PROPERTY "debug.gpu.tlsp"
#define MIN_SPEED 0.1
#define MAX_SPEED 10.0
#define CLOCK_COUNT 8
#define TRANSLATOR "libndk_translation.so"

// Android reads the bridge's interface as a struct; the real one is 160 bytes (20 pointers).
__attribute__((visibility("default"))) uintptr_t NativeBridgeItf[20];

typedef struct {
    double speed;
    int64_t base_real[CLOCK_COUNT], base_fake[CLOCK_COUNT];
} Epoch;

static Epoch epoch = {.speed = 1.0};
static atomic_uint sequence, seen_serial;
static pthread_mutex_t epoch_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint decided_serial; // the property serial `decision` was made at, for `decided_pid`
static atomic_int decided_pid = -1, decision;

static int scaled_clock(clockid_t id) {
    return id == CLOCK_REALTIME || id == CLOCK_MONOTONIC || id == CLOCK_MONOTONIC_RAW ||
           id == CLOCK_REALTIME_COARSE || id == CLOCK_MONOTONIC_COARSE || id == CLOCK_BOOTTIME;
}

static int64_t real_ns(clockid_t id) {
    struct timespec ts;
    clock_gettime(id, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static int64_t fake_ns(const Epoch *e, clockid_t id, int64_t real) {
    return e->base_fake[id] + (int64_t)((double)(real - e->base_real[id]) * e->speed);
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
    if (serial != atomic_load_explicit(&seen_serial, memory_order_relaxed)) {
        atomic_store_explicit(&seen_serial, serial, memory_order_relaxed);
        change_speed(read_speed());
    }
    return read_epoch();
}

// The bridge is loaded in zygote, so every app has it. Whether this process is the game is decided
// again whenever any property changes (MyEmu names the game after it has started, and Android names
// the process after its first clock reads), otherwise kept.
static int in_target(void) {
    int pid = getpid();
    unsigned serial = __system_property_area_serial();
    if (pid == atomic_load_explicit(&decided_pid, memory_order_relaxed) &&
        serial == atomic_load_explicit(&decided_serial, memory_order_relaxed))
        return atomic_load_explicit(&decision, memory_order_relaxed);
    char name[128] = "", want[PROP_VALUE_MAX] = "";
    int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, name, sizeof name - 1);
    close(fd);
    if (n <= 0) return 0;
    __system_property_get(PACKAGE_PROPERTY, want);
    int target = want[0] && strcmp(name, want) == 0;
    // benign race: two threads deciding at once store the same answer
    atomic_store_explicit(&decision, target, memory_order_relaxed);
    atomic_store_explicit(&decided_serial, serial, memory_order_relaxed);
    atomic_store_explicit(&decided_pid, pid, memory_order_relaxed);
    return target;
}

static void scale(clockid_t id, struct timespec *ts) {
    if (!scaled_clock(id) || !in_target()) return;
    Epoch now = epoch_now();
    if (now.speed == 1.0) return;
    int64_t fake = fake_ns(&now, id, (int64_t)ts->tv_sec * 1000000000 + ts->tv_nsec);
    ts->tv_sec = fake / 1000000000;
    ts->tv_nsec = fake % 1000000000;
}

static int scaled_clock_gettime(clockid_t id, struct timespec *ts) {
    int result = clock_gettime(id, ts);
    if (result == 0) scale(id, ts);
    return result;
}

// The translator runs the guest's own system calls through syscall(); x86_64 takes up to 6 args.
static long scaled_syscall(long number, long a, long b, long c, long d, long e, long f) {
    long result = syscall(number, a, b, c, d, e, f);
    if (result != 0) return result;
    if (number == SYS_clock_gettime && b) scale((clockid_t)a, (struct timespec *)b);
    else if (number == SYS_gettimeofday && a) {
        struct timeval *tv = (struct timeval *)a;
        struct timespec ts = {tv->tv_sec, tv->tv_usec * 1000};
        scale(CLOCK_REALTIME, &ts);
        tv->tv_sec = ts.tv_sec;
        tv->tv_usec = ts.tv_nsec / 1000;
    }
    return result;
}

// Points `name`'s GOT slots in every loaded translator library at `hook`.
static void patch_got(struct dl_phdr_info *info, const char *name, void *hook) {
    uintptr_t bias = info->dlpi_addr;
    const ElfW(Dyn) *dyn = NULL;
    for (int i = 0; i < info->dlpi_phnum; i++)
        if (info->dlpi_phdr[i].p_type == PT_DYNAMIC) dyn = (const ElfW(Dyn) *)(bias + info->dlpi_phdr[i].p_vaddr);
    if (!dyn) return;
    const ElfW(Sym) *symtab = NULL;
    const char *strtab = NULL;
    const ElfW(Rela) *tables[2] = {NULL, NULL};
    size_t sizes[2] = {0, 0};
    for (; dyn->d_tag != DT_NULL; dyn++) {
        uintptr_t p = dyn->d_un.d_ptr < bias ? bias + dyn->d_un.d_ptr : dyn->d_un.d_ptr;
        switch (dyn->d_tag) {
        case DT_SYMTAB: symtab = (const ElfW(Sym) *)p; break;
        case DT_STRTAB: strtab = (const char *)p; break;
        case DT_JMPREL: tables[0] = (const ElfW(Rela) *)p; break;
        case DT_PLTRELSZ: sizes[0] = dyn->d_un.d_val; break;
        case DT_RELA: tables[1] = (const ElfW(Rela) *)p; break;
        case DT_RELASZ: sizes[1] = dyn->d_un.d_val; break;
        }
    }
    if (!symtab || !strtab) return;
    long page = sysconf(_SC_PAGESIZE);
    for (int t = 0; t < 2; t++) {
        if (!tables[t]) continue;
        for (size_t i = 0; i < sizes[t] / sizeof(ElfW(Rela)); i++) {
            const ElfW(Rela) *r = &tables[t][i];
            unsigned type = ELF64_R_TYPE(r->r_info);
            if (type != R_X86_64_JUMP_SLOT && type != R_X86_64_GLOB_DAT) continue;
            if (strcmp(strtab + symtab[ELF64_R_SYM(r->r_info)].st_name, name)) continue;
            void **slot = (void **)(bias + r->r_offset);
            uintptr_t start = (uintptr_t)slot & ~(uintptr_t)(page - 1);
            // left writable: restoring read-only could break a slot the linker still writes
            if (mprotect((void *)start, page, PROT_READ | PROT_WRITE) == 0) *slot = hook;
        }
    }
}

static int scaled_gettimeofday(struct timeval *tv, struct timezone *tz) {
    int result = gettimeofday(tv, tz);
    if (result == 0 && tv) {
        struct timespec ts = {tv->tv_sec, tv->tv_usec * 1000};
        scale(CLOCK_REALTIME, &ts);
        tv->tv_sec = ts.tv_sec;
        tv->tv_usec = ts.tv_nsec / 1000;
    }
    return result;
}

// The guest's libc calls host functions through trampolines the translator finds with dlsym.
static void *bridged_dlsym(void *handle, const char *symbol) {
    if (symbol && !strcmp(symbol, "clock_gettime")) return (void *)scaled_clock_gettime;
    if (symbol && !strcmp(symbol, "gettimeofday")) return (void *)scaled_gettimeofday;
    return dlsym(handle, symbol);
}

static int patch_translator(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size; (void)data;
    if (info->dlpi_name && strstr(info->dlpi_name, "libndk_translation")) {
        patch_got(info, "dlsym", (void *)bridged_dlsym);
        patch_got(info, "clock_gettime", (void *)scaled_clock_gettime);
        patch_got(info, "syscall", (void *)scaled_syscall);
    }
    return 0;
}

__attribute__((constructor)) static void load(void) {
    void *translator = dlopen(TRANSLATOR, RTLD_NOW);
    void *itf = translator ? dlsym(translator, "NativeBridgeItf") : NULL;
    if (!itf) {
        __android_log_print(ANDROID_LOG_ERROR, "gputls", "no translator: %s", dlerror());
        return;
    }
    memcpy(NativeBridgeItf, itf, sizeof NativeBridgeItf);
    dl_iterate_phdr(patch_translator, NULL);
}
