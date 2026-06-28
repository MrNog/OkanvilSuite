-- ============================================================
--   ██████╗██╗███████╗███████╗██████╗
--  ██╔════╝██║██╔════╝██╔════╝██╔══██╗
--  ██║     ██║█████╗  █████╗  ██████╔╝
--  ██║     ██║██╔══╝  ██╔══╝  ██╔══██╗
--  ╚██████╗██║██║     ███████╗██║  ██║
--   ╚═════╝╚═╝╚═╝     ╚══════╝╚═╝  ╚═╝
--  Okanvil-Logs -- combat-log control + a movable/lockable REC timer
--  + session tracker. Works standalone OR embeds into Okanvil.
--  (Addons can't read/write files, so SLICING + EXPORT live in the
--   desktop tool; this records start/stop/zone as a reference.)
-- ============================================================

local ADDON = "Okanvil-Logs"
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"

local defaults = {
	askOnEnter = true, -- prompt (Start log / No) when entering an instance
	autoLog = false, -- legacy: silently auto-log on raid entry (used only if askOnEnter is off)
	recLocked = false, -- lock the REC timer (click-through, no drag)
	rec = { point = "TOP", x = 0, y = -140 },
	minimapAngle = 205, -- standalone minimap button position
}
local db
local rec, toastF, askLogF -- frames
local askedZone -- last instance we already prompted for (avoid re-asking on repeat PLAYER_ENTERING_WORLD)
OkanvilLogs = OkanvilLogs or {} -- tiny namespace for slash/standalone

-- ------------------------------------------------------------
-- helpers (use Okanvil's shared media when embedded, else local)
-- ------------------------------------------------------------
local function flat(f, a, dark)
	if Okanvil and Okanvil.Backdrop then
		Okanvil:Backdrop(f, a, dark)
		return
	end
	f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
	f:SetBackdropColor(dark and 0.06 or 0.10, dark and 0.06 or 0.10, dark and 0.08 or 0.12, a or 0.95)
	f:SetBackdropBorderColor(0.32, 0.32, 0.38, 1)
end

local function newText(parent, layer, size)
	if Okanvil and Okanvil.NewText then
		local fs = Okanvil:NewText(parent, layer)
		if size then
			fs._cifSize = size
			fs:SetFont(Okanvil:Font(), size)
		end
		return fs
	end
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	fs:SetFont(STANDARD_TEXT_FONT, size or 12)
	return fs
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ddff[Okanvil-Logs]|r " .. tostring(msg))
end

local function fmtTime(s)
	s = math.floor(s or 0)
	if s >= 3600 then
		return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
	end
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
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

-- a label + ON/OFF flat toggle (no Blizzard checkbox)
local function toggleRow(parent, label, x, y, getFn, setFn)
	local fs = newText(parent, "OVERLAY")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(label)
	local b = flatButton(parent, "", 46, 20)
	b:SetPoint("TOPLEFT", x + 200, y + 4)
	local function paint()
		if getFn() then
			b.text:SetText("|cff00ff00ON|r")
		else
			b.text:SetText("|cffff5555OFF|r")
		end
	end
	paint()
	b:SetScript("OnClick", function()
		setFn(not getFn())
		paint()
	end)
	b._paint = paint
	return b
end

-- ------------------------------------------------------------
-- logging state + sessions
-- ------------------------------------------------------------
local function isLogging()
	return LoggingCombat()
end

-- the desktop tool slices WoWCombatLog.txt itself, so we only keep a tiny
-- in-flight marker (start time) for the REC timer -- no persisted session list.
local function beginSession()
	db._cur = { start = time(), bosses = {} }
end

local function endSession()
	if db._cur and db._cur.bosses then
		db._lastBosses = db._cur.bosses -- keep the last session's kills visible after Stop
	end
	db._cur = nil
end

-- ------------------------------------------------------------
-- transient toast (start/stop)
-- ------------------------------------------------------------
local function toast(msg, color)
	PlaySound("UI_BnetToast")
	if not toastF then
		toastF = CreateFrame("Frame", nil, UIParent)
		toastF:SetSize(230, 30)
		toastF:SetPoint("TOP", 0, -100)
		toastF:SetFrameStrata("FULLSCREEN_DIALOG")
		flat(toastF, 0.96, true)
		toastF.txt = newText(toastF, "OVERLAY")
		toastF.txt:SetPoint("CENTER")
		toastF:SetScript("OnUpdate", function(s, e)
			s._life = (s._life or 0) - e
			if s._life <= 0 then
				s:Hide()
			elseif s._life < 1 then
				s:SetAlpha(s._life)
			end
		end)
	end
	toastF.txt:SetText("|cff" .. (color or "ffffff") .. msg .. "|r")
	toastF:SetAlpha(1)
	toastF._life = 3
	toastF:Show()
end

-- ------------------------------------------------------------
-- raid boss recognition -- record which bosses died during a session
-- (no encounter API in 3.3.5a, so we match UNIT_DIED against known names)
-- ------------------------------------------------------------
local BOSSES = {}
do
	local names = {
		-- Ulduar
		"Flame Leviathan", "Ignis the Furnace Master", "Razorscale", "XT-002 Deconstructor",
		"Steelbreaker", "Runemaster Molgeim", "Stormcaller Brundir", "Kologarn", "Auriaya",
		"Hodir", "Thorim", "Freya", "Mimiron", "General Vezax", "Yogg-Saron", "Algalon the Observer",
		-- Icecrown Citadel
		"Lord Marrowgar", "Lady Deathwhisper", "Deathbringer Saurfang", "Festergut", "Rotface",
		"Professor Putricide", "Prince Keleseth", "Prince Taldaram", "Prince Valanar",
		"Blood-Queen Lana'thel", "Sindragosa", "The Lich King",
		-- Trial of the (Grand) Crusader
		"Gormok the Impaler", "Acidmaw", "Dreadscale", "Icehowl", "Lord Jaraxxus",
		"Eydis Darkbane", "Fjola Lightbane", "Anub'arak",
		-- Naxxramas
		"Anub'Rekhan", "Grand Widow Faerlina", "Maexxna", "Noth the Plaguebringer",
		"Heigan the Unclean", "Loatheb", "Instructor Razuvious", "Gothik the Harvester",
		"Patchwerk", "Grobbulus", "Gluth", "Thaddius", "Sapphiron", "Kel'Thuzad",
		-- Other WotLK raids
		"Malygos", "Sartharion", "Onyxia",
		"Archavon the Stone Watcher", "Emalon the Storm Watcher", "Koralon the Flame Watcher", "Toravon the Ice Watcher",
		"Halion", "Baltharus the Warborn", "General Zarithrian", "Saviana Ragefire",
	}
	for i = 1, #names do
		BOSSES[names[i]] = true
	end
end

-- Boss NPC IDs -- locale-proof and more reliable than names. Either an ID match OR a
-- name match counts, so a wrong/missing ID still gets caught by the name list above.
local BOSS_IDS = {}
do
	local ids = {
		-- Ulduar
		33113, 33118, 33186, 33293,            -- Flame Leviathan, Ignis, Razorscale, XT-002
		32867, 32927, 32857,                   -- Assembly: Steelbreaker, Molgeim, Brundir
		32930, 33515, 32845, 32865, 32906,     -- Kologarn, Auriaya, Hodir, Thorim, Freya
		33350, 33271, 33288, 32871,            -- Mimiron, General Vezax, Yogg-Saron, Algalon
		-- Icecrown Citadel
		36612, 36855, 37813, 36626, 36627, 36678, -- Marrowgar, Deathwhisper, Saurfang, Festergut, Rotface, Putricide
		37972, 37973, 37970, 37955, 36853, 36597, -- Keleseth, Taldaram, Valanar, Lana'thel, Sindragosa, Lich King
		-- Trial of the (Grand) Crusader
		34796, 35144, 34799, 34797, 34780, 34496, 34497, 34564, -- Gormok, Acidmaw, Dreadscale, Icehowl, Jaraxxus, Twins, Anub
		-- Naxxramas
		15956, 15953, 15952, 15954, 15936, 16011, 16061, 16060, -- Anub'Rekhan..Gothik
		16028, 15931, 15932, 15928, 15989, 15990,               -- Patchwerk..Kel'Thuzad
		-- Other WotLK raids
		28859, 28860, 10184,                   -- Malygos, Sartharion, Onyxia
		31125, 33993, 35013, 38433,            -- VoA: Archavon, Emalon, Koralon, Toravon
		39863, 39751, 39746, 39747,            -- Ruby Sanctum: Halion, Baltharus, Zarithrian, Saviana
	}
	for i = 1, #ids do
		BOSS_IDS[ids[i]] = true
	end
end

-- 3.3.5a: pull the creature entry id out of a unit GUID ("0x" + 4 type nibbles + 4 id nibbles)
local function npcID(guid)
	if type(guid) ~= "string" then
		return nil
	end
	local id = guid:match("^0x%x%x%x%x(%x%x%x%x)")
	return id and tonumber(id, 16) or nil
end

-- Multi-NPC encounters: collapse their members into one line (by id or name).
local GROUP = {
	-- Iron Council (Assembly of Iron)
	[32867] = "Iron Council", [32927] = "Iron Council", [32857] = "Iron Council",
	["Steelbreaker"] = "Iron Council", ["Runemaster Molgeim"] = "Iron Council", ["Stormcaller Brundir"] = "Iron Council",
	-- Blood Prince Council
	[37972] = "Blood Prince Council", [37973] = "Blood Prince Council", [37970] = "Blood Prince Council",
	["Prince Keleseth"] = "Blood Prince Council", ["Prince Taldaram"] = "Blood Prince Council", ["Prince Valanar"] = "Blood Prince Council",
	-- Twin Val'kyr
	[34496] = "Twin Val'kyr", [34497] = "Twin Val'kyr",
	["Eydis Darkbane"] = "Twin Val'kyr", ["Fjola Lightbane"] = "Twin Val'kyr",
	-- Northrend Beasts
	[34796] = "Northrend Beasts", [35144] = "Northrend Beasts", [34799] = "Northrend Beasts", [34797] = "Northrend Beasts",
	["Gormok the Impaler"] = "Northrend Beasts", ["Acidmaw"] = "Northrend Beasts", ["Dreadscale"] = "Northrend Beasts", ["Icehowl"] = "Northrend Beasts",
}

local function recordBoss(guid, name)
	local id = npcID(guid)
	if not ((id and BOSS_IDS[id]) or (name and BOSSES[name])) then
		return
	end
	local cur = db and db._cur
	if not cur then
		return
	end
	local label = (id and GROUP[id]) or (name and GROUP[name]) or ((name and name ~= "") and name) or ("NPC " .. tostring(id))
	cur.bosses = cur.bosses or {}
	for i = 1, #cur.bosses do
		if cur.bosses[i].name == label then
			return -- already logged this session
		end
	end
	cur.bosses[#cur.bosses + 1] = { name = label, id = id, at = time() - cur.start }
	toast("Boss logged: " .. label, "00ddff")
	if OkanvilLogs.Refresh then
		OkanvilLogs.Refresh()
	end
end

-- ------------------------------------------------------------
-- "Log this instance?" prompt (shown once on entering an instance)
-- ------------------------------------------------------------
local function askToLog(zone)
	if not askLogF then
		askLogF = CreateFrame("Frame", nil, UIParent)
		askLogF:SetSize(280, 76)
		askLogF:SetPoint("TOP", 0, -120)
		askLogF:SetFrameStrata("FULLSCREEN_DIALOG")
		flat(askLogF, 0.97, true)
		askLogF.txt = newText(askLogF, "OVERLAY")
		askLogF.txt:SetPoint("TOP", 0, -12)
		local yes = flatButton(askLogF, "|cff00ff00Start log|r", 116, 24)
		yes:SetPoint("BOTTOMLEFT", 12, 12)
		yes:SetScript("OnClick", function()
			askLogF:Hide()
			OkanvilLogs.SetLogging(true)
		end)
		local no = flatButton(askLogF, "|cffff5555No|r", 116, 24)
		no:SetPoint("BOTTOMRIGHT", -12, 12)
		no:SetScript("OnClick", function()
			askLogF:Hide()
		end)
	end
	askLogF.txt:SetText("Log this instance?\n|cffaaaaaa" .. (zone or "") .. "|r")
	PlaySound("UI_BnetToast")
	askLogF:Show()
end

-- ------------------------------------------------------------
-- REC timer (persistent while logging; movable + lockable)
-- ------------------------------------------------------------
local function applyRecLock()
	if not rec then
		return
	end
	rec:EnableMouse(not db.recLocked) -- locked = click-through (no accidental drags mid-fight)
end

local function buildRec()
	if rec then
		return
	end
	local r = CreateFrame("Frame", "OkanvilLogs_Rec", UIParent)
	r:SetSize(160, 26)
	r:SetPoint(db.rec.point, UIParent, db.rec.point, db.rec.x, db.rec.y)
	r:SetFrameStrata("HIGH")
	flat(r, 0.9, true)
	r:SetMovable(true)
	r:RegisterForDrag("LeftButton")
	r:SetScript("OnDragStart", function(s)
		if not db.recLocked then
			s:StartMoving()
		end
	end)
	r:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		local p, _, _, x, y = s:GetPoint(1)
		db.rec.point, db.rec.x, db.rec.y = p, x, y
	end)
	local dot = newText(r, "OVERLAY")
	dot:SetPoint("LEFT", 9, 0)
	dot:SetText("|cffff3333REC|r")
	r.label = newText(r, "OVERLAY")
	r.label:SetPoint("LEFT", dot, "RIGHT", 6, 0)
	r.label:SetText("0:00")
	-- Stop button: always clickable (even when locked/click-through) to end the session
	local stop = flatButton(r, "|cffff5555Stop|r", 42, 18)
	stop:SetPoint("RIGHT", -4, 0)
	stop:SetScript("OnClick", function()
		OkanvilLogs.SetLogging(false)
	end)
	r:SetScript("OnUpdate", function(s, e)
		s._t = (s._t or 0) + e
		if s._t < 0.5 then
			return
		end
		s._t = 0
		if db._cur then
			s.label:SetText(fmtTime(time() - db._cur.start))
			-- WATCHDOG: a session is open, but is the client log ACTUALLY on? A zone change,
			-- death or ghost re-enter can silently switch LoggingCombat off while the timer
			-- keeps ticking. Detect that, self-heal, and make it visible.
			if not LoggingCombat() then
				LoggingCombat(true)
				dot:SetText("|cffffaa00REC!|r") -- amber = it had dropped and was re-armed
				if not s._dropped then
					s._dropped = true
					toast("Logging had DROPPED -- re-armed!", "ffaa00")
				end
			else
				dot:SetText("|cffff3333REC|r")
				s._dropped = false
			end
		end
		dot:SetAlpha((math.floor(GetTime() * 1.5) % 2 == 0) and 1 or 0.35) -- blink
	end)
	r:Hide()
	rec = r
	applyRecLock()
end

-- ------------------------------------------------------------
-- start / stop
-- ------------------------------------------------------------
function OkanvilLogs.SetLogging(on)
	buildRec()
	if on then
		if not LoggingCombat() then
			LoggingCombat(true)
		end
		if not db._cur then
			beginSession()
		end
		OkanvilLogs._suppressAuto = nil -- explicit start -> auto-log allowed
		rec:Show()
		toast("REC -- combat log STARTED", "00ff00")
	else
		if LoggingCombat() then
			LoggingCombat(false)
		end
		endSession()
		OkanvilLogs._suppressAuto = true -- explicit stop -> don't auto-restart until you leave the raid
		rec:Hide()
		toast("STOP -- combat log saved", "ff5555")
	end
	if OkanvilLogs.Refresh then
		OkanvilLogs.Refresh()
	end
end

-- ------------------------------------------------------------
-- UI panel (built into `parent`: standalone window OR Okanvil content)
-- ------------------------------------------------------------
function OkanvilLogs.BuildUI(parent)
	local X = 16

	-- single Start/Stop button (its label doubles as the status)
	local toggle = flatButton(parent, "", 200, 30)
	toggle:SetPoint("TOPLEFT", X, -16)
	toggle:SetScript("OnClick", function()
		OkanvilLogs.SetLogging(not isLogging())
	end)
	parent._toggle = toggle

	toggleRow(parent, "Ask to log when entering an instance", X, -60, function()
		return db.askOnEnter
	end, function(v)
		db.askOnEnter = v
	end)

	toggleRow(parent, "Lock REC timer (click-through)", X, -86, function()
		return db.recLocked
	end, function(v)
		db.recLocked = v
		applyRecLock()
	end)

	local hint = newText(parent, "OVERLAY")
	hint:SetPoint("TOPLEFT", X, -120)
	hint:SetWidth(380)
	hint:SetJustifyH("LEFT")
	hint:SetText(
		"|cff888888Logging writes to WoWCombatLog.txt. Slice/export it with the Okanvil-Logs desktop tool. Drag the REC box to move it; lock it to avoid mid-fight drags.|r"
	)

	local blbl = newText(parent, "OVERLAY")
	blbl:SetPoint("TOPLEFT", X, -166)
	blbl:SetText("|cffc0943aBosses logged this session|r")
	local blist = newText(parent, "OVERLAY")
	blist:SetPoint("TOPLEFT", X, -186)
	blist:SetWidth(380)
	blist:SetJustifyH("LEFT")
	blist:SetJustifyV("TOP")
	parent._blist = blist

	OkanvilLogs.Refresh()
end

function OkanvilLogs.Refresh()
	local p = OkanvilLogs.panel
	if not p or not p._toggle then
		return
	end
	if isLogging() then
		p._toggle.text:SetText("|cffff5555STOP logging|r")
	else
		p._toggle.text:SetText("|cff00ff00START logging|r")
	end
	if p._blist then
		local cur = db and db._cur
		local list = (cur and cur.bosses) or (db and db._lastBosses)
		local header = (cur and "this session") or "last session"
		if list and #list > 0 then
			local lines = {}
			for i = 1, #list do
				lines[i] = string.format("|cff66dd66+|r %s  |cff888888%s|r", list[i].name, fmtTime(list[i].at or 0))
			end
			p._blist:SetText("|cff666666(" .. header .. ")|r\n" .. table.concat(lines, "\n"))
		else
			p._blist:SetText("|cff888888(none yet -- boss kills appear here as they happen)|r")
		end
	end
end

-- ------------------------------------------------------------
-- standalone window (only when Okanvil isn't hosting us)
-- ------------------------------------------------------------
local function buildStandalone()
	if OkanvilLogs.win then
		return
	end
	local f = CreateFrame("Frame", "OkanvilLogs_Window", UIParent)
	f:SetSize(420, 460)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	flat(f, 0.96)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	local title = newText(f, "OVERLAY", 14)
	title:SetPoint("TOP", 0, -8)
	title:SetText("|cff66ddffOkanvil-Logs|r")
	local close = flatButton(f, "X", 22, 20)
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function()
		f:Hide()
	end)
	local body = CreateFrame("Frame", nil, f)
	body:SetPoint("TOPLEFT", 4, -30)
	body:SetPoint("BOTTOMRIGHT", -4, 4)
	OkanvilLogs.panel = body
	OkanvilLogs.BuildUI(body)
	OkanvilLogs.win = f
	f:Hide()
end

function OkanvilLogs.Toggle()
	buildStandalone()
	if OkanvilLogs.win:IsShown() then
		OkanvilLogs.win:Hide()
	else
		OkanvilLogs.win:Show()
		OkanvilLogs.Refresh()
	end
end

-- minimap button (standalone only — when hosted, use the Okanvil button instead)
local function buildMinimap()
	if OkanvilLogs.minimap then
		return
	end
	local b = CreateFrame("Button", "OkanvilLogs_MinimapButton", Minimap)
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
	icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("CENTER", 1, 1)

	local function updatePos()
		local a = math.rad(db.minimapAngle or 205)
		b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
	end
	updatePos()

	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local s = Minimap:GetEffectiveScale()
			db.minimapAngle = math.deg(math.atan2(py / s - my, px / s - mx))
			updatePos()
		end)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	b:SetScript("OnClick", function()
		OkanvilLogs.Toggle()
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("|cff66ddffOkanvil-Logs|r")
		GameTooltip:AddLine("Click: open", 1, 1, 1)
		GameTooltip:AddLine("Drag: move button", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	OkanvilLogs.minimap = b
end

-- ------------------------------------------------------------
-- events / boot
-- ------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_DISABLED") -- entered combat -> guarantee the raid is being logged
ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") -- watch for boss deaths to list them per session
ev:SetScript("OnEvent", function(_, event, arg1, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		-- cheap early-out unless a session is active; arg1 = timestamp, ... = subevent, src*, dest*
		if not db or not db._cur then
			return
		end
		if ... == "UNIT_DIED" then
			recordBoss(select(5, ...), select(6, ...)) -- destGUID, destName
		end
		return
	end
	if event == "ADDON_LOADED" and arg1 == ADDON then
		OkanvilLogsDB = OkanvilLogsDB or {}
		for k, v in pairs(defaults) do
			if OkanvilLogsDB[k] == nil then
				OkanvilLogsDB[k] = (type(v) == "table") and {} or v
				if type(v) == "table" then
					for kk, vv in pairs(v) do
						OkanvilLogsDB[k][kk] = vv
					end
				end
			end
		end
		db = OkanvilLogsDB
		-- NOTE: we intentionally KEEP db._cur across reload/relog. A session stays
		-- open until the user hits Stop, so PLAYER_ENTERING_WORLD can resume the
		-- client log (reload/teleport turn it off) without losing or splitting it.
	elseif event == "PLAYER_LOGIN" then
		buildRec()
		-- register with Okanvil if present, else run standalone
		Okanvil_Plugins = Okanvil_Plugins or {}
		Okanvil_Plugins[ADDON] = {
			title = "Combat Logs",
			icon = "Interface\\Icons\\INV_Misc_Note_01",
			build = function(panel)
				OkanvilLogs.panel = panel
				OkanvilLogs.BuildUI(panel)
			end,
			refresh = function()
				OkanvilLogs.Refresh()
			end,
		}
		if Okanvil and Okanvil.Register then
			Okanvil:Register(ADDON)
			Print("loaded -- hosted by Okanvil. |cff00ff00/oklog|r toggles logging.")
		else
			buildMinimap() -- only standalone gets its own button
			Print("loaded (standalone). |cff00ff00/oklog|r or the minimap button.")
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if not db then
			return
		end
		local inInstance, itype = IsInInstance()
		if db._cur then
			-- Session still open: a /reload, relog or in-instance teleport turns the
			-- client log back OFF. Silently RESUME -- never reset, never split, never re-ask.
			if not LoggingCombat() then
				buildRec()
				LoggingCombat(true)
				rec:Show()
				toast("REC -- resumed (still logging)", "00ff00")
			end
		elseif inInstance and not LoggingCombat() then
			-- No active session and we just entered an instance: ask once per zone.
			local zone = GetRealZoneText()
			if not zone or zone == "" then
				zone = GetZoneText()
			end
			if db.askOnEnter and zone ~= askedZone then
				askedZone = zone
				askToLog(zone)
			elseif db.autoLog and itype == "raid" then
				OkanvilLogs.SetLogging(true) -- legacy silent auto-log (askOnEnter off)
			end
		elseif not inInstance then
			askedZone = nil -- left the instance -> allow asking again on next entry
			OkanvilLogs._suppressAuto = nil -- left the raid -> auto-log may kick in again next time
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- Entered combat: guarantee a raid pull is always being logged.
		if db then
			if db._cur then
				if not LoggingCombat() then LoggingCombat(true) end -- keep an open session truly ON
			else
				local inInstance, itype = IsInInstance()
				if inInstance and itype == "raid" and not OkanvilLogs._suppressAuto then
					OkanvilLogs.SetLogging(true) -- safety net: never miss a raid boss again
				end
			end
		end
	end
end)

-- ------------------------------------------------------------
-- slash
-- ------------------------------------------------------------
SLASH_OkanvilLOGS1 = "/oklog"
SlashCmdList["OkanvilLOGS"] = function(arg)
	arg = string.lower(arg or "")
	if arg == "on" then
		OkanvilLogs.SetLogging(true)
	elseif arg == "off" then
		OkanvilLogs.SetLogging(false)
	elseif Okanvil and Okanvil.Toggle then
		Okanvil:Toggle() -- embedded: open the Okanvil window
	else
		OkanvilLogs.Toggle()
	end
end
