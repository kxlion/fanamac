# Game presets

`app/Presets/fanatec_recommended.json` holds Fanatec's recommended settings for each game and each base. They are the values the Fanatec App shows under "Recommended Settings".

**Source:** Fanatec App 1.6.1.3.

The fields of this file:

- `tuning`: Tuning Menu values in FanaMac's units (SEN 0 = Auto, FFS 1 = Peak / 0 = Linear, Off = 0).
- `userPreference`: settings Fanatec leaves to the driver. Loading a preset keeps them as they are, along with everything it doesn't list (e.g. FUL).
- `otherSettings`: lines for settings FanaMac doesn't have (ABS, DRI on belt-driven bases).
- `inGame` and `notes`: the game's own settings and Fanatec's footnotes, as written.
