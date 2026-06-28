-- Okanvil-guild — guild tools for the RATS hub. First feature: export the guild roster as JSON.
-- Works standalone (own window) and embeds into Okanvil as the "Guild" tab when the host is present.
-- Roster export matches officer/guild.html's importer:
--   { guildName, realm, exportedAt, ranks:[{name,rankIndex}], roster:[{name,class,level,rankName,rankIndex,publicNote,officerNote}] }

local ADDON = "Okanvil-guild"

-- minimal JSON string escaper (WoW strings are UTF-8 -> raw is valid JSON)
local function esc(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return s
end

local function BuildJSON()
  local guildName = GetGuildInfo("player") or "Guild"
  local realm = GetRealmName() or ""
  local total = GetNumGuildMembers() or 0
  local ranksSeen, ranks, members = {}, {}, {}
  for i = 1, total do
    -- 3.3.5 signature: name, rank, rankIndex, level, class, zone, note, officernote, online, status
    local name, rankName, rankIndex, level, class, _, note, officernote = GetGuildRosterInfo(i)
    if name then
      name = name:gsub("%-.*$", "")
      rankIndex = rankIndex or 0
      if not ranksSeen[rankIndex] then
        ranksSeen[rankIndex] = true
        table.insert(ranks, { idx = rankIndex, name = rankName or ("Rank " .. rankIndex) })
      end
      table.insert(members, string.format(
        '{"name":"%s","class":"%s","level":%d,"rankName":"%s","rankIndex":%d,"publicNote":"%s","officerNote":"%s"}',
        esc(name), esc(class), level or 0, esc(rankName), rankIndex, esc(note), esc(officernote)))
    end
  end
  table.sort(ranks, function(a, b) return a.idx < b.idx end)
  local ranksJson = {}
  for _, r in ipairs(ranks) do
    table.insert(ranksJson, string.format('{"name":"%s","rankIndex":%d}', esc(r.name), r.idx))
  end
  return string.format(
    '{"guildName":"%s","realm":"%s","exportedAt":%d,"ranks":[%s],"roster":[%s]}',
    esc(guildName), esc(realm), time(), table.concat(ranksJson, ","), table.concat(members, ",")), #members
end

-- shared UI handles (work whether embedded or standalone)
local ui = {}
local pendingShow = false

local function Populate()
  local json, count = BuildJSON()
  OkanvilGuildDB = { lastExport = json, at = time() }   -- backup copy in SavedVariables
  if ui.eb then ui.eb:SetText(json); ui.eb:HighlightText(); ui.eb:SetFocus() end
  if ui.status then ui.status:SetText(count .. " members — Ctrl+A, Ctrl+C to copy, paste into the hub.") end
end

local function RequestRoster()
  if not IsInGuild() then
    if ui.status then ui.status:SetText("You're not in a guild.") end
    return
  end
  SetGuildRosterShowOffline(true)   -- include offline members
  pendingShow = true
  GuildRoster()                     -- -> GUILD_ROSTER_UPDATE -> Populate()
  if ui.status then ui.status:SetText("Fetching roster…") end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:SetScript("OnEvent", function() if pendingShow then pendingShow = false; Populate() end end)

-- Build the Guild panel into ANY parent (Okanvil content panel, or our own window's body).
local function Guild_BuildUI(parent)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(170, 24)
  btn:SetPoint("TOPLEFT", 12, -12)
  btn:SetText("Export roster JSON")
  btn:SetScript("OnClick", RequestRoster)

  local status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("LEFT", btn, "RIGHT", 10, 0)
  status:SetText("Pull the guild roster as JSON for the hub importer.")
  ui.status = status

  local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -10)
  scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -30, 12)

  local eb = CreateFrame("EditBox", nil, scroll)
  eb:SetMultiLine(true)
  eb:SetFontObject(ChatFontNormal)
  eb:SetWidth(440)
  eb:SetAutoFocus(false)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  scroll:SetScrollChild(eb)
  ui.eb = eb
end

-- Standalone window (used only when Okanvil isn't installed).
local standalone
local function CreateStandaloneWindow()
  local f = CreateFrame("Frame", "OkanvilGuildFrame", UIParent)
  f:SetSize(560, 420); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
  })
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -16); title:SetText("Okanvil-guild")

  local body = CreateFrame("Frame", nil, f)
  body:SetPoint("TOPLEFT", 6, -40); body:SetPoint("BOTTOMRIGHT", -6, 40)
  Guild_BuildUI(body)

  local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  close:SetSize(90, 22); close:SetPoint("BOTTOM", 0, 16); close:SetText("Close")
  close:SetScript("OnClick", function() f:Hide() end)

  f:Hide()
  return f
end

local function Toggle()
  if Okanvil and Okanvil.Toggle then Okanvil:Toggle(); return end
  if standalone then if standalone:IsShown() then standalone:Hide() else standalone:Show() end end
end

-- Register with Okanvil if present; otherwise stand on our own.
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
  Okanvil_Plugins = Okanvil_Plugins or {}
  Okanvil_Plugins["Okanvil-guild"] = {
    title = "Guild",
    icon  = "Interface\\Icons\\INV_Misc_GroupLooking",
    build = function(panel) Guild_BuildUI(panel) end,   -- room to add more guild tools here later
  }
  if Okanvil and Okanvil.Register then
    Okanvil:Register("Okanvil-guild")     -- embed into the host
  else
    standalone = CreateStandaloneWindow() -- standalone fallback
  end
end)

SLASH_OKANVILGUILD1 = "/okanvilguild"
SLASH_OKANVILGUILD2 = "/oguild"
SlashCmdList["OKANVILGUILD"] = Toggle
