# Supporting another Fanatec base

FanaMac was written and tested on a CSL DD. Every other base is supported from data: a profile says what the base can do, and a diagnostic sent by someone who owns the base says whether the profile is right.

> **Warning.** A direct drive base can move with enough force to injure. An untested base stays read-only until its driver turns Experimental Mode on, and its force stays capped at 25 %.

## The three levels

| Level | Which bases | What FanaMac does |
|---|---|---|
| Tested | CSL DD | Everything |
| Untested | A base with a profile that nobody confirmed | Shows inputs and reads the active setup. Writes and force feedback only with Experimental Mode, force capped at 25 % |
| Unknown | A Fanatec product without a profile | Nothing. It can only be captured in a diagnostic |

## Built-in profiles

Product IDs, force format, Tuning Menu and maximum angle of the untested bases come from the Linux driver [hid-fanatecff](https://github.com/gotzl/hid-fanatecff). Product IDs and names were checked against the files of Fanatec's Windows driver. The list is in `app/Sources/FanaMacCore/Bases.swift`.

| Product ID | Base | Status | Constant force | Tuning Menu over USB | Maximum angle |
|---|---|---|---|---|---|
| `0020` | CSL DD | Tested | 16-bit | Yes | 2520° |
| `0006` | Podium DD1 | Untested | 16-bit | Yes | 2520° |
| `0007` | Podium DD2 | Untested | 16-bit | Yes | 2520° |
| `0E03` | CSL Elite | Untested | 16-bit | Yes | 1080° |
| `0005` | CSL Elite PS4 | Untested | 16-bit | Yes | 1080° |
| `0004` | ClubSport V2.5 | Untested | 8-bit | No | 900° |
| `0001` | ClubSport V2 | Untested | 8-bit | No | 900° |
| `038E` | ClubSport V1 | Untested | 8-bit | No | 900° |
| `0011` | CSR Elite | Untested | 8-bit | No | 900° |
| `0197` | Porsche 911 | Untested | 8-bit | No | 900° |

Not known yet: which Tuning Menu settings each untested base has, and whether their input report has the CSL DD's layout. A diagnostic answers both.

### Newer bases: ClubSport DD, ClubSport DD+, GT DD Pro, Podium DD

> **Warning.** Fanatec's Windows driver gives this whole generation the CSL DD's product ID, `0020`. One of these bases may therefore be taken for the tested CSL DD, with no force cap, on a stronger base. If you own one, set the game's force feedback very low first, and send a diagnostic: it is what will let FanaMac tell the bases apart.

Every other product ID FanaMac knows (PlayStation mode, pedals, shifter, handbrake, firmware update modes) and how the bases of this generation differ are in [DEVICES.md](DEVICES.md).

## If you own the base: send a diagnostic

1. Plug the base in and turn it on in PC mode.
2. In FanaMac, choose Help > Save Diagnostic.
3. During the 10 seconds, turn the wheel lock to lock, press each pedal fully and press a few buttons.
4. Attach the file to an issue on FanaMac's GitHub page, with the name of the base, rim and pedals.

| In the file | Not in the file |
|---|---|
| Product ID, product name and firmware version of each Fanatec device | Serial numbers |
| The HID descriptor of each device | Anything about the Mac except the macOS version |
| The base's tuning report (the active setup) | |
| For each input report: the first one, and the lowest and highest value of each byte | |

A capture writes nothing to a device, with one exception: a base whose profile has the Tuning Menu gets the handshake `01 F5` and the read request `FF 03 02`, the two frames FanaMac sends on every connection. A product without a profile is only listened to.

The same capture from the command line:

```bash
app/build/fanamac diagnose my-base.json
```

`--ask-tuning` also sends the two frames to a product without a profile.

## If you maintain FanaMac: ingest a diagnostic

Run it from the `app` folder:

```bash
build/fanamac ingest my-base.json
```

It reads the capture with FanaMac's own decoders and prints what it found. Lines starting with `!` are what doesn't match:

| Check | What a `!` means |
|---|---|
| HID descriptor against the tested bases' fixtures | The input layout (axes, buttons) may differ: compare the bytes that moved |
| Input report `01` | Missing, shorter than 34 bytes, or bytes moving past what FanaMac decodes |
| Each tuning register against its range | Another encoding, or a setting this base doesn't have: leave it out of the profile's `params` |
| Steering angle against the profile's maximum | Wrong `maxAngle` |
| Sending the setup back unchanged | FanaMac would change a byte the driver didn't touch |
| Tuning report against the profile's `tuningMenu` | Wrong `tuningMenu` |

For a product without a profile it also prints a cautious one to try.

Then keep the capture as a test:

```bash
build/fanamac ingest my-base.json --add
```

It is copied to `app/Tests/Fixtures`, and `./build.sh test` replays every file there. A capture of a tested base must raise no `!`.

## Profile files

A profile is a JSON file. FanaMac loads every `*.json` in `~/Library/Application Support/FanaMac/Bases` when it starts, so an owner can try a profile without a new build.

```json
{
  "productID": "0006",
  "name": "Podium DD1",
  "presetBase": "PDD1",
  "highResForce": true,
  "tuningMenu": true,
  "maxAngle": 2520,
  "params": ["FF", "SEN", "FFS", "NDP", "NFR", "NIN", "INT", "FEI", "FOR", "SPR", "DPR", "SHO", "BLI", "BRF"]
}
```

| Field | Meaning |
|---|---|
| `productID` | USB product ID, four hex digits |
| `name` | Shown in the window's header |
| `presetBase` | The base's name in Fanatec's recommended settings, optional |
| `highResForce` | `true`: 16-bit constant force. `false`: the 8-bit frame, which every base reads |
| `tuningMenu` | The base answers `FF 03 02` |
| `maxAngle` | Largest steering angle, 90 to 2520 |
| `params` | Settings the base's Tuning Menu has. Left out: all of them. A setting not listed is never shown or written |

A profile file is always untested, and it can't replace the profile of a tested base.

## Making a base tested

A base becomes `tested` in `Bases.swift` once an owner has confirmed, in Experimental Mode:

1. Inputs: wheel, each pedal, buttons and rim show correctly.
2. Settings: a value sent from FanaMac shows on the wheel's Tuning Menu, and the other way round.
3. Force: `fanamac force --send` turns the wheel clockwise first, then back.
4. A game's force feedback works.

Its diagnostic stays in `app/Tests/Fixtures`.
