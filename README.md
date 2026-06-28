# 🛠️ Okanvil Suite

> An ElvUI-style **addon host + plugins** for WoW **3.3.5a / Warmane**.
> Every plugin runs **on its own** — and slots into Okanvil's window when the host is installed.

<br>

## 🧩 The addons

| | Addon | What it does |
|:--:|:--|:--|
| 🏰 | **Okanvil** | The host shell. Empty by itself — provides the window, theme & shared media for the plugins. |
| 🔎 | **Okanvil‑IDs** | Find a spell/item **ID by name** for WeakAuras — offline spell scan, item harvester, aura catcher, link library. |
| 📜 | **Okanvil‑Logs** | Combat‑log helper — auto `/combatlog` when you enter a raid. |
| 📣 | **Okanvil‑Recruit** | Recruitment helper. |
| 🐀 | **Okanvil‑Guild** | Guild tools — export the guild roster as JSON. |

<br>

## 📥 Install

1. Grab the addon zip(s) from the **[Latest release](../../releases/latest)**.
2. Drop the folder(s) into `World of Warcraft\Interface\AddOns\`.
3. **Fully restart the game** (a brand-new addon won't show after just `/reload`).

The host is **optional** — every plugin also works standalone.

<br>

## 📦 Releases

Push to `main` → the action builds one clean `<Addon>.zip` per folder and updates the rolling
**Latest** release. Download only what you want.

<br>

## ❓ Why one repo

The plugins share the host's API (`Okanvil:Register`, `Okanvil_Plugins`, the media/`Backdrop`
helpers), so changing it should be **one commit**, not several.
Full roadmap & plugin contract → **[`Okanvil/PLAN.md`](Okanvil/PLAN.md)**.
