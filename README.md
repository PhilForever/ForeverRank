# ForeverRank

ForeverRank is a lightweight, zero-combat-CPU mana efficiency and downranking calculator built specifically for **WoW: Forever** (`1.60.1`).

Because *WoW: Forever* rebalances class talents, base spell values, and coefficients while enforcing modern combat API rules, legacy 1.12 spell calculators are no longer accurate. **ForeverRank** dynamically reads your live spellbook descriptions, factors in your equipped **+Healing**, **+Spell Damage**, and **Spell Crit**, and calculates which spell rank provides peak mana efficiency for your current gear.

---

## Key Features

* **Live Tooltip Breakdown:** Appends **HPM** (Heal-Per-Mana) or **DPM** (Damage-Per-Mana), estimated total output, and **HPS / DPS / HPCT** directly to your spell tooltips out of combat.
* **Optimal Downrank Finder:** Automatically scans all known ranks of your spells on login and gear swaps, highlighting your most mana-efficient rank with a **Peak Mana Efficiency** badge.
* **Action Bar Rank Badges:** Displays clean, color-coded rank overlays on your action bar buttons:
  * **Green (`R2`):** Your most mana-efficient rank for your current gear.
  * **Gold (`R4`):** Your highest throughput (max) rank learned.
  * **Grey (`R1`):** Intermediate or outdated ranks.
* **Full Spell Mechanics Support:**
  * **Direct Heals & Nukes:** Uses the 3.5-second cast time coefficient rule and Classic sub-level-20 downrank penalties.
  * **Periodic (HoTs & DoTs):** Uses the 15-second duration rule and displays both per-cast and per-second output.
  * **Hybrid Spells (*Regrowth*, *Holy Fire*, *Immolate*):** Proportionally splits Spell Power between direct and periodic portions.
  * **Absorb Shields (*Power Word: Shield*, *Ice Barrier*):** Calculates effective HPM for damage absorption shields.
  * **Multi-Target & AoE (*Prayer of Healing*, *Holy Nova*, *Chain Heal*):** Displays both single-target and 5-target AoE mana efficiency.
* **Zero Combat CPU:** Respects *WoW: Forever* combat lockdown rules—never runs combat log parsers or background loops during combat.

---

## Slash Commands

* `/frank` or `/foreverrank` — Prints a complete summary in chat of your most mana-efficient rank for every multi-rank spell in your Spellbook.
* `/frank badges` — Toggles the `TOPLEFT` rank badges on your action bars ON/OFF.
* `/frank crit` — Toggles Spell Critical Strike scaling in efficiency calculations ON/OFF.
