// Loaded into Google's emulator engine (DYLD_INSERT_LIBRARIES; the engine is signed to allow it),
// the way MuMu Pro runs its renderer inside its own app: gfxstream presents every Android frame
// straight into a Metal layer, and MyEmu's window shows that layer through Core Animation's
// cross-process layer hosting (what Safari and Chrome use for their GPU processes). No GPU
// readback, no copy, no waiting for MyEmu's next display refresh.
//
// Environment (set by MyEmu): MYEMU_DISPLAY_STATE = path of the shared state file,
// MYEMU_DISPLAY_SIZE = "<width>x<height>" of Android's screen in pixels, optional MYEMU_IMEI.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <crt_externs.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <pthread.h>
#import <pthread/qos.h>
#import <stdatomic.h>
#import <sys/mman.h>
#import "MyEmuDisplay.h"

// Private Core Animation API (stable since macOS 10.x; Chromium and WebKit depend on it).
typedef uint32_t CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
@interface CAContext : NSObject
+ (instancetype)contextWithCGSConnection:(CGSConnectionID)connection options:(NSDictionary *)options;
@property(readonly) uint32_t contextId;
@property(retain) CALayer *layer;
@end

// Exported by the engine: gfxstream's "subwindow" mode, which Google's own UI uses for its window.
typedef int (*ShowOpenglesWindow)(void *window, int wx, int wy, int ww, int wh, int fbw, int fbh,
                                  float dpr, float rotation, bool deleteExisting, bool hideWindow);

static os_log_t logger;
static MyEmuDisplayState *state;
static const uint64_t slowPresentNs = 40 * NSEC_PER_MSEC;

/// Stands in for the NSWindow gfxstream expects; it only asks for these. A real window needs the
/// main thread's event loop, which the headless engine never runs.
@interface MyEmuHostWindow : NSObject
@property(strong) NSView *contentView;
@end
@implementation MyEmuHostWindow
- (NSRect)frame { return self.contentView.frame; }
- (NSRect)contentRectForFrameRect:(NSRect)rect { return rect; }
- (void)makeKeyAndOrderFront:(id)sender {}
@end

static MyEmuHostWindow *hostWindow;
static CAContext *context;

/// gfxstream (through MoltenVK) takes one drawable per presented frame.
static IMP originalNextDrawable;
static id countingNextDrawable(id self, SEL _cmd) {
    // Android waits for each present, so the presenting thread must not sit on an efficiency core.
    static _Thread_local bool raised;
    if (!raised) raised = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0;
    static _Atomic uint64_t lastNs;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t last = atomic_exchange(&lastNs, now);
    if (last && now - last >= slowPresentNs) atomic_fetch_add((_Atomic uint64_t *)&state->slowPresents, 1);
    atomic_fetch_add((_Atomic uint64_t *)&state->presents, 1);
    return ((id (*)(id, SEL))originalNextDrawable)(self, _cmd);
}

static bool showOnLayer(ShowOpenglesWindow show, int width, int height) {
    hostWindow.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    hostWindow.contentView.wantsLayer = YES;
    if (show((__bridge void *)hostWindow, 0, 0, width, height, width, height, 1, 0, true, false) != 0) return false;
    CALayer *layer = hostWindow.contentView.subviews.firstObject.layer;
    if (![layer isKindOfClass:[CAMetalLayer class]]) {
        os_log_error(logger, "gfxstream view has no Metal layer: %{public}@", layer);
        return false;
    }
    CAMetalLayer *metal = (CAMetalLayer *)layer;
    // MuMu's default (present_vsync_on 0): show a frame as soon as Android finishes it.
    metal.displaySyncEnabled = NO;
    // Android draws sRGB; untagged pixels would be shown in the display's wider gamut (too vivid).
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    metal.colorspace = srgb;
    CGColorSpaceRelease(srgb);

    [CATransaction begin];
    context = [CAContext contextWithCGSConnection:CGSMainConnectionID() options:@{}];
    context.layer = metal;
    [CATransaction commit];
    [CATransaction flush]; // no run loop here to flush it for us
    atomic_store((_Atomic uint32_t *)&state->contextId, context.contextId);
    os_log(logger, "Android screen shared as context %u (%dx%d)", context.contextId, width, height);
    return true;
}

static void attach(void) {
    ShowOpenglesWindow show = (ShowOpenglesWindow)dlsym(RTLD_DEFAULT, "android_showOpenglesWindow");
    int width = 0, height = 0;
    const char *size = getenv("MYEMU_DISPLAY_SIZE");
    if (!show || !size || sscanf(size, "%dx%d", &width, &height) != 2 || width <= 0 || height <= 0) {
        os_log_error(logger, "Not attaching: show=%p size=%{public}s", show, size ?: "(none)");
        return;
    }
    Method next = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    originalNextDrawable = method_setImplementation(next, (IMP)countingNextDrawable);
    hostWindow = [MyEmuHostWindow new];
    // The renderer starts a few seconds after the engine; until then the call returns -1.
    for (int attempt = 0; attempt < 600; attempt++) { // up to 2 minutes
        @autoreleasepool {
            if (showOnLayer(show, width, height)) return;
        }
        usleep(200 * 1000);
    }
    os_log_error(logger, "gfxstream never accepted the display; MyEmu falls back to the screenshot stream");
}

// QEMU's own threads (virtual CPUs, main loop) and gfxstream's (render, sync, post) start at default
// QoS, so a busy Mac pushes them onto efficiency cores. Start them at user-interactive QoS, like
// MuMu's engine does. Xerion Online with 8 busy Mac processes: stalls ≥ 40 ms per 20 s 13–17 → 0–2.
static bool isEngineThread(void *(*routine)(void *)) {
    static const char *gfxstream = "libgfxstream_backend.dylib";
    Dl_info info;
    if (!dladdr((const void *)routine, &info) || !info.dli_fname) return false;
    return info.dli_fbase == (void *)_NSGetMachExecuteHeader() || strstr(info.dli_fname, gfxstream);
}

typedef struct { void *(*routine)(void *); void *argument; } ThreadStart;

static void *startFast(void *raw) {
    ThreadStart start = *(ThreadStart *)raw;
    free(raw);
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    return start.routine(start.argument);
}

static int myemuPthreadCreate(pthread_t *thread, const pthread_attr_t *attr, void *(*routine)(void *), void *argument) {
    ThreadStart *start = isEngineThread(routine) ? malloc(sizeof(ThreadStart)) : NULL;
    if (!start) return pthread_create(thread, attr, routine, argument);
    *start = (ThreadStart){routine, argument};
    int result = pthread_create(thread, attr, startFast, start);
    if (result != 0) free(start);
    return result;
}

// dyld swaps every other image's pthread_create for ours (this library keeps the real one).
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement, *original;
} interposePthreadCreate = {(const void *)myemuPthreadCreate, (const void *)pthread_create};

/// The engine's modem simulator answers AT+CGSN with this hard-coded IMEI; MYEMU_IMEI replaces it
/// in memory (same length) before Android first asks.
static void patchIMEI(void) {
    static const char stock[] = "867400022047199";
    const char *imei = getenv("MYEMU_IMEI");
    if (!imei || strlen(imei) != sizeof(stock) - 1) return;
    unsigned long size = 0;
    // The engine itself (dyld's image 0 is this inserted library, not the executable).
    uint8_t *strings = getsectiondata((const struct mach_header_64 *)_NSGetMachExecuteHeader(),
                                      "__TEXT", "__cstring", &size);
    uint8_t *found = strings ? memmem(strings, size, stock, sizeof(stock)) : NULL; // with its NUL
    if (!found) {
        os_log_error(logger, "Engine IMEI not found; Android keeps the stock IMEI");
        return;
    }
    vm_address_t page = trunc_page((vm_address_t)found);
    vm_size_t length = round_page((vm_address_t)found + sizeof(stock)) - page;
    // A private, writable copy of the page (the engine is signed to allow modified pages).
    if (vm_protect(mach_task_self(), page, length, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        os_log_error(logger, "Could not make the engine IMEI writable");
        return;
    }
    memcpy(found, imei, sizeof(stock) - 1);
    vm_protect(mach_task_self(), page, length, false, VM_PROT_READ | VM_PROT_EXECUTE);
    os_log(logger, "IMEI set");
}

__attribute__((constructor)) static void start(void) {
    // The launcher and helper processes inherit the environment too; only the VM needs this.
    if (!strstr(getprogname(), "qemu-system")) return;
    logger = os_log_create("MyEmu", "display");
    patchIMEI();
    const char *path = getenv("MYEMU_DISPLAY_STATE");
    int fd = path ? open(path, O_RDWR) : -1;
    if (fd < 0) return;
    void *mapped = mmap(NULL, sizeof(MyEmuDisplayState), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) return;
    state = mapped;
    // MuMu's QEMU runs its main loop (device I/O, timers) at user-interactive priority; here the
    // constructor runs on the thread that becomes QEMU's main loop.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ attach(); });
}
