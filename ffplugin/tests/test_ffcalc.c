/* Host tests for ffcalc.c and packet.h: ./build.sh test */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "ffcalc.h"
#include "packet.h"

static int failures, count;
#define CHECK(cond, msg) do { count++; if (!(cond)) { failures++; printf("FAIL line %d: %s\n", __LINE__, msg); } } while (0)
#define NEAR(a, b) (fabs((a) - (b)) < 1e-9)

/* An effect that started at t = 1 s, forever, full gain, towards +X. */
static ff_effect make(int kind)
{
    ff_effect e = {0};
    e.kind = kind;
    e.gain = 1;
    e.dir_x = 1;
    e.playing = 1;
    e.started_us = 1000000;
    e.iterations = 1;
    return e;
}

static double level(const ff_effect *fx, int n, uint64_t t)
{
    ff_output o;
    ff_render(fx, n, 1, t, &o);
    return -o.level;  /* the game's own sign: ff_render turns it round for the wheel */
}

static float f32_at(const uint8_t *p)
{
    uint32_t bits = p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

int main(void)
{
    long right = 1, left = -1, east = 9000, west = 27000, sph0 = 0, sph180 = 18000;
    long xy[2] = {3, 4};
    CHECK(ff_direction_x(1, 1, &right) == 1, "cartesian +1");
    CHECK(ff_direction_x(1, 1, &left) == -1, "cartesian -1");
    CHECK(NEAR(ff_direction_x(1, 2, xy), 0.6), "cartesian 2 axes");
    CHECK(NEAR(ff_direction_x(2, 1, &east), 1), "polar east");
    CHECK(NEAR(ff_direction_x(2, 1, &west), -1), "polar west");
    CHECK(NEAR(ff_direction_x(3, 1, &sph0), 1), "spherical 0");
    CHECK(NEAR(ff_direction_x(3, 1, &sph180), -1), "spherical 180");
    CHECK(ff_direction_x(1, 0, NULL) == 1, "no axes");

    /* constant forces */
    ff_effect fx[3];
    fx[0] = make(FF_CONSTANT); fx[0].magnitude = 0.5;
    CHECK(NEAR(level(fx, 1, 2000000), 0.5), "one constant");
    ff_output o;
    ff_render(fx, 1, 0.5, 2000000, &o);
    CHECK(NEAR(o.level, -0.25), "device gain, and a positive game force turns the wheel anti-clockwise");
    fx[0].gain = 0.5;
    CHECK(NEAR(level(fx, 1, 2000000), 0.25), "effect gain");
    fx[0].gain = 1;
    fx[1] = make(FF_CONSTANT); fx[1].magnitude = 0.25; fx[1].dir_x = -1;
    CHECK(NEAR(level(fx, 2, 2000000), 0.25), "two constants add up");
    fx[2] = make(FF_OTHER); fx[2].magnitude = 1;
    CHECK(NEAR(level(fx, 3, 2000000), 0.25), "unknown effects give nothing");
    fx[0].magnitude = -1; fx[1].magnitude = -1; fx[1].dir_x = 1;
    CHECK(level(fx, 2, 2000000) == -1, "sum stops at the motor's top");

    /* timing */
    ff_effect t = make(FF_CONSTANT);
    t.magnitude = 1; t.duration_us = 100000; t.delay_us = 50000;
    CHECK(level(&t, 1, 1040000) == 0, "start delay");
    CHECK(level(&t, 1, 1060000) == 1, "on after delay");
    CHECK(level(&t, 1, 1160000) == 0, "off after duration");
    t.iterations = 2;
    CHECK(level(&t, 1, 1160000) == 1, "second iteration");
    t.playing = 0;
    CHECK(level(&t, 1, 1060000) == 0, "stopped");

    /* envelope: 0.2 → 1 over 100 ms, 1 → 0 over the last 100 ms of 1 s */
    ff_effect env = make(FF_CONSTANT);
    env.magnitude = -1; env.duration_us = 1000000;
    env.env = (ff_envelope){1, 0.2, 0, 100000, 100000};
    CHECK(NEAR(level(&env, 1, 1000000), -0.2), "attack start");
    CHECK(NEAR(level(&env, 1, 1050000), -0.6), "attack middle");
    CHECK(NEAR(level(&env, 1, 1500000), -1), "sustain");
    CHECK(NEAR(level(&env, 1, 1950000), -0.5), "fade middle");

    /* ramp: 0.2 → -0.6 over 1 s */
    ff_effect ramp = make(FF_RAMP);
    ramp.ramp_start = 0.2; ramp.ramp_end = -0.6; ramp.duration_us = 1000000;
    CHECK(NEAR(level(&ramp, 1, 1000000), 0.2), "ramp start");
    CHECK(NEAR(level(&ramp, 1, 1500000), -0.2), "ramp middle");
    CHECK(level(&ramp, 1, 2000001) == 0, "ramp over");

    /* periodic: 100 ms period, magnitude 0.5, offset 0.1 */
    ff_effect sine = make(FF_SINE);
    sine.magnitude = 0.5; sine.offset = 0.1; sine.period_us = 100000;
    CHECK(NEAR(level(&sine, 1, 1000000), 0.1), "sine at 0");
    CHECK(NEAR(level(&sine, 1, 1025000), 0.6), "sine at a quarter");
    CHECK(NEAR(level(&sine, 1, 1075000), -0.4), "sine at three quarters");
    sine.phase = 0.25;
    CHECK(NEAR(level(&sine, 1, 1000000), 0.6), "sine phase");
    sine.dir_x = -1; sine.phase = 0;
    CHECK(NEAR(level(&sine, 1, 1025000), -0.6), "sine direction");
    ff_effect sq = make(FF_SQUARE); sq.magnitude = 1; sq.period_us = 100000;
    CHECK(level(&sq, 1, 1010000) == 1 && level(&sq, 1, 1060000) == -1, "square");
    ff_effect tri = make(FF_TRIANGLE); tri.magnitude = 1; tri.period_us = 100000;
    CHECK(NEAR(level(&tri, 1, 1000000), -1) && NEAR(level(&tri, 1, 1050000), 1) &&
          NEAR(level(&tri, 1, 1025000), 0), "triangle");
    ff_effect up = make(FF_SAW_UP); up.magnitude = 1; up.period_us = 100000;
    ff_effect down = make(FF_SAW_DOWN); down.magnitude = 1; down.period_us = 100000;
    CHECK(NEAR(level(&up, 1, 1075000), 0.5) && NEAR(level(&down, 1, 1075000), -0.5), "sawtooth");

    /* spring and damper go to the base's slots, not into the level */
    ff_effect cond[3];
    cond[0] = make(FF_SPRING);
    cond[0].cond = (ff_condition){0.1, 0.05, 0.6, 0.4, 0.5, 0.3};
    cond[0].gain = 0.5;
    cond[1] = make(FF_DAMPER);
    cond[1].cond = (ff_condition){0, 0, 0.3, 0.3, 1, 1};
    cond[2] = make(FF_SPRING);
    cond[2].cond = (ff_condition){0.9, 0.9, 0.2, 0.2, 0.2, 0.2};
    ff_render(cond, 3, 1, 2000000, &o);
    CHECK(o.level == 0, "conditions give no level");
    CHECK(NEAR(o.spring.offset, 0.1) && NEAR(o.spring.deadband, 0.05), "spring centre from the first");
    CHECK(NEAR(o.spring.pos_coeff, 0.5) && NEAR(o.spring.neg_coeff, 0.4), "spring coefficients add up");
    CHECK(NEAR(o.spring.saturation, 0.45), "spring saturation, larger side, adds up");
    CHECK(NEAR(o.damper.pos_coeff, 0.3) && NEAR(o.damper.saturation, 1), "damper");
    cond[1].playing = 0;
    ff_render(cond, 2, 1, 2000000, &o);
    CHECK(o.damper.saturation == 0, "damper stopped = slot off");

    /* packet */
    uint8_t p[FMFF_SIZE];
    ff_output po = {0.5, {0.1, 0.05, 0.6, -0.4, 0.25}, {0, 0, 0.3, 0.3, 1}};
    fmff_write(p, 0x01020304, &po, 1);
    CHECK(memcmp(p, "FMFF", 4) == 0 && p[4] == 1 && p[5] == 1 && p[6] == 0 && p[7] == 0, "packet header");
    CHECK(p[8] == 4 && p[9] == 3 && p[10] == 2 && p[11] == 1, "packet sequence little-endian");
    CHECK(p[12] == 0 && p[13] == 0 && p[14] == 0 && p[15] == 0x3F, "packet level 0.5f");
    CHECK(f32_at(p + 16) == 0.1f && f32_at(p + 20) == 0.05f && f32_at(p + 24) == 0.6f &&
          f32_at(p + 28) == -0.4f && f32_at(p + 32) == 0.25f, "packet spring");
    CHECK(f32_at(p + 44) == 0.3f && f32_at(p + 52) == 1.0f, "packet damper");
    fmff_write(p, 0, &(ff_output){0}, 0);
    CHECK(p[5] == 0, "release flag");

    printf("%d/%d checks passed\n", count - failures, count);
    return failures != 0;
}
