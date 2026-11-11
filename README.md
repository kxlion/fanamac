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

## Install

You need:

- an Apple silicon Mac on macOS 14 or later
- a CSL DD connected by USB
- [CrossOver](https://www.codeweavers.com/crossover), the app that runs Windows games on a Mac, with your game installed in it

1. Download `FanaMac-x.y.dmg` from the [latest release](https://github.com/kxlion/fanamac/releases/latest).
2. Open it and drag FanaMac onto the Applications folder.
3. Open FanaMac from Applications. macOS refuses the first time, because FanaMac isn't signed with a paid Apple developer certificate: click **Done**.
4. Go to System Settings > Privacy & Security, scroll down to the message about FanaMac and click **Open Anyway**. This is only needed once per version.

If you'd rather skip steps 3 and 4, run this in Terminal after step 2:

```bash
xattr -dr com.apple.quarantine /Applications/FanaMac.app
```

Run FanaMac from Applications, not from the downloaded disk image. To build it yourself instead, see [For developers](#for-developers).

## Play with force feedback

Follow this order every time. If CrossOver starts before FanaMac, the game gets no force feedback, brake or handbrake.

1. Quit your game, Steam and CrossOver completely.
2. Turn the base on in PC mode (red LED).
3. Open FanaMac. At the top right, it must show **Connected** with a green dot.
4. Start CrossOver, then your game.
5. In the game's settings, assign the wheel and pedals and turn force feedback on.
6. Set the game's force feedback low for the first run, then raise it.
7. Leave FanaMac open while you play. A **Game** badge appears next to **Connected** when the game sends forces.

If you'd rather not think about the order, add FanaMac under System Settings > General > Login Items: it then opens with your session, before CrossOver.

Controls you set up before using FanaMac may no longer match: set them up again. In Assetto Corsa Competizione, the default Fanatec controls work and only the clutch has to be added by hand.

To change the base's settings, pick a setup in FanaMac, adjust it and click **Send**.

### If it doesn't work

| What you see | What to do |
|---|---|
| Orange dot, no force, or no brake and handbrake in the game | CrossOver was already running. Quit it completely, wait for the dot to turn green, then start it again |
| The dot stays orange after quitting | Part of CrossOver is still running, often `steamwebhelper`. Quit it in Activity Monitor |
| **Not connected** | Check the USB cable, and that the base is on in PC mode |
| Green dot but no force | Check that force feedback is on in the game and that the wheel is assigned there |

## Update

Quit FanaMac, your game, Steam and CrossOver. Download the new `.dmg` from the [latest release](https://github.com/kxlion/fanamac/releases/latest), drag FanaMac onto Applications and choose **Replace**. Then open it as in steps 3 and 4 of [Install](#install).

Your setups are kept. Mouse Emulation has to be allowed again after each update: see below.

## Mouse emulation

macOS asks for the Accessibility permission the first time. Allow FanaMac in System Settings > Privacy & Security > Accessibility, then turn Mouse Emulation on again.

It stays active during games so you can use their menus. Turn it off before driving.

After each update, macOS no longer recognises FanaMac. Run this in Terminal, then allow FanaMac again as above:

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

## For developers

| Command | Result |
|---|---|
| `app/build.sh test` | Runs the app's tests, no hardware needed |
| `ffplugin/build.sh test` | Runs the force calculation tests |
| `app/build.sh cli` | Builds the development tool, `app/build/fanamac` |

To build from source, install Apple's developer tools with `xcode-select --install`, then:

```bash
git clone https://github.com/kxlion/fanamac.git && cd fanamac && app/build.sh
```

| Command | Result |
|---|---|
| `app/build.sh` | Builds `app/build/FanaMac.app`, force feedback plug-in included |
| `./release.sh` | Builds the app, then the release disk image `build/FanaMac-<version>.dmg` |

Builds use the macOS 26 SDK from the Xcode Command Line Tools. `app/build.sh` refuses to run while FanaMac is open.

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
