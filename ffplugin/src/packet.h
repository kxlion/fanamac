/* FanaMac force packet: what the macOS plug-in sends to FanaMac.
 *
 * One UDP datagram to 127.0.0.1:9310, 56 bytes, little-endian:
 *
 *   0  char[4]  "FMFF"
 *   4  u8       version (1)
 *   5  u8       flags   (bit 0: the game asked for a force; 0 = release)
 *   6  u16      reserved, 0
 *   8  u32      sequence number, +1 per packet
 *  12  f32      level, -1 ... +1, positive turns the wheel clockwise
 *  16  slot     spring, played by the base
 *  36  slot     damper, played by the base
 *
 * A slot is five f32: offset (-1 ... +1, the whole wheel travel), deadband
 * (each side of the offset, same units), positive and negative coefficients
 * (-1 ... +1, positive side = clockwise), saturation (0 ... 1, 0 = off).
 *
 * The plug-in sends a packet each time something changes, every 2 ms while a
 * force moves by itself (vibration, ramp, envelope), and at least every 20 ms
 * while the game runs. FanaMac cuts everything when packets stop for 0.25 s.
 * The plug-in's own thread keeps sending while an effect plays, so a hung game
 * can keep its force.
 *
 * MIT licence, FanaMac.
 */
#ifndef FANAMAC_PACKET_H
#define FANAMAC_PACKET_H

#include <stdint.h>
#include <string.h>

#include "ffcalc.h"

#define FMFF_PORT 9310
#define FMFF_VERSION 1
#define FMFF_SIZE 56
#define FMFF_FLAG_ACTIVE 0x01

static inline void fmff_f32(uint8_t *out, double v)
{
    float f = (float)v;
    uint32_t bits;
    memcpy(&bits, &f, 4);
    for (int i = 0; i < 4; i++) out[i] = (uint8_t)(bits >> (8 * i));
}

static inline void fmff_slot(uint8_t *out, const ff_slot *s)
{
    fmff_f32(out, s->offset);
    fmff_f32(out + 4, s->deadband);
    fmff_f32(out + 8, s->pos_coeff);
    fmff_f32(out + 12, s->neg_coeff);
    fmff_f32(out + 16, s->saturation);
}

static inline void fmff_write(uint8_t out[FMFF_SIZE], uint32_t seq, const ff_output *o, int active)
{
    memcpy(out, "FMFF", 4);
    out[4] = FMFF_VERSION;
    out[5] = active ? FMFF_FLAG_ACTIVE : 0;
    out[6] = out[7] = 0;
    for (int i = 0; i < 4; i++) out[8 + i] = (uint8_t)(seq >> (8 * i));
    fmff_f32(out + 12, o->level);
    fmff_slot(out + 16, &o->spring);
    fmff_slot(out + 36, &o->damper);
}

#endif
