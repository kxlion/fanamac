# Fanatec USB devices

Every Fanatec product ID known to FanaMac, and what FanaMac does with each. The vendor ID is always `0EB7`.

The IDs and names come from the Linux driver [hid-fanatecff](https://github.com/gotzl/hid-fanatecff) and from the files of Fanatec's Windows driver. Only the CSL DD was seen on real hardware. Each table says how sure a line is:

| Mark | Meaning |
|---|---|
| Seen | Observed on the real device with FanaMac |
| Named | The ID and the name are written together in Fanatec's driver files |
| Deduced | Fanatec's software handles the ID, the name is our reading of it |

## Bases in PC mode

These have a profile in `app/Sources/FanaMacCore/Bases.swift`. What a profile allows is in [BASES.md](BASES.md).

| Product ID | Base | Maximum angle | How sure |
|---|---|---|---|
| `0020` | CSL DD, and probably the whole generation: see below | 2520° | Seen (CSL DD) |
| `0006` | Podium DD1 | 2520° | Named |
| `0007` | Podium DD2 | 2520° | Named |
| `0E03` | CSL Elite | 1080° | Named |
| `0005` | CSL Elite PS4 | 1080° | Named |
| `0004` | ClubSport V2.5, and the compatibility mode of direct drive bases (CSL DD: yellow LED) | 900° | Named |
| `0001` | ClubSport V2 | 900° | Named |
| `038E` | ClubSport V1 | 900° | Named |
| `0011` | CSR Elite | 900° | Named |
| `0197` | Porsche wheels (911 Carrera, GT3 RS, Turbo S, GT2) | 900° | Named |

Known to Fanatec's software, without a profile in FanaMac:

| Product ID | What it is | How sure |
|---|---|---|
| `0002`, `0003` | CSL Elite, other variants | Deduced |
| `0008`–`000C` | Handled exactly like `0004` | Deduced |
| `0021`–`002F` | Accepted as bases of the CSL DD generation, no name | Deduced |
| `0F00`–`0FEF` | Accepted as bases, grouped by tens per model. Which mode this is isn't known | Deduced |

## One ID for the whole CSL DD generation

Fanatec's Windows driver has a single PC-mode product ID, `0020`, for the CSL DD, GT DD Pro, ClubSport DD, ClubSport DD+ and Podium DD. It tells them apart with a **base type** that the base sends in a report:

| Base type | Base |
|---|---|
| 1 | ClubSport V2 |
| 2 | ClubSport V2.5 |
| 3, 4 | CSL Elite 1.0, 1.1 |
| 5 | CSL Elite PS4 |
| 6 | Podium DD1 |
| 7 | Podium DD1 PS4 |
| 8 | Podium DD2 |
| 9 | GT DD Pro |
| 10 | CSL DD |
| 11 | ClubSport DD |
| 12 | ClubSport DD+ |
| 13, 14 | Podium DD, Podium DD+ |
| 15, 16 | "Miata" base, and its PlayStation version |

> **Warning.** FanaMac doesn't read the base type yet: which byte of which report carries it is not known. A ClubSport DD or DD+ may therefore show up as `0020` and be taken for the tested CSL DD, with no force cap, on a stronger base.

What would settle it: a diagnostic (Help > Save Diagnostic) from a base of this generation that isn't a CSL DD. Compared with a CSL DD's, the byte that differs and holds one of the values above is the base type. `BaseProfile` would then need a base type next to the product ID.

## Bases in PlayStation mode

FanaMac recognises these to say that the base has to be switched to PC mode. It never writes to them.

| Product ID | Base | How sure |
|---|---|---|
| `0E04` | CSL Elite PS4 | Deduced |
| `0E05`, `0E06` | Podium DD | Deduced |
| `0E07` | GT DD Pro | Deduced |
| `0E08`, `0E09` | Newer bases | Deduced |

## Pedals, shifter and handbrake

Recognised so they are never taken for a base. FanaMac reads them and never writes to them.

| Product ID | Device | How sure |
|---|---|---|
| `1839` | ClubSport Pedals | Named |
| `183B` | ClubSport Pedals V3 | Named |
| `6204` | CSL Elite Pedals | Named |
| `6205` | CSL Pedals LC | Named |
| `6206` | CSL Elite Pedals V2 | Named |
| `6207` | Pedals, model unknown | Deduced |
| `1A92` | ClubSport USB adapter with a shifter | Seen |
| `1A93` | ClubSport USB adapter with a handbrake | Named |
| `1A95` | ClubSport USB adapter with pedals | Deduced |
| `6E00`–`6E02` | Pedals, no profile in FanaMac | Deduced |
| `6E03`–`6E05` | Shifter, no profile in FanaMac | Deduced |
| `6E06`–`6E08` | Handbrake, no profile in FanaMac | Deduced |

## Firmware update modes

A device shows one of these IDs while its firmware is being replaced. FanaMac has no profile for them and must never get one: a write at that moment can leave the device unusable.

| Product ID | Device | How sure |
|---|---|---|
| `02C9`, `02CA`, `0714` | ClubSport V1, V2, V2.5 | Named |
| `02CD` | CSL Elite | Named |
| `0704`, `0706`, `0707`, `0720` | CSL Elite PS4, Podium DD1, Podium DD2, CSL DD | Deduced |
| `0718` | A base's motor | Named |
| `02BD`, `1A2F`, `6274` | ClubSport Pedals, ClubSport Pedals V3, CSL Elite Pedals | Named |
| `1A2E` | ClubSport USB adapter | Named |
| `02C0` | Porsche wheels | Named |

## Still unknown

| Question | What would answer it |
|---|---|
| Which byte carries the base type | A diagnostic from a GT DD Pro, ClubSport DD, ClubSport DD+ or Podium DD |
| Whether those bases use `0020` or one of `0021`–`002F` | The same diagnostic |
| Which Tuning Menu settings each base has | A diagnostic from each base |
| What the `0F00`–`0FEF` IDs are | Unknown |
