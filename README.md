# ForeverRank

ForeverRank compares the mana efficiency of learned spell ranks in **WoW: Forever**. It adds healing per mana (HPM), damage per mana (DPM), estimated output, and output per cast second to supported spell tooltips out of combat.

Calculations start with your live tooltip totals, which already include gear, talents, and rank scaling. ForeverRank does not add spell power or apply generic Classic coefficients a second time. The tooltip's **Tooltip** value shows efficiency before optional crit estimation; it is not an unscaled spell baseline.

## Rank comparisons and badges

The addon compares supported ranks in your learned spellbook. Hovering an unlearned spell does not add it to the comparison. It refreshes after gear, spellbook, player stat, aura, and talent changes. Tooltip calculations and badge refreshes defer during combat and rebuild afterward.

Rank badges appear on the default action bar, the four traditional extra bars, and the three additional modern bars:

- **Green:** The most mana-efficient rank in the comparison.
- **Gold:** The highest learned rank in the comparison, when it is not also the most efficient.
- **Grey:** Other learned ranks in the comparison.

The highest rank is not necessarily the highest throughput choice. Badges refresh when action bar pages or forms change, once out of combat.

## Estimates and supported effects

Supported English (`enUS`) descriptions include direct healing or damage, periodic totals, direct-plus-periodic effects, shields, and simple tick-based channels. Known channel families use their full channel duration for output per cast second. Periodic output per duration second is an average, not the amount of an individual tick.

Optional crit estimation assumes critical hits produce **150%** of normal output. It applies to direct effects and selected periodic spell families, including Renew, Rejuvenation, Tranquility, Wild Growth, Riptide, and supported drains. Shields and unknown periodic families receive no crit adjustment. Spell-specific crit bonuses, conditional talents, triggered effects, hit chance, resistance, and overhealing are not modeled, so these values are estimates. [Blizzard's beta notes](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-october-8/2360696/1) document several periodic crit changes; [the Warlock deep dive](https://worldofwarcraft.blizzard.com/en-us/news/24310968) describes drain crit bonuses.

AoE and chained effects show a single or primary-target amount. The addon does not assume a target count or multiply the first target's output across diminishing jumps.

Unsupported descriptions are omitted. These include ambiguous multi-effect output, damage-or-heal channels with an initial tick, self-and-enemy damage channels, and spells with ongoing mana consumption. Non-English descriptions are not supported.

## Slash commands

- `/frank` or `/foreverrank` — Refresh and print the most mana-efficient rank for each supported spell with multiple learned ranks. Run out of combat for a current summary.
- `/frank badges` — Toggle action bar rank badges. `/frank bars` is an alias.
- `/frank crit` — Toggle estimated crit scaling.

## Validation

From the addon directory, run the mocked regression suite with Lua 5.1:

```sh
lua5.1 tests/regression.lua
```

Alternatively, install the optional Python dependency with `python -m pip install lupa`, then run:

```sh
python tests/run.py
```

The suite checks parser totals, rank membership, refresh behavior, and badge updates with controlled client mocks. It does not replace in-game validation of tooltip values, combat restrictions, or every spell's mechanics.
