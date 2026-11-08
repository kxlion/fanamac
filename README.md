# FanaMac

A native macOS app for Fanatec wheelbases. It tunes the base and brings force feedback to games on the Mac, with no driver to install. The goal is to cover every Fanatec base, and the CSL DD is the first one supported.

![FanaMac](assets/fanamac.jpeg)

FanaMac is an independent project, not affiliated with or endorsed by Fanatec.

> **Safety.** A direct drive base is strong enough to injure. FanaMac doesn't limit the force. It cuts it only on a normal quit, on a USB write error, and when force packets stop for 0.25 s. A hung game or a FanaMac crash can leave a force on. Keep the base's power within reach, and use this at your own risk.

## Features

| Feature | What it does |
|---|---|
| Tuning | Every Tuning Menu setting: setups 1 to 5 read and written, Auto Setup shown only |
| Standard / Advanced | Follows the wheel's menu and can switch it, after asking for confirmation |
| Game presets | Fanatec's recommended settings per game |
| Export / Import | One setup per JSON file |
| Live inputs | Wheel angle, pedals, handbrake, shifter, buttons and rim |
| Force feedback | CrossOver games through a plug-in inside the app. Native Mac games untested |
| Calibration | Wheel centre and H-pattern shifter |
| Mouse emulation | The rim's joystick moves the cursor, button 26 clicks |

## Compared with the Fanatec App

| Function | Fanatec App | FanaMac |
|---|---|---|
| Tuning Menu, 5 setups | Yes | Yes |
| Standard / Advanced menu | Yes | Yes |
| Recommended settings per game | Yes | Yes |
| Profile export and import | Yes | Yes |
| Force feedback in games | Yes | Yes |
| Centre calibration | Yes | Yes |
| Shifter calibration | Yes | Yes |
| Reset of all setups | Yes | Yes |
| Mouse emulation | Yes | Yes |
| Profile per game and car, applied when the game starts | Yes | No |
| Motor sensor calibration | Yes | No |
| Pedal and handbrake calibration, curves | Yes | No |
| FullForce effects | Yes | No |
| Game telemetry | Yes | No |
| Rev lights and button colours | Yes | No |
| Wheel display (gear, speed, pages) | Yes | No |
| Rim vibration motors | Yes | No |
| Firmware updates | Yes | No |
| Online services | Yes | No |

## Tested with

| Item | Tested on |
|---|---|
| Base | CSL DD, PC mode (red LED) |
| Rim | ClubSport Steering Wheel RS |
| Shifter | ClubSport Shifter SQ V1.5 |
| System | macOS 26 on Apple silicon |
| Games, through CrossOver | Assetto Corsa Competizione, DiRT Rally 2.0 |

Mouse emulation's joystick and button are only known for the RS rim.

## Build

You need an Apple silicon Mac on macOS 14 or later, and the Xcode Command Line Tools with a macOS 26 SDK.

Build the plug-in first: without it, the app still builds but has no force feedback. From the repository root:

```bash
ffplugin/build.sh
app/build.sh
open app/build/FanaMac.app
```

| Command | Result |
|---|---|
| `app/build.sh` | Builds `app/build/FanaMac.app`. Refuses to run while FanaMac is open |
| `app/build.sh test` | Runs the tests, no hardware needed |
| `app/build.sh cli` | Builds the development tool, `app/build/fanamac` |

## Use

| Step | Action |
|---|---|
| 1 | Turn the base on in PC mode (red LED) |
| 2 | Open FanaMac **before** starting CrossOver or a game |
| 3 | Pick a setup, adjust the settings and click **Send** |
| 4 | Start your game and leave FanaMac open |

Quit Wine completely before you rebuild or update FanaMac.

### Mouse emulation

macOS asks for the Accessibility permission the first time. Allow FanaMac in System Settings > Privacy & Security > Accessibility, then turn Mouse Emulation on again.

It stays active during games so you can use their menus. Turn it off before driving.

Each build needs the permission again, because the app is ad-hoc signed. Clear the old entry, then allow it again:

```bash
tccutil reset Accessibility app.fanamac.FanaMac
```

## How force feedback works

| Step | Component |
|---|---|
| 1 | The game, unchanged, through Wine DirectInput and SDL2 under CrossOver |
| 2 | `ForceFeedback.framework`, which loads FanaMac's plug-in |
| 3 | `FanaMacFF.plugin` computes the effects and sends them over UDP on `127.0.0.1:9310` |
| 4 | FanaMac turns them into USB frames for the base |

Nothing is installed in the system or in the CrossOver bottle, and games are not modified.

## Project layout

| Path | Content |
|---|---|
| `app/Sources/FanaMacCore` | Protocol frames and state, no hardware access |
| `app/Sources/FanaMac` | USB access and the SwiftUI interface |
| `app/Sources/FanaMacCLI` | Development tool |
| `app/Tests` | Tests that need no hardware |
| `app/Presets` | Game presets |
| [`app/docs/PROTOCOL.md`](app/docs/PROTOCOL.md) | Every USB command seen so far |
| [`app/docs/PRESETS.md`](app/docs/PRESETS.md) | Format of the game presets |
| `ffplugin/` | Force feedback plug-in, in C |

## Licence

MIT, see [`LICENSE`](LICENSE). `app/Presets/fanatec_recommended.json` contains values and notes from Fanatec and is not covered by the MIT licence.

Fanatec and CSL DD are trademarks of their owner.
