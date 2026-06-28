# Okanvil suite

Monorepo for the **Okanvil** addon host and its plugins — World of Warcraft **3.3.5a / Warmane**.

Each folder is its own installable addon. Plugins work **standalone**, and embed into Okanvil's
window when the host is present.

---

## Addons

### `Okanvil`
The host shell (ElvUI-style). Empty by itself — it hosts the plugins, the shared media/theme, and the
config window.

### `Okanvil-IDs`
Find a spell or item **ID by name** (for WeakAuras). Offline spell scan, item harvester, aura catcher,
and a personal link library.

### `Okanvil-Logs`
Combat-log helper — auto `/combatlog` when you enter a raid.

### `Okanvil-recruit`
Recruitment helper.

### `Okanvil-guild`
Guild tools. First feature: export the guild roster as JSON for the RATS hub importer.

---

## Install

Drop the addon folder(s) you want into:

```
World of Warcraft\Interface\AddOns\
```

A **new addon needs a full game restart** (not just `/reload`). The host is optional for every plugin.

---

## Releases

`.github/workflows/package.yml` builds one clean `<Addon>.zip` per folder on every push to `main` and
attaches them all to the rolling **Latest** release — download only the folders you want.

---

## Why one repo

The plugins share the host's plugin contract (`Okanvil:Register`, `Okanvil_Plugins`, the media /
`Backdrop` helpers). Changing that API touches the host **and** every plugin — one repo means one
atomic commit instead of juggling several.

## Design rules

- **Okanvil stays empty** — every feature is a standalone plugin.
- Plugins **never hard-depend** on Okanvil; they always fall back to their own window
  (`## OptionalDeps: Okanvil`).
- One shared media source (`Okanvil.db` font / texture / alpha) themes the whole suite.
- Registration is load-order safe via the shared `Okanvil_Plugins` global.

See [`Okanvil/PLAN.md`](Okanvil/PLAN.md) for the host roadmap and the full plugin contract.
