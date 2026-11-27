/* Works out the wheel force from the game's DirectInput effects.
 * Plain C, no Windows headers, so it is tested on the Mac.
 *
 * Same split as Fanatec's own driver: the constant, ramp and periodic effects
 * are computed here and add up to one level (sent as the base's constant
 * force). Spring and damper are played by the base itself, so only their
 * settings are passed on.
 *
 * MIT licence, FanaMac.
 */
#ifndef FANAMAC_FFCALC_H
#define FANAMAC_FFCALC_H

#include <stdint.h>

enum ff_kind {
    FF_OTHER = 0,
    FF_CONSTANT,
    FF_RAMP,
    FF_SINE,
    FF_SQUARE,
    FF_TRIANGLE,
    FF_SAW_UP,
    FF_SAW_DOWN,
    FF_SPRING,
    FF_DAMPER,
};

/* DIENVELOPE, levels 0 ... 1. */
typedef struct {
    int on;
    double attack_level, fade_level;
    uint64_t attack_us, fade_us;
} ff_envelope;

/* DICONDITION for the wheel axis. Offset and deadband in axis units
 * (-1 ... +1 is the whole travel), coefficients -1 ... +1, saturations 0 ... 1. */
typedef struct {
    double offset, deadband;
    double pos_coeff, neg_coeff;
    double pos_sat, neg_sat;
} ff_condition;

typedef struct {
    int kind;
    double magnitude;      /* constant -1 ... +1; periodic 0 ... 1 */
    double offset;         /* periodic, -1 ... +1 */
    double phase;          /* periodic, 0 ... 1 of a period */
    uint64_t period_us;    /* periodic */
    double ramp_start, ramp_end;
    ff_envelope env;
    ff_condition cond;
    double gain;           /* 0 ... 1, from DIEFFECT.dwGain */
    double dir_x;          /* -1 ... +1, X part of the direction */
    uint64_t duration_us;  /* 0 = forever */
    uint64_t delay_us;     /* start delay */
    int playing;
    uint64_t started_us;
    uint32_t iterations;   /* 0 = forever */
} ff_effect;

/* What the base is asked to play: one condition slot (spring or damper).
 * Saturation 0 means the slot is off. */
typedef struct {
    double offset, deadband, pos_coeff, neg_coeff, saturation;
} ff_slot;

typedef struct {
    double level;          /* -1 ... +1, positive turns the wheel clockwise;
                            * the opposite of the game's sign (see ff_render) */
    ff_slot spring, damper;
} ff_output;

/* X part of a DirectInput direction. coords: 1 cartesian, 2 polar, 3 spherical. */
double ff_direction_x(int coords, int naxes, const long *dirs);

/* Everything playing at now_us, times the device gain. */
void ff_render(const ff_effect *fx, int count, double device_gain, uint64_t now_us, ff_output *out);

#endif
