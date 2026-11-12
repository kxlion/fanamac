# Fanatec CSL DD USB protocol

Every Fanatec USB command seen so far, whether FanaMac uses it or not, and the reports the base sends. Unofficial, and possibly wrong.

> **Warning.** A direct drive base can move with enough force to injure. A wrong command can erase what the base has stored, and some commands below can leave it unusable. Use this at your own risk.

## Legend

| Status | Meaning |
|---|---|
| **Tested** | Sent to a real CSL DD, result observed |
| **Not sent** | Read from a source, never sent to a base. It may not work, and it may not be safe |

| Source | Meaning |
|---|---|
| **Public** | Already publicly known |
| **SDK** | Static reading of the Fanatec App 1.6.1.3 files. Nothing was run |
| **Measured** | Observed on a CSL DD with a ClubSport Steering Wheel RS and a ClubSport Shifter SQ V1.5 |

| Notation | Meaning |
|---|---|
| Hexadecimal | All bytes. Byte 0 is the report ID |
| `x` | A value |
| Short frame | Report `01`, 8 bytes, zero padded |
| Long frame | Report `FF`, 64 bytes, zero padded |
| Report ID `01` on **Not sent** short frames | Assumed, as for the tested ones |

## USB identity

| Device | Vendor | Product | HID usage carrying the reports |
|---|---|---|---|
| CSL DD, PC mode (red LED) | `0EB7` | `0020` | `04` / `05` |
| CSL DD, compatibility mode (yellow LED) | `0EB7` | `0004` | Seen as a ClubSport V2.5: untested, see [BASES.md](BASES.md) |
| ClubSport Shifter SQ V1.5 on its USB adapter | `0EB7` | `1A92` | |

The product IDs of the other Fanatec devices are in [DEVICES.md](DEVICES.md).

## All commands

| Group | Function | Frame | Source | Status | Notes |
|---|---|---|---|---|---|
| Start-up | Handshake | `01 F5` | Public | Tested | Sent when the base is opened |
| Start-up | Start-up sequence 1 | `01 F8 09 01 06 FF 01` | Public | Not sent | Meaning undocumented. FanaMac works without it |
| Start-up | Start-up sequence 2 | `01 F8 09 01 06 FF 00` | Public | Not sent | Same |
| Start-up | Start-up sequence 3 | `01 F8 09 01 06 FF 04` | Public | Not sent | Same |
| Start-up | Start-up sequence 4 | `01 F8 09 01 05 00` | Public | Not sent | Same |
| Tuning | Read the active setup | `FF 03 02` | Public | Tested | The base answers with a tuning report |
| Tuning | Write the active setup | `FF 03 00 <setup code> <registers>` | Public | Tested | See "Tuning report and registers" |
| Tuning | Select a setup | `FF 03 01 <code>` | Public | Tested | Code 1 = Auto Setup, 2 to 6 = setups 1 to 5 |
| Tuning | Switch Standard / Advanced menu | `FF 03 06` | SDK | Tested | **Going to Standard can erase setups** |
| Tuning | Reset all setups | `FF 03 04` | SDK | Tested | Erases every setup, leaves the base in the Standard menu |
| Tuning | Save tuning data | `FF 03 03` | SDK | Not sent | |
| Force | Constant force | `01 01 08 <lo> <hi> 00 00 01` | Public | Tested | Slot 0 |
| Force | Constant force, 8-bit | `01 01 08 <x>` | Public | Not sent | For bases without the 16-bit format. Centred on `80` |
| Force | Constant force off | `01 03 08` | Public | Tested | |
| Force | Spring | `01 11 0B <left> <right> <k> 00 <sat>` | Public | Tested | Slot 1 |
| Force | Spring off | `01 13 0B` | Public | Tested | |
| Force | Damper | `01 21 0C <k left> 00 <k right> 00 <sat>` | Public | Tested | Slot 2 |
| Force | Damper off | `01 23 0C 00 00 00 00 FF` | Public | Tested | |
| Force | Inertia | `01 31 0C <k left> 00 <k right> 00 <sat>` | Public | Not sent | Slot 3. Fanatec's driver doesn't offer it to games |
| Force | Friction | `01 41 0C <k left> 00 <k right> 00 <sat>` | Public | Not sent | Slot 4. Fanatec's driver doesn't offer it to games |
| Force | Stop all forces | `01 F3` | Public | Tested | |
| Force | Stop effects | `FF 0A 01 1A` | SDK | Not sent | |
| Force | Force feedback without a rim | `01 FA x` | SDK | Not sent | |
| Calibration | Center | `01 F9 05` | SDK | Tested | The current position becomes the centre. No reply. Checked in a game |
| Calibration | Shifter, start | `01 F8 09 01 19 01` | SDK | Tested | H-pattern shifter on the base only |
| Calibration | Shifter, next | `01 F8 09 01 19 02` | SDK | Tested | Once per position, nine times |
| Calibration | Motor sensor (likely) | `01 F9 04 AA AA AA AA AA` | SDK | Not sent | **Could erase a calibration.** Function not confirmed |
| Calibration | Motor sensor (likely) | `01 F9 04 BB BB BB BB BB` | SDK | Not sent | **Could erase a calibration.** Function not confirmed |
| Wheel | Set wheel angle | `01 F8 81 x x` | SDK | Not sent | |
| Wheel | MPS function | `01 F8 09 01 16 x` | SDK | Not sent | |
| Wheel | Clutch bite point | `01 F8 09 01 17 01 x` | SDK | Not sent | |
| Wheel | Rev stripe on/off | `01 F8 09 06 x` | SDK | Not sent | `x` is inverted |
| Wheel | OLED pixel test | `01 F8 09 01 50 x` | SDK | Not sent | |
| Base | Compatibility mode | `01 F8 09 05 x` | SDK | Not sent | |
| Base | Trigger a USB report | `01 F8 09 01 06 x x` | SDK | Not sent | |
| Base | Operating hours report, enable | `FF 07 01 x` | SDK | Not sent | |
| Base | Operating hours report, trigger | `FF 07 02` | SDK | Not sent | |
| Base | System report, enable | `FF 08 01 x` | SDK | Not sent | |
| Base | System report, trigger | `FF 08 02` | SDK | Not sent | |
| Firmware | USB CDC mode | `01 F8 09 01 FE x` | SDK | Not sent | Part of the firmware update path |
| Firmware | **Bootloader mode** | `01 F8 09 01 FF` | SDK | Not sent | **Never send: it puts the base in bootloader mode** |

## Force values

| Field | Range | Meaning |
|---|---|---|
| `<lo> <hi>` | `0001` to `FFFF`, little-endian | Centred on `8000`. Below turns the wheel clockwise, above anti-clockwise |
| Last byte of constant force | `01` | Selects the 16-bit format |
| First data byte | `(slot << 4) \| 01` | Add `02` to turn the slot off |
| `<left>`, `<right>` | `00` to `FF` | Edges of the spring's dead zone over the wheel's travel. `80` is the centre |
| Spring `<k>` | Two 4-bit values | Clockwise side in the high 4 bits. 0 to `F` each |
| Damper `<k left>`, `<k right>` | 0 to `F` | Reported: oscillation on a direct drive when the two `00` bytes are non-zero |
| `<sat>` | `00` to `FF` | Top force. 0 turns a slot off |

## Tuning report and registers

| Item | Value |
|---|---|
| Report | `FF 03 …`, 64 bytes |
| Sent by the base | When asked, when a setting changes on the wheel, after each write |
| Byte 2 | Setup byte: bit `80` = Standard menu, other bits = setup code |
| Register position in a report | At its address |
| Write frame | `FF 03 00`, then bytes 2 to 62 of the report, so a register sits at address + 1 |
| Bit `80` in a write | Must be cleared, otherwise the write has no effect |
| FanaMac's write sequence | Select, read, replace the changed values, write, read again. Unknown bytes keep the base's values |

| Address | Wheel label | Setting | Raw value |
|---|---|---|---|
| `02` | | Setup byte | See above |
| `03` | SEN | Steering angle | Degrees / 10 − 127, modulo 256. 90° = `8A`, 2520° = `7D`, Auto (2530°) = `7E` |
| `04` | FFB | Force feedback | 0 to 100 |
| `05` | SHO | Wheel vibration | Percent / 10 |
| `06` | BLI | Brake level indicator | 0 to 100, 101 = off |
| `07` | FFS | FFB scaling | 0 = Linear, 1 = Peak |
| `0A` | FOR | Game force effect | Percent / 10 |
| `0B` | SPR | Game spring effect | Percent / 10 |
| `0C` | DPR | Game damper effect | Percent / 10 |
| `0D` | NDP | Natural damper | 0 to 100 |
| `0E` | NFR | Natural friction | 0 to 100 |
| `0F` | BRF | Brake force, second copy | The wheel only changes `10`. FanaMac writes both |
| `10` | BRF | Brake force | 0 to 100 |
| `11` | FEI | Force effect intensity | 0 to 100 |
| `14` | INT | Interpolation filter | 0 to 20 |
| `15` | NIN | Natural inertia | 0 to 100 |
| `16` | FUL | FullForce | 0 to 100 |

## Input report

| Bytes | Content |
|---|---|
| 0 | Report ID `01` (34 bytes, sent only when something changes) |
| 1 to 16 | 4-bit hat (0 to 7, otherwise centred), then button bits, lowest bit first |
| 17 to 24 | X, Z, Rz, Y, unsigned 16-bit little-endian |
| 25, 26 | Rx, Ry, signed 8-bit |
| 27 | Slider, unsigned 8-bit |
| 28 | Dial, signed 8-bit |
| 29 to 33 | Vendor bytes |

| Input | Where | Notes |
|---|---|---|
| Wheel | X | Scale follows SEN. In Auto the axis spans 1080° |
| Throttle | Z | 65535 at rest, lower when pressed |
| Brake | Rz | Same |
| Clutch | Y | Same |
| Handbrake | Slider | Range varies |
| Rim joystick (RS) | Rx, Ry | −128 to 127. Up = Ry −128, left = Rx 127. Rest: Rx −1, Ry 0 |
| Button 26 (RS) | Buttons | Held for as long as it's pressed |
| Sequential shifter | Buttons 29, 30 | Up, down |
| H-pattern shifter | Buttons 13 to 20 | R, then 1st to 7th, once calibrated |
| Vendor byte 1 | Byte 29 | `04` = shifter in H mode, `05` = sequential |
| Vendor byte 2 | Byte 30 | Rim, see below |
| Report `02` | Declared, 12 more axes | Never seen. Hidden by FanaMac's plug-in, or CrossOver games lose the brake and handbrake |

| Rim code | Rim | Checked |
|---|---|---|
| `0A` | ClubSport Steering Wheel Formula V2 / V2.5 | No |
| `0D` | Podium Button Module Endurance | No |
| `0E` | CSL Elite Steering Wheel WRC | No |
| `0F` | Podium Steering Wheel Bentley GT3 | No |
| `10` | Podium Steering Wheel BMW M4 GT3 | No |
| `11` | Podium Steering Wheel DD GT | No |
| `12` | CSL Steering Wheel Universal Hub | No |
| `13` | ClubSport Steering Wheel BMW V2 | No |
| `14` | ClubSport Steering Wheel RS | Yes |
| `15` | ClubSport Universal Hub V2 | No |
| `16` | ClubSport Steering Wheel F1 Esports V2 | No |
| `17` | Podium Steering Wheel DD GT X | No |
| `18` | CSL Elite Steering Wheel McLaren GT3 V2 | No |
