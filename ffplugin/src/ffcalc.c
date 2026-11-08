/* MIT licence, FanaMac. See ffcalc.h. */
#include "ffcalc.h"

#include <math.h>

#define PI 3.14159265358979323846

double ff_direction_x(int coords, int naxes, const long *dirs)
{
    if (naxes <= 0 || !dirs) return 1;
    switch (coords) {
    case 2: /* polar: hundredths of a degree, 0 = north, 9000 = east (+X) */
        return sin(dirs[0] / 100.0 * PI / 180.0);
    case 3: /* spherical: hundredths of a degree from +X */
        return cos(dirs[0] / 100.0 * PI / 180.0);
    default: /* cartesian */
        if (naxes == 1) return dirs[0] < 0 ? -1 : 1;
        {
            double x = dirs[0], y = dirs[1];
            double len = sqrt(x * x + y * y);
            return len > 0 ? x / len : 1;
        }
    }
}

static double clamp(double v, double lo, double hi)
{
    return v < lo ? lo : v > hi ? hi : v;
}

/* Time since the current iteration began, or -1 when the effect is not on. */
static int64_t play_time(const ff_effect *e, uint64_t now_us)
{
    if (!e->playing || now_us < e->started_us + e->delay_us) return -1;
    uint64_t played = now_us - e->started_us - e->delay_us;
    if (e->duration_us == 0) return (int64_t)played;
    if (e->iterations != 0 && played >= e->duration_us * e->iterations) return -1;
    return (int64_t)(played % e->duration_us);
}

/* The envelope's level at time t, for an effect whose steady level is `sustain`. */
static double envelope(const ff_effect *e, double sustain, uint64_t t)
{
    const ff_envelope *v = &e->env;
    if (!v->on) return sustain;
    if (e->duration_us && v->fade_us && t + v->fade_us > e->duration_us) {
        double left = (double)(e->duration_us - t) / v->fade_us;
        return v->fade_level + (sustain - v->fade_level) * left;
    }
    if (v->attack_us && t < v->attack_us)
        return v->attack_level + (sustain - v->attack_level) * ((double)t / v->attack_us);
    return sustain;
}

/* One period of each wave shape, x = 0 ... 1, value -1 ... +1. */
static double wave(int kind, double x)
{
    switch (kind) {
    case FF_SINE: return sin(2 * PI * x);
    case FF_SQUARE: return x < 0.5 ? 1 : -1;
    case FF_TRIANGLE: return x < 0.5 ? 4 * x - 1 : 3 - 4 * x;
    case FF_SAW_UP: return 2 * x - 1;
    case FF_SAW_DOWN: return 1 - 2 * x;
    default: return 0;
    }
}

/* Force of one constant, ramp or periodic effect, before gains and direction. */
static double force(const ff_effect *e, uint64_t t)
{
    switch (e->kind) {
    case FF_CONSTANT: {
        double m = envelope(e, fabs(e->magnitude), t);
        return e->magnitude < 0 ? -m : m;
    }
    case FF_RAMP: {
        double r = e->duration_us ? (double)t / e->duration_us : 0;
        double v = e->ramp_start + (e->ramp_end - e->ramp_start) * r;
        double top = fmax(fabs(e->ramp_start), fabs(e->ramp_end));
        return top > 0 ? v * envelope(e, top, t) / top : 0;
    }
    case FF_SINE: case FF_SQUARE: case FF_TRIANGLE: case FF_SAW_UP: case FF_SAW_DOWN: {
        double x = e->phase + (e->period_us ? (double)t / e->period_us : 0);
        return e->offset + envelope(e, e->magnitude, t) * wave(e->kind, x - floor(x));
    }
    default:
        return 0;
    }
}

static void add_condition(ff_slot *s, int *taken, const ff_condition *c, double g)
{
    if (!*taken) { s->offset = c->offset; s->deadband = c->deadband; *taken = 1; }
    s->pos_coeff = clamp(s->pos_coeff + c->pos_coeff * g, -1, 1);
    s->neg_coeff = clamp(s->neg_coeff + c->neg_coeff * g, -1, 1);
    s->saturation = clamp(s->saturation + fmax(c->pos_sat, c->neg_sat) * g, 0, 1);
}

void ff_render(const ff_effect *fx, int count, double device_gain, uint64_t now_us, ff_output *out)
{
    *out = (ff_output){0};
    int spring_taken = 0, damper_taken = 0;
    double sum = 0;
    for (int i = 0; i < count; i++) {
        const ff_effect *e = &fx[i];
        int64_t t = play_time(e, now_us);
        if (t < 0) continue;
        double g = e->gain * device_gain;
        if (e->kind == FF_SPRING) add_condition(&out->spring, &spring_taken, &e->cond, g);
        else if (e->kind == FF_DAMPER) add_condition(&out->damper, &damper_taken, &e->cond, g);
        else sum += force(e, (uint64_t)t) * g * e->dir_x;
    }
    /* The motor has a top: past it the force is simply the most it can do.
     * A game's positive force turns the wheel anti-clockwise (X down): with
     * the opposite sign, ACC pushed the wheel away from the centre. */
    out->level = -clamp(sum, -1, 1);
}
