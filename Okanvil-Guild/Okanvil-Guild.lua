-- Okanvil-Guild — guild tools for the RATS hub. First feature: export the guild roster as JSON.
-- Works standalone (own window) and embeds into Okanvil as the "Guild" tab when the host is present.
-- Roster export matches officer/guild.html's importer:
--   { guildName, realm, exportedAt, ranks:[{name,rankIndex}], roster:[{name,class,level,rankName,rankIndex,publicNote,officerNote}] }

local ADDON = "Okanvil-Guild"

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
			table.insert(
				members,
				string.format(
					'{"name":"%s","class":"%s","level":%d,"rankName":"%s","rankIndex":%d,"publicNote":"%s","officerNote":"%s"}',
					esc(name),
					esc(class),
					level or 0,
					esc(rankName),
					rankIndex,
					esc(note),
					esc(officernote)
				)
			)
		end
	end
	table.sort(ranks, function(a, b)
		return a.idx < b.idx
	end)
	local ranksJson = {}
	for _, r in ipairs(ranks) do
		table.insert(ranksJson, string.format('{"name":"%s","rankIndex":%d}', esc(r.name), r.idx))
	end
	return string.format(
		'{"guildName":"%s","realm":"%s","exportedAt":%d,"ranks":[%s],"roster":[%s]}',
		esc(guildName),
		esc(realm),
		time(),
		table.concat(ranksJson, ","),
		table.concat(members, ",")
	),
		#members
end

-- ------------------------------------------------------------
-- UI helpers — use Okanvil's shared look when embedded, else fall back.
-- ------------------------------------------------------------
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"

local function flat(f, a, dark)
	if Okanvil and Okanvil.Backdrop then
		Okanvil:Backdrop(f, a, dark)
		return
	end
	f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
	f:SetBackdropColor(dark and 0.06 or 0.10, dark and 0.06 or 0.10, dark and 0.08 or 0.12, a or 0.95)
	f:SetBackdropBorderColor(0.32, 0.32, 0.38, 1)
end

local function newText(parent, layer)
	if Okanvil and Okanvil.NewText then
		return Okanvil:NewText(parent, layer)
	end
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	fs:SetFont(STANDARD_TEXT_FONT, 12)
	return fs
end

local function flatButton(parent, text, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	flat(b, 1)
	b.text = newText(b, "OVERLAY")
	b.text:SetPoint("CENTER")
	b.text:SetText(text)
	b:SetScript("OnEnter", function(s)
		s:SetBackdropColor(0.2, 0.2, 0.25, 1)
	end)
	b:SetScript("OnLeave", function(s)
		s:SetBackdropColor(0.10, 0.10, 0.12, 1)
	end)
	return b
end

-- shared UI handles (work whether embedded or standalone)
local ui = {}
local pendingShow = false

local function Populate()
	local json, count = BuildJSON()
	OkanvilGuildDB = OkanvilGuildDB or {}
	OkanvilGuildDB.lastExport, OkanvilGuildDB.at = json, time() -- backup copy in SavedVariables
	if ui.eb then
		ui.eb:SetText(json)
		ui.eb:HighlightText()
		ui.eb:SetFocus()
	end
	if ui.status then
		ui.status:SetText(count .. " members — Ctrl+A, Ctrl+C to copy, paste into the hub.")
	end
end

local function RequestRoster()
	if not IsInGuild() then
		if ui.status then
			ui.status:SetText("You're not in a guild.")
		end
		return
	end
	SetGuildRosterShowOffline(true) -- include offline members
	pendingShow = true
	GuildRoster() -- -> GUILD_ROSTER_UPDATE -> Populate()
	if ui.status then
		ui.status:SetText("Fetching roster…")
	end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:SetScript("OnEvent", function()
	if pendingShow then
		pendingShow = false
		Populate()
	end
end)

-- Build the Guild panel into ANY parent (Okanvil content panel, or our own window's body).
local scrollSeq = 0 -- unique names so UIPanelScrollFrameTemplate never concatenates a nil name
local function Guild_BuildUI(parent)
	local btn = flatButton(parent, "Export roster JSON", 150, 22)
	btn:SetPoint("TOPLEFT", 12, -12)
	btn:SetScript("OnClick", RequestRoster)

	local status = newText(parent, "OVERLAY")
	status:SetPoint("LEFT", btn, "RIGHT", 10, 0)
	status:SetPoint("RIGHT", parent, "RIGHT", -12, 0) -- anchored both sides so it tracks width
	status:SetJustifyH("LEFT")
	status:SetText("Pull the guild roster as JSON for the hub importer.")
	ui.status = status

	-- bordered box around the scroll area, matching the rest of the suite
	local box = CreateFrame("Frame", nil, parent)
	box:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -10)
	box:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, 12)
	flat(box, nil, true)

	-- named scroll frame: UIPanelScrollFrameTemplate errors when its name is nil
	scrollSeq = scrollSeq + 1
	local scroll = CreateFrame("ScrollFrame", "OkanvilGuild_Scroll" .. scrollSeq, box, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", -10, 4) -- leave room for the scrollbar
	if Okanvil and Okanvil.skinScroll then
		Okanvil.skinScroll(scroll) -- thin flat ElvUI-style bar to match the host
	end

	local eb = CreateFrame("EditBox", nil, scroll)
	eb:SetMultiLine(true)
	eb:SetFontObject(ChatFontNormal)
	eb:SetAutoFocus(false)
	eb:SetWidth(scroll:GetWidth())
	eb:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	scroll:SetScrollChild(eb)
	ui.eb = eb

	-- keep the text column matched to the window as it resizes
	scroll:SetScript("OnSizeChanged", function(self, w)
		eb:SetWidth(w or self:GetWidth())
	end)
end

-- Standalone window (used only when Okanvil isn't installed).
local standalone
local function CreateStandaloneWindow()
	local f = CreateFrame("Frame", "OkanvilGuildFrame", UIParent)
	f:SetSize(560, 440)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	flat(f) -- same flat panel as the host
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetResizable(true)
	if f.SetMinResize then
		f:SetMinResize(420, 320)
	end
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)

	-- header bar
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetPoint("TOPLEFT", 2, -2)
	hdr:SetPoint("TOPRIGHT", -2, -2)
	hdr:SetHeight(24)
	local hbg = hdr:CreateTexture(nil, "ARTWORK")
	hbg:SetTexture(FLAT)
	hbg:SetVertexColor(0.16, 0.16, 0.20, 1)
	hbg:SetAllPoints()

	local title = newText(f, "OVERLAY")
	title:SetPoint("LEFT", hdr, "LEFT", 8, 0)
	title:SetText("|cff66ddffOkanvil-Guild|r")

	local close = flatButton(hdr, "X", 22, 20)
	close:SetPoint("RIGHT", hdr, "RIGHT", -3, 0)
	close:SetScript("OnClick", function()
		f:Hide()
	end)

	local body = CreateFrame("Frame", nil, f)
	body:SetPoint("TOPLEFT", 4, -28)
	body:SetPoint("BOTTOMRIGHT", -4, 4)
	Guild_BuildUI(body)

	-- resize grip
	local grip = CreateFrame("Button", nil, f)
	grip:SetPoint("BOTTOMRIGHT", -2, 2)
	grip:SetSize(16, 16)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnMouseDown", function()
		f:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
	end)

	f:Hide()
	return f
end

local function Toggle()
	if Okanvil and Okanvil.Toggle then
		Okanvil:Toggle()
		return
	end
	if standalone then
		if standalone:IsShown() then
			standalone:Hide()
		else
			standalone:Show()
		end
	end
end

-- Minimap button (standalone only — when hosted, use the Okanvil button instead).
local minimapBtn
local function CreateMinimapButton()
	if minimapBtn then
		return
	end
	OkanvilGuildDB = OkanvilGuildDB or {}
	local b = CreateFrame("Button", "OkanvilGuild_MinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp")
	b:RegisterForDrag("LeftButton")

	local overlay = b:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("CENTER", 1, 1)

	local function updatePos()
		local a = math.rad(OkanvilGuildDB.minimapAngle or 215)
		b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
	end
	updatePos()

	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local s = Minimap:GetEffectiveScale()
			OkanvilGuildDB.minimapAngle = math.deg(math.atan2(py / s - my, px / s - mx))
			updatePos()
		end)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	b:SetScript("OnClick", Toggle)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("|cff66ddffOkanvil-Guild|r")
		GameTooltip:AddLine("Click: open", 1, 1, 1)
		GameTooltip:AddLine("Drag: move button", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	minimapBtn = b
end

-- Register with Okanvil if present; otherwise stand on our own.
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
	Okanvil_Plugins = Okanvil_Plugins or {}
	Okanvil_Plugins["Okanvil-Guild"] = {
		title = "Guild",
		icon = "Interface\\Icons\\INV_Misc_GroupLooking",
		build = function(panel)
			Guild_BuildUI(panel)
		end, -- room to add more guild tools here later
	}
	if Okanvil and Okanvil.Register then
		Okanvil:Register("Okanvil-Guild") -- embed into the host
	else
		standalone = CreateStandaloneWindow() -- standalone fallback
		CreateMinimapButton() -- only standalone gets its own button
	end
end)

SLASH_OKANVILGUILD1 = "/okanvilguild"
SLASH_OKANVILGUILD2 = "/okguild"
SlashCmdList["OKANVILGUILD"] = Toggle
