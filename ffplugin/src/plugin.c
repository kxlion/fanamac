/* FanaMacFF: the CSL DD's force feedback plug-in for macOS.
 *
 * macOS's ForceFeedback framework loads this plug-in for the base once
 * FanaMac has named it in the base's IOCFPlugInTypes (see FanaMac's
 * NativeForce.swift). Native games call the framework directly; CrossOver
 * games get there through Wine's DirectInput and SDL2. Nothing is installed
 * in a game or a bottle.
 *
 * It plays the part of Fanatec's own driver: the
 * game's effects are kept here, constant, ramp and periodic effects are worked
 * out into one force (ffcalc), spring and damper are left to the base. The
 * result goes to FanaMac in a UDP packet (packet.h), which drives
 * the base. This plug-in never talks to the base itself.
 *
 * Packets go out only while an effect plays: every 2 ms when the force moves,
 * at least every 20 ms, and one release packet when the last effect stops.
 * Wine keeps the wheel open as long as a bottle runs, game or not.
 *
 * Call log for testing: create ~/Library/Logs/FanaMac/ff-plugin.log and the
 * plug-in appends to it (calls only, not the 2 ms ticks).
 *
 * Written from Apple's public IOForceFeedbackLib.h. MIT licence, FanaMac.
 */
#include <arpa/inet.h>
#include <math.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <IOKit/IOCFPlugIn.h>
#include <ForceFeedback/ForceFeedback.h>
#include <ForceFeedback/IOForceFeedbackLib.h>

#include "ffcalc.h"
#include "packet.h"

#define FACTORY_ID "CD5B6809-31F4-4DED-AC1D-E15E359B5EAA"  /* same as Info.plist */
#define MAX_EFFECTS 64
#define TICK_US 2000          /* the force is worked out this often, as Fanatec's driver does */
#define HEARTBEAT_US 20000    /* and sent at least this often while something plays */
/* SDL2 (CrossOver) sends its "infinite" (0xFFFFFFFF ms) times 1000, wrapped to
 * 32 bits: about 71 minutes. Taken as infinite, so a long race keeps its force. */
#define SDL_INFINITE_US 0xFFFFFC18u

/* ---------- log (only when the file already exists) ---------- */

static void say(const char *fmt, ...)
{
    const char *home = getenv("HOME");
    if (!home) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Logs/FanaMac/ff-plugin.log", home);
    if (access(path, W_OK) != 0) return;
    FILE *f = fopen(path, "a");
    if (!f) return;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    fprintf(f, "%ld.%03ld [%d] ", (long)ts.tv_sec, ts.tv_nsec / 1000000, getpid());
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static uint64_t now_us(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000;
}

/* ---------- one plug-in instance = one opened wheel ---------- */

typedef struct {
    int used;
    ff_effect fx;
} slot;

typedef struct {
    IOCFPlugInInterface *plugin;            /* must come first: QueryInterface hands out &this->plugin */
    IOForceFeedbackDeviceInterface *ff;
    CFUUIDRef factory;
    UInt32 refs;

    pthread_mutex_t lock;
    slot effects[MAX_EFFECTS];              /* download ID = index + 1 */
    double gain;                            /* FFPROP_FFGAIN / 10000 */
    int paused, actuators_off;

    pthread_t thread;
    int running;
    int sock;
    struct sockaddr_in dest;
    uint32_t seq;
    int busy;                               /* something was playing at the last tick */
    ff_output last_sent;
    uint64_t last_sent_us;
} wheel;

static wheel *from_plugin(void *p) { return (wheel *)p; }
static wheel *from_ff(void *p) { return (wheel *)((char *)p - offsetof(wheel, ff)); }

static int finished(const ff_effect *e, uint64_t t)
{
    return e->duration_us && e->iterations &&
           t - e->started_us >= e->delay_us + e->duration_us * e->iterations;
}

/* Called with the lock held. */
static int playing_now(wheel *w, uint64_t t)
{
    if (w->paused || w->actuators_off) return 0;
    for (int i = 0; i < MAX_EFFECTS; i++)
        if (w->effects[i].used && w->effects[i].fx.playing && !finished(&w->effects[i].fx, t)) return 1;
    return 0;
}

static void render(wheel *w, uint64_t t, ff_output *o)
{
    ff_effect list[MAX_EFFECTS];
    int n = 0;
    for (int i = 0; i < MAX_EFFECTS; i++)
        if (w->effects[i].used) list[n++] = w->effects[i].fx;
    if (w->paused || w->actuators_off) { *o = (ff_output){0}; return; }
    ff_render(list, n, w->gain, t, o);
}

static void send_output(wheel *w, const ff_output *o, int active, uint64_t t)
{
    w->last_sent = *o;
    w->last_sent_us = t;
    if (w->sock < 0) return;
    uint8_t p[FMFF_SIZE];
    fmff_write(p, w->seq++, o, active);
    sendto(w->sock, p, FMFF_SIZE, 0, (struct sockaddr *)&w->dest, sizeof w->dest);
}

/* Called with the lock held, after any change and at each tick. */
static void update(wheel *w, int changed)
{
    uint64_t t = now_us();
    if (playing_now(w, t)) {
        ff_output o;
        render(w, t, &o);
        if (changed || !w->busy || memcmp(&o, &w->last_sent, sizeof o) != 0 || t - w->last_sent_us >= HEARTBEAT_US)
            send_output(w, &o, 1, t);
        w->busy = 1;
    } else if (w->busy) {
        send_output(w, &(ff_output){0}, 0, t);  /* release: FanaMac lets go of the wheel */
        w->busy = 0;
    }
}

static void *ticker(void *arg)
{
    wheel *w = arg;
    uint64_t next = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (;;) {
        pthread_mutex_lock(&w->lock);
        int run = w->running;
        if (run) update(w, 0);
        pthread_mutex_unlock(&w->lock);
        if (!run) return NULL;
        /* Against a fixed schedule: a plain 2 ms sleep overshoots by about
         * 0.5 ms each time and gives 400 Hz. Late by a whole tick: start again
         * from now, no burst to catch up. */
        next += TICK_US * 1000ull;
        uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (t < next) nanosleep(&(struct timespec){0, (long)(next - t)}, NULL);
        else next = t;
    }
}

static void stop_all(wheel *w)
{
    for (int i = 0; i < MAX_EFFECTS; i++) w->effects[i].fx.playing = 0;
}

static slot *find(wheel *w, FFEffectDownloadID id)
{
    if (id < 1 || id > MAX_EFFECTS || !w->effects[id - 1].used) return NULL;
    return &w->effects[id - 1];
}

/* The nine effects Fanatec's own driver offers. */
static int effect_kind(CFUUIDRef type)
{
    if (CFEqual(type, kFFEffectType_ConstantForce_ID)) return FF_CONSTANT;
    if (CFEqual(type, kFFEffectType_RampForce_ID)) return FF_RAMP;
    if (CFEqual(type, kFFEffectType_Sine_ID)) return FF_SINE;
    if (CFEqual(type, kFFEffectType_Square_ID)) return FF_SQUARE;
    if (CFEqual(type, kFFEffectType_Triangle_ID)) return FF_TRIANGLE;
    if (CFEqual(type, kFFEffectType_SawtoothUp_ID)) return FF_SAW_UP;
    if (CFEqual(type, kFFEffectType_SawtoothDown_ID)) return FF_SAW_DOWN;
    if (CFEqual(type, kFFEffectType_Spring_ID)) return FF_SPRING;
    if (CFEqual(type, kFFEffectType_Damper_ID)) return FF_DAMPER;
    return FF_OTHER;
}

static int is_condition(int kind) { return kind == FF_SPRING || kind == FF_DAMPER; }

static void start_effect(ff_effect *f, UInt32 iterations)
{
    f->playing = 1;
    f->iterations = iterations == FF_INFINITE ? 0 : iterations;
    f->started_us = now_us();
}

/* The game's numbers (10000 = full) into ffcalc's. */
static void take_params(ff_effect *f, const FFEFFECT *p, FFEffectParameterFlag flags)
{
    if (flags & FFEP_DURATION)
        f->duration_us = p->dwDuration == FF_INFINITE || p->dwDuration == SDL_INFINITE_US ? 0 : p->dwDuration;
    if (flags & FFEP_GAIN) f->gain = p->dwGain / 10000.0;
    if (flags & FFEP_STARTDELAY && p->dwSize >= sizeof(FFEFFECT)) f->delay_us = p->dwStartDelay;
    if (flags & FFEP_DIRECTION && p->rglDirection && p->cAxes) {
        int n = p->cAxes > 2 ? 2 : (int)p->cAxes;
        long d[2] = {p->rglDirection[0], n > 1 ? p->rglDirection[1] : 0};
        int coords = p->dwFlags & FFEFF_POLAR ? 2 : p->dwFlags & FFEFF_SPHERICAL ? 3 : 1;
        f->dir_x = ff_direction_x(coords, n, d);
    }
    if (flags & FFEP_TYPESPECIFICPARAMS && p->lpvTypeSpecificParams) {
        const void *v = p->lpvTypeSpecificParams;
        DWORD got = p->cbTypeSpecificParams;
        switch (f->kind) {
        case FF_CONSTANT:
            if (got >= sizeof(FFCONSTANTFORCE)) f->magnitude = ((const FFCONSTANTFORCE *)v)->lMagnitude / 10000.0;
            break;
        case FF_RAMP:
            if (got >= sizeof(FFRAMPFORCE)) {
                f->ramp_start = ((const FFRAMPFORCE *)v)->lStart / 10000.0;
                f->ramp_end = ((const FFRAMPFORCE *)v)->lEnd / 10000.0;
            }
            break;
        case FF_SPRING: case FF_DAMPER:
            if (got >= sizeof(FFCONDITION)) {
                const FFCONDITION *c = v;  /* the first axis is the wheel */
                f->cond = (ff_condition){c->lOffset / 10000.0, c->lDeadBand / 10000.0,
                                         c->lPositiveCoefficient / 10000.0, c->lNegativeCoefficient / 10000.0,
                                         c->dwPositiveSaturation / 10000.0, c->dwNegativeSaturation / 10000.0};
            }
            break;
        default:
            if (got >= sizeof(FFPERIODIC)) {
                const FFPERIODIC *q = v;
                f->magnitude = q->dwMagnitude / 10000.0;
                f->offset = q->lOffset / 10000.0;
                f->phase = (q->dwPhase % 36000) / 36000.0;
                f->period_us = q->dwPeriod;
            }
        }
    }
    if (flags & FFEP_ENVELOPE) {
        const FFENVELOPE *e = p->lpEnvelope;
        if (e && !is_condition(f->kind))
            f->env = (ff_envelope){1, e->dwAttackLevel / 10000.0, e->dwFadeLevel / 10000.0, e->dwAttackTime, e->dwFadeTime};
        else
            f->env.on = 0;
    }
}

/* ---------- COM plumbing ---------- */

static ULONG add_ref(wheel *w) { return ++w->refs; }

static void shut_down(wheel *w)
{
    pthread_mutex_lock(&w->lock);
    int was = w->running;
    w->running = 0;
    stop_all(w);
    if (was) send_output(w, &(ff_output){0}, 0, now_us());
    w->busy = 0;
    pthread_mutex_unlock(&w->lock);
    if (was) pthread_join(w->thread, NULL);
    if (w->sock >= 0) { close(w->sock); w->sock = -1; }
}

static ULONG release(wheel *w)
{
    if (--w->refs) return w->refs;
    say("released");
    shut_down(w);
    pthread_mutex_destroy(&w->lock);
    CFPlugInRemoveInstanceForFactory(w->factory);
    CFRelease(w->factory);
    free(w);
    return 0;
}

static HRESULT query(wheel *w, REFIID iid, LPVOID *out)
{
    CFUUIDRef want = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT r = E_NOINTERFACE;
    *out = NULL;
    if (CFEqual(want, IUnknownUUID) || CFEqual(want, kIOCFPlugInInterfaceID)) { *out = &w->plugin; r = S_OK; }
    else if (CFEqual(want, kIOForceFeedbackDeviceInterfaceID)) { *out = &w->ff; r = S_OK; }
    CFRelease(want);
    if (r == S_OK) add_ref(w);
    return r;
}

/* IOCFPlugInInterface */
static HRESULT p_query(void *p, REFIID iid, LPVOID *out) { return query(from_plugin(p), iid, out); }
static ULONG p_add(void *p) { return add_ref(from_plugin(p)); }
static ULONG p_rel(void *p) { return release(from_plugin(p)); }
static IOReturn p_probe(void *p, CFDictionaryRef t, io_service_t s, SInt32 *order) { (void)p; (void)t; (void)s; if (order) *order = 0; return kIOReturnSuccess; }
static IOReturn p_start(void *p, CFDictionaryRef t, io_service_t s) { (void)p; (void)t; (void)s; return kIOReturnSuccess; }
static IOReturn p_stop(void *p) { (void)p; return kIOReturnSuccess; }

/* ---------- IOForceFeedbackDeviceInterface ---------- */

static HRESULT f_query(void *p, REFIID iid, LPVOID *out) { return query(from_ff(p), iid, out); }
static ULONG f_add(void *p) { return add_ref(from_ff(p)); }
static ULONG f_rel(void *p) { return release(from_ff(p)); }

static HRESULT f_version(void *p, ForceFeedbackVersion *v)
{
    (void)p;
    v->apiVersion.majorRev = kFFPlugInAPIMajorRev;
    v->apiVersion.minorAndBugRev = kFFPlugInAPIMinorAndBugRev;
    v->apiVersion.stage = kFFPlugInAPIStage;
    v->apiVersion.nonRelRev = kFFPlugInAPINonRelRev;
    v->plugInVersion = (NumVersion){0, 1, finalStage, 0};
    return FF_OK;
}

static HRESULT f_init(void *p, NumVersion api, io_object_t dev, boolean_t begin)
{
    (void)api; (void)dev;
    wheel *w = from_ff(p);
    say("InitializeTerminate %s", begin ? "begin" : "end");
    if (!begin) { shut_down(w); return FF_OK; }
    pthread_mutex_lock(&w->lock);
    if (!w->running) {
        w->sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        w->dest = (struct sockaddr_in){.sin_family = AF_INET, .sin_port = htons(FMFF_PORT),
                                       .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        w->running = 1;
        pthread_create(&w->thread, NULL, ticker, w);
    }
    pthread_mutex_unlock(&w->lock);
    return FF_OK;
}

static HRESULT f_destroy(void *p, FFEffectDownloadID id)
{
    wheel *w = from_ff(p);
    pthread_mutex_lock(&w->lock);
    slot *s = find(w, id);
    if (s) memset(s, 0, sizeof *s);
    update(w, 1);
    pthread_mutex_unlock(&w->lock);
    say("DestroyEffect %u", id);
    return FF_OK;  /* already gone after a reset: nothing left to do */
}

static HRESULT f_download(void *p, CFUUIDRef type, FFEffectDownloadID *id, FFEFFECT *fx, FFEffectParameterFlag flags)
{
    wheel *w = from_ff(p);
    int kind = effect_kind(type);
    if (kind == FF_OTHER) { say("DownloadEffect: effect not offered"); return FFERR_UNSUPPORTED; }
    if (!fx) return FFERR_INVALIDPARAM;
    pthread_mutex_lock(&w->lock);
    slot *s = *id ? find(w, *id) : NULL;
    if (!s) {
        for (int i = 0; i < MAX_EFFECTS && !s; i++)
            if (!w->effects[i].used) { s = &w->effects[i]; *id = (FFEffectDownloadID)(i + 1); }
        if (!s) { pthread_mutex_unlock(&w->lock); say("DownloadEffect: full"); return FFERR_DEVICEFULL; }
        *s = (slot){.used = 1, .fx = {.kind = kind, .gain = 1, .dir_x = 1}};
    }
    say("  raw: dwFlags=0x%x cAxes=%u axes=%s%d dirs=%s%d,%d typesize=%u first=%d", fx->dwFlags, fx->cAxes,
        fx->rgdwAxes ? "" : "NULL ", fx->rgdwAxes && fx->cAxes ? (int)fx->rgdwAxes[0] : 0,
        fx->rglDirection ? "" : "NULL ", fx->rglDirection && fx->cAxes ? (int)fx->rglDirection[0] : 0,
        fx->rglDirection && fx->cAxes > 1 ? (int)fx->rglDirection[1] : 0, fx->cbTypeSpecificParams,
        fx->lpvTypeSpecificParams && fx->cbTypeSpecificParams >= 4 ? *(const int *)fx->lpvTypeSpecificParams : 0);
    take_params(&s->fx, fx, flags);
    if (flags & FFEP_START) start_effect(&s->fx, 1);
    ff_effect f = s->fx;
    update(w, 1);
    pthread_mutex_unlock(&w->lock);
    say("DownloadEffect id=%u kind=%d flags=0x%x magnitude=%.4f dir_x=%.3f gain=%.3f duration=%llu period=%llu "
        "cond=%.3f/%.3f/%.3f", *id, kind, flags, f.magnitude, f.dir_x, f.gain,
        (unsigned long long)f.duration_us, (unsigned long long)f.period_us,
        f.cond.pos_coeff, f.cond.neg_coeff, fmax(f.cond.pos_sat, f.cond.neg_sat));
    return FF_OK;
}

static HRESULT f_escape(void *p, FFEffectDownloadID id, FFEFFESCAPE *e) { (void)p; (void)id; (void)e; return FFERR_UNSUPPORTED; }

static HRESULT f_status(void *p, FFEffectDownloadID id, FFEffectStatusFlag *st)
{
    wheel *w = from_ff(p);
    pthread_mutex_lock(&w->lock);
    slot *s = find(w, id);
    *st = s && s->fx.playing && !finished(&s->fx, now_us()) ? FFEGES_PLAYING : FFEGES_NOTPLAYING;
    pthread_mutex_unlock(&w->lock);
    return s ? FF_OK : FFERR_INVALIDDOWNLOADID;
}

static HRESULT f_caps(void *p, FFCAPABILITIES *c)
{
    (void)p;
    *c = (FFCAPABILITIES){0};
    c->ffSpecVer = (NumVersion){1, 0, finalStage, 0};
    c->supportedEffects = FFCAP_ET_CONSTANTFORCE | FFCAP_ET_RAMPFORCE | FFCAP_ET_SQUARE | FFCAP_ET_SINE
        | FFCAP_ET_TRIANGLE | FFCAP_ET_SAWTOOTHUP | FFCAP_ET_SAWTOOTHDOWN | FFCAP_ET_SPRING | FFCAP_ET_DAMPER;
    c->subType = FFCAP_ST_KINESTHETIC;
    c->numFfAxes = 1;
    c->ffAxes[0] = FFJOFS_X;  /* the wheel, named as games name it */
    c->storageCapacity = MAX_EFFECTS;
    c->playbackCapacity = MAX_EFFECTS;
    c->driverVer = (NumVersion){0, 1, finalStage, 0};
    return FF_OK;
}

static HRESULT f_state(void *p, ForceFeedbackDeviceState *st)
{
    wheel *w = from_ff(p);
    pthread_mutex_lock(&w->lock);
    int any = 0;
    for (int i = 0; i < MAX_EFFECTS; i++) any |= w->effects[i].used;
    int playing = playing_now(w, now_us());
    st->dwState = FFGFFS_POWERON | (w->actuators_off ? FFGFFS_ACTUATORSOFF : FFGFFS_ACTUATORSON) |
                  (w->paused ? FFGFFS_PAUSED : 0) | (any ? 0 : FFGFFS_EMPTY) | (playing ? 0 : FFGFFS_STOPPED);
    st->dwLoad = 0;
    pthread_mutex_unlock(&w->lock);
    return FF_OK;
}

static HRESULT f_command(void *p, FFCommandFlag cmd)
{
    wheel *w = from_ff(p);
    pthread_mutex_lock(&w->lock);
    if (cmd & FFSFFC_RESET) { memset(w->effects, 0, sizeof w->effects); w->paused = 0; }
    if (cmd & FFSFFC_STOPALL) stop_all(w);
    if (cmd & FFSFFC_PAUSE) w->paused = 1;
    if (cmd & FFSFFC_CONTINUE) w->paused = 0;
    if (cmd & FFSFFC_SETACTUATORSOFF) w->actuators_off = 1;
    if (cmd & FFSFFC_SETACTUATORSON) w->actuators_off = 0;
    update(w, 1);
    pthread_mutex_unlock(&w->lock);
    say("SendCommand 0x%x", cmd);
    return FF_OK;
}

static HRESULT f_prop(void *p, FFProperty prop, void *v)
{
    wheel *w = from_ff(p);
    if (prop == FFPROP_FFGAIN && v) {
        UInt32 g = *(UInt32 *)v;
        pthread_mutex_lock(&w->lock);
        w->gain = (g > 10000 ? 10000 : g) / 10000.0;
        update(w, 1);
        pthread_mutex_unlock(&w->lock);
        say("SetProperty gain %u", g);
        return FF_OK;
    }
    if (prop == FFPROP_AUTOCENTER) { say("SetProperty autocenter (left to the base)"); return FF_OK; }
    return FFERR_UNSUPPORTED;
}

static HRESULT f_start(void *p, FFEffectDownloadID id, FFEffectStartFlag mode, UInt32 iterations)
{
    wheel *w = from_ff(p);
    pthread_mutex_lock(&w->lock);
    slot *s = find(w, id);
    if (s) {
        if (mode & FFES_SOLO) stop_all(w);
        start_effect(&s->fx, iterations);
        update(w, 1);
    }
    pthread_mutex_unlock(&w->lock);
    say("StartEffect %u iterations=%u solo=%d", id, iterations, (mode & FFES_SOLO) != 0);
    return s ? FF_OK : FFERR_INVALIDDOWNLOADID;
}

static HRESULT f_stop(void *p, UInt32 id)
{
    wheel *w = from_ff(p);
    pthread_mutex_lock(&w->lock);
    slot *s = find(w, id);
    if (s) { s->fx.playing = 0; update(w, 1); }
    pthread_mutex_unlock(&w->lock);
    say("StopEffect %u", id);
    return FF_OK;
}

static IOCFPlugInInterface plugin_vt = {
    NULL, p_query, p_add, p_rel, 1, 0, p_probe, p_start, p_stop,
};
static IOForceFeedbackDeviceInterface ff_vt = {
    NULL, f_query, f_add, f_rel,
    f_version, f_init, f_destroy, f_download, f_escape, f_status, f_caps, f_state, f_command, f_prop, f_start, f_stop,
};

/* Factory named in Info.plist. */
void *FanaMacFFFactory(CFAllocatorRef alloc, CFUUIDRef type)
{
    (void)alloc;
    if (!CFEqual(type, kIOForceFeedbackLibTypeID)) return NULL;
    wheel *w = calloc(1, sizeof *w);
    if (!w) return NULL;
    w->plugin = &plugin_vt;
    w->ff = &ff_vt;
    w->refs = 1;
    w->gain = 1;
    w->sock = -1;
    pthread_mutex_init(&w->lock, NULL);
    w->factory = CFUUIDCreateFromString(NULL, CFSTR(FACTORY_ID));
    CFPlugInAddInstanceForFactory(w->factory);
    return &w->plugin;
}
