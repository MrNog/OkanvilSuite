# Okanvil — plan / roadmap

**Goal:** an ElvUI-style **host addon** (`Okanvil`) that is *empty by itself* and hosts
**standalone plugins**. Each plugin (Okanvil-recruit, a future Log addon, …) works **on its own**
AND, when Okanvil is installed, embeds into Okanvil's config window as a list entry. No hard coupling
— the plugin always falls back to its own window if Okanvil isn't present.

---

## ✅ DONE — Okanvil core (built, NOT yet tested in-game)

Folder: `Projects\Okanvil\` → synced to `…\AddOns\Okanvil\`. **New addon → needs a full game RESTART.**

- `Okanvil.toc` — loads embedded libs → `Core.lua` → `UI.lua`. SavedVariables: `Okanvil_DB`.
- `Libs\` — embedded **LibStub**, **CallbackHandler-1.0**, **LibSharedMedia-3.0** (so Okanvil works standalone).
- `Core.lua` — engine:
  - `Okanvil` global, DB + defaults (window pos/size, scale, font, fontSize, fontFlag, statusbar, bgAlpha, minimapAngle).
  - Media API: `Okanvil:Font()`, `Okanvil:Texture()`, `Okanvil:NewText(parent,layer,template)` (auto-restyles on font change), `Okanvil:ApplyFonts()`, `Okanvil:Backdrop(frame,alpha,dark)`.
  - Registry: `Okanvil:Register(name)`, `Okanvil:ProcessPlugins()`, `Okanvil:CountPlugins()`.
  - Boot: ADDON_LOADED (db) + PLAYER_LOGIN (process plugins, minimap). Slash `/okanvil`.
- `UI.lua` — shell:
  - Resizable (corner grip) + movable (header drag); size/pos saved to DB.
  - Left nav (scroll list) + content area (anchor-based, auto-reflows on resize).
  - **Home** panel (presentation + installed-plugin list).
  - **Okanvil Settings** tab: scale / bg opacity / font size sliders + **font** & **bar-texture** LSM dropdowns.
  - Minimap button + `Okanvil:Toggle()`.

### Test checklist (do first, after RESTART)
- [ ] `/okanvil` opens the window; Home shows "No plugins installed yet".
- [ ] Drag header to move; drag corner grip to resize; reopen → size/pos remembered.
- [ ] Okanvil Settings → change scale / font / opacity → applies live & persists.
- [ ] No Lua errors on login.

---

## ▶️ NEXT — Step 2: convert Okanvil-recruit into a plugin

Keep it 100% standalone; just make it Okanvil-aware.

1. **Parent-agnostic UI:** change `Recruit_BuildUI()` → `Recruit_BuildUI(parent)` and build all widgets
   as children of `parent` instead of the fixed `RecruitFrame`. (Standalone passes its own
   window; Okanvil passes its content panel.)
2. **Register + fallback** (run at PLAYER_LOGIN):
   ```lua
   Okanvil_Plugins = Okanvil_Plugins or {}
   Okanvil_Plugins["Okanvil-recruit"] = {
       title = "Okanvil-recruit",
       icon  = "Interface\\Icons\\Ability_Warrior_BattleShout",
       build = function(panel) Recruit_BuildUI(panel) end,
       refresh = function() Recruit_RefreshUI() end,
   }
   if Okanvil and Okanvil.Register then
       Okanvil:Register("Okanvil-recruit")     -- embed; skip own window
   else
       RRec_CreateStandaloneWindow()      -- own window + minimap (current behaviour)
   end
   ```
3. **`.toc`:** add `## OptionalDeps: Okanvil` (never a hard dependency).
4. Optional: when embedded, hide the Okanvil-recruit minimap button (or make it open Okanvil).
5. Optional: use `Okanvil:Backdrop`/`Okanvil:NewText` when `Okanvil` exists so it inherits the theme/font.

---

## ▶️ Step 3: new Log addon (standalone + consumable)

- A standalone combat-log helper (since no auto-log addon exists for 3.3.5a). Likely: auto `/combatlog`
  on entering a raid instance (ZONE/PLAYER_ENTERING_WORLD), toggle, status display.
- Born with the **same plugin contract** so Okanvil hosts it for free.

---

## ✅ Plugin: Okanvil-IDs (built, NOT yet tested in-game)

`Projects\Okanvil-IDs\` → junction in `…\AddOns\Okanvil-IDs`. **New addon → full game RESTART.**

- **Goal:** find a spell/item **ID by NAME** (for WeakAuras), without owning the item.
- **Spells:** scanned fully offline from the client (`GetSpellInfo(1..80000)`) — complete, no server hits.
- **Items:** the 3.3.5a client has **no offline item-name table**, so items are **harvested** —
  every item the client loads (tooltip hover incl. AtlasLoot, bags, bank, merchant, chat links) +
  a "Sweep loaded items" button + auto-sweep gear/bags on login. Stored in `OkanvilIDsDB` (account-wide).
- **Full scan (risky):** optional brute-force `GetItemInfo(1..56000)`, throttled (~1k ids/s) + Stop button.
  Fires a server request per uncached id → may throttle/disconnect on a private server. Test once.
- **Auras tab:** catches every buff/debuff that lands on you/target/focus/pet (`select(11, UnitBuff...)`,
  account-wide `OkanvilIDsDB.auras`). Empty search = "caught this session, newest first" → proc a trinket,
  the buff is at the top. This is the only reliable item→proc-buff bridge (client has no API for it).
- **Link library (`OkanvilIDsDB.links`):** the whole point — a personal offline Wowhead. Pick an item, pick a
  spell/buff, hit **⇄ Link** → saved forever. Picking the item then lists its linked buffs (click=copy,
  right-click=unlink); picking a buff shows "comes from items". e.g. Soul Preserver 37111 ⇄ Healing Trance 60513.
- Picking an item also shows `↳ use/proc spell` via `GetItemSpell` (gives the equip spell, e.g. 60510).
- Click a result → ID drops into a **Ctrl+C-ready box**; toggle raw-id ↔ `GetItemCount(id)` snippet.
- Slash `/cid` (or `/idfind`); `/cid sweep`. Standalone window or embeds into Okanvil as "ID Finder".
- **Test:** RESTART → `/cid` → Items: Sweep, search "potion of speed" → 40211; open an AtlasLoot page,
  hover items, search them. Spells: search "bloodlust"/"heroism". Verify Ctrl+C copies the box.

## 🎨 Polish / later

- Swap placeholder icons (`INV_Misc_Rabbit_2`) for your own logo (header, minimap, nav).
- Per-fontstring size multipliers (titles bigger) — `_cifSize` hook already in `ApplyFonts`.
- Content scroll if a plugin panel overflows.
- Remember last open panel across sessions (save `_current` to DB).
- Optional shared **profiles** (copy Okanvil + plugin settings between chars).
- Optional: Okanvil exposes `Okanvil:GetDB(pluginName)` so plugins can store settings in Okanvil's DB when embedded.
- Version-check/“plugin list” niceties (ElvUI's EP does this).

---

## Design rules (don't break these)
- **Okanvil stays empty** — all features are standalone plugins.
- Plugins **never hard-depend** on Okanvil; always have a standalone fallback.
- One **shared media** source (`Okanvil.db` font/texture/alpha) so the whole suite themes from one place.
- Registration is **load-order safe** via the shared `Okanvil_Plugins` global.

## File map
```
Projects\Okanvil\
  Okanvil.toc
  Core.lua      (engine, DB, media, registry, slash)
  UI.lua        (window, nav, Home, Settings, minimap)
  Libs\         (LibStub, CallbackHandler-1.0, LibSharedMedia-3.0)
  PLAN.md       (this file)
```
Sync to game: `Copy-Item -Recurse Projects\Okanvil → …\AddOns\Okanvil` (RESTART after first install).
