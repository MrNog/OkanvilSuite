# Okanvil suite

Monorepo for the **Okanvil** addon host and its plugins (WoW 3.3.5a / Warmane). Each folder is its
own installable addon — plugins work standalone, and embed into Okanvil's window when it's present.

## Addons
| Folder | What it is |
|---|---|
| `Okanvil/` | The host shell (ElvUI-style). Empty by itself; hosts the plugins, shared media/theme, config window. |
| `Okanvil-IDs/` | Find a spell/item **ID by name** (for WeakAuras) — offline spell scan, item harvester, aura catcher, link library. |
| `Okanvil-Logs/` | Combat-log helper (auto `/combatlog` in raids). |
| `Okanvil-recruit/` | Recruitment helper. |

## Why one repo
The plugins share the host's plugin contract (`Okanvil:Register`, `Okanvil_Plugins`, media/`Backdrop`
helpers). Changing that API touches the host **and** every plugin — one repo = one atomic commit.

## Install
Each addon is a top-level folder → drop it into `World of Warcraft\Interface\AddOns\`. A **new addon
needs a full game restart** (not just `/reload`). The host is optional for every plugin.

## Releases
`.github/workflows/package.yml` builds one clean `<Addon>.zip` per folder on push to `main` and
attaches them all to the rolling **Latest** release. Download only the folders you want.

## Design rules
- **Okanvil stays empty** — all features are standalone plugins.
- Plugins **never hard-depend** on Okanvil; always fall back to their own window (`## OptionalDeps: Okanvil`).
- One shared media source (`Okanvil.db` font/texture/alpha) themes the whole suite.
- Registration is load-order safe via the shared `Okanvil_Plugins` global.

See `Okanvil/PLAN.md` for the host roadmap and plugin contract.
