# Okanvil

A lightweight **host shell for standalone WoW addons** — ElvUI-style plugins for WotLK **3.3.5a**.

Plugins register into Okanvil and get a shared home: one config window, a common theme, fonts and shared media. Every plugin also runs perfectly **standalone** (Okanvil is never a hard dependency).

## Install

1. Download the latest **.zip** (green **Code → Download ZIP**, or a release).
2. Extract and drop the **`Okanvil`** folder into `World of Warcraft\Interface\AddOns\` (remove any `-main` suffix so the folder is exactly `Okanvil`).
3. Restart WoW or `/reload`.
4. Open it with **`/okanvil`**.

## Plugins

Each works on its own, or docks into Okanvil when it's installed:

| Plugin | What it does |
|---|---|
| [Okanvil-Logs](https://github.com/MrNog/Okanvil-Logs) | Combat-log control + REC timer + session tracker |
| [Okanvil-recruit](https://github.com/MrNog/Okanvil-recruit) | Guild-recruitment advertiser (auto-reply + auto-invite) |
| [Okanvil-IDs](https://github.com/MrNog/Okanvil-IDs) | Search spells & items by name → get the ID (for WeakAuras) |

## For plugin authors

Register your addon at `PLAYER_LOGIN`:

```lua
Okanvil_Plugins = Okanvil_Plugins or {}
Okanvil_Plugins["MyAddon"] = {
    title   = "MyAddon",
    icon    = "Interface\\Icons\\INV_Misc_Gear_01",
    build   = function(panel) --[[ build your UI as children of panel ]] end,
    refresh = function() --[[ optional ]] end,
}
if Okanvil and Okanvil.Register then
    Okanvil:Register("MyAddon")   -- embed into Okanvil; skip your own window
else
    MyAddon_CreateStandaloneWindow()  -- run on your own
end
```

Add `## OptionalDeps: Okanvil` to your `.toc` (never a hard dependency). Helpers available when embedded: `Okanvil:Backdrop(frame)`, `Okanvil:NewText(...)`, shared font/media.

---

Interface: **3.3.5a (30300)**.
