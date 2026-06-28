-- ============================================================
-- Recruit  (WotLK 3.3.5a)
-- Generic guild-recruitment advertiser: auto-advertise + auto-reply
-- (AFK mode) + auto-invite, keyword + known-contact filters.
-- Guild name is configurable (default "Guild"); use {guild} in any
-- message and it is replaced with the guild name at send time.
-- Tabbed UI: Text / Settings / Filters / Whispers / Summary. Minimap button.
-- ============================================================

local ADDON = "Okanvil-Recruit" -- must match the folder/.toc name (ADDON_LOADED arg)
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"

-- ------------------------------------------------------------
-- Saved-variable defaults -- NO pre-filled text (the user inserts it all).
-- ------------------------------------------------------------
local defaults = {
	guildName = "Guild", -- used by the {guild} token and the join toast
	message = "",
	reply = "",
	afkReply = "",
	afkMode = false,
	keywords = "",
	replyCooldown = 600,
	inviteCooldown = 300,
	active = false,
	autoInvite = true,
	toastOnJoin = true, -- pop a toast when someone joins the guild
	toastOnlyActive = false, -- ...only while advertising is ON (false = always)
	filterGuild = true,
	filterGroup = true,
	filterFriends = true,
	-- per-channel spam interval in seconds (0 = off). All off by default.
	channelIntervals = { Global = 0, Trade = 0, LookingForGroup = 0, General = 0, GUILD = 0 },
	customChannel = "",
	customInterval = 0,
	blacklist = "", -- block words (gold sellers / ads); user fills it in
	minimapAngle = 210,
	log = {},
	session = {}, -- per-name recruiting tally (uncapped); cleared from the Summary tab
}

local db
local chElapsed = {} -- per-channel advertise timer accumulators
local recentInvites = {}
local repliedTo = {}

-- ------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------
local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffF1C40F[Recruit]|r " .. tostring(msg))
end

-- guild name with a safe fallback (never empty)
local function gname()
	return (db and db.guildName and db.guildName ~= "" and db.guildName) or "Guild"
end

-- replace the {guild} token with the configured guild name
local function brand(s)
	if not s or s == "" then
		return s
	end
	return (s:gsub("{guild}", gname()))
end

local function stripRealm(name)
	if not name then
		return name
	end
	local n = strsplit("-", name)
	return n
end

-- best-effort real class lookup (self / group / guild roster); nil if unknown
local function resolveClass(name)
	if not name or name == "" then
		return nil
	end
	if name == UnitName("player") then
		return select(2, UnitClass("player"))
	end
	local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
	if raidN > 0 then
		for i = 1, raidN do
			if UnitName("raid" .. i) == name then
				return select(2, UnitClass("raid" .. i))
			end
		end
	else
		local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
		for i = 1, partyN do
			if UnitName("party" .. i) == name then
				return select(2, UnitClass("party" .. i))
			end
		end
	end
	if IsInGuild and IsInGuild() then
		local total = (GetNumGuildMembers and GetNumGuildMembers()) or 0
		for i = 1, total do
			local gn = GetGuildRosterInfo(i)
			if gn then
				gn = strsplit("-", gn)
				if gn == name then
					return select(11, GetGuildRosterInfo(i))
				end
			end
		end
	end
	return nil
end

-- skip people we already know / are playing with (toggle each in Filters tab)
local function isKnownContact(name)
	if not name then
		return false
	end
	if db.filterGroup then
		local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
		if raidN > 0 then
			for i = 1, raidN do
				if UnitName("raid" .. i) == name then
					return true
				end
			end
		else
			local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
			for i = 1, partyN do
				if UnitName("party" .. i) == name then
					return true
				end
			end
		end
	end
	if db.filterFriends then
		local nf = (GetNumFriends and GetNumFriends()) or 0
		for i = 1, nf do
			local fname = GetFriendInfo(i)
			if fname then
				fname = strsplit("-", fname)
				if fname == name then
					return true
				end
			end
		end
	end
	if db.filterGuild and IsInGuild and IsInGuild() then
		local total = (GetNumGuildMembers and GetNumGuildMembers()) or 0
		for i = 1, total do
			local gn = GetGuildRosterInfo(i)
			if gn then
				gn = strsplit("-", gn)
				if gn == name then
					return true
				end
			end
		end
	end
	return false
end

-- is this name currently in MY guild? (used to hide the re-invite button)
local function isInMyGuild(name)
	if not (IsInGuild and IsInGuild()) then
		return false
	end
	local total = (GetNumGuildMembers and GetNumGuildMembers()) or 0
	for i = 1, total do
		local gn = GetGuildRosterInfo(i)
		if gn then
			gn = strsplit("-", gn)
			if gn == name then
				return true
			end
		end
	end
	return false
end

-- parse guild join/decline system messages to track an invite's outcome
local function makePattern(fmt)
	local p = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
	return (p:gsub("%%s", "(.+)"))
end
local PAT_JOIN = ERR_GUILD_JOIN_S and makePattern(ERR_GUILD_JOIN_S)
local PAT_DECLINE = ERR_GUILD_DECLINE_S and makePattern(ERR_GUILD_DECLINE_S)
local PAT_FAILS = {}
do
	local function addFail(g)
		if g and g:find("%%s") then
			PAT_FAILS[#PAT_FAILS + 1] = makePattern(g)
		end
	end
	addFail(ERR_ALREADY_IN_GUILD_S)
	addFail(ERR_ALREADY_INVITED_TO_GUILD_S)
end
local PAT_OFFLINE = ERR_GUILD_PLAYER_NOT_FOUND_S
	and ERR_GUILD_PLAYER_NOT_FOUND_S:find("%%s")
	and makePattern(ERR_GUILD_PLAYER_NOT_FOUND_S)
local PAT_FRIEND_ONLINE = ERR_FRIEND_ONLINE_SS and makePattern(ERR_FRIEND_ONLINE_SS)

local function setInviteState(name, state)
	db.session[name] = db.session[name] or {}
	db.session[name].state = state
	for i = 1, #db.log do
		local e = db.log[i]
		if e.who == name then
			e.state = state
			break
		end
	end
	if RecruitFrame and RecruitFrame.logPanel and RecruitFrame.logPanel:IsShown() then
		Rec_RefreshLog()
	end
end

-- resolve a configured channel name to the numeric id THIS player has for it.
local function resolveChannelId(name)
	if not name or name == "" then
		return nil
	end
	local asNum = tonumber(name)
	if asNum then
		return asNum
	end
	local id = GetChannelName(name)
	if id and id > 0 then
		return id
	end
	local list = { GetChannelList() } -- id1, name1, id2, name2, ...
	local target = name:lower()
	for i = 1, #list - 1, 2 do -- exact match first
		if type(list[i + 1]) == "string" and list[i + 1]:lower() == target then
			return list[i]
		end
	end
	for i = 1, #list - 1, 2 do -- then prefix ("General" -> "General - Dalaran")
		if type(list[i + 1]) == "string" and list[i + 1]:lower():find(target, 1, true) == 1 then
			return list[i]
		end
	end
	return nil
end

local function SendToChannel(name, msg)
	if not name or not msg or msg == "" then
		return
	end
	if name == "GUILD" then
		SendChatMessage(msg, "GUILD")
		return
	end
	local id = resolveChannelId(name)
	if id and id > 0 then
		SendChatMessage(msg, "CHANNEL", nil, id)
	end
end

-- ------------------------------------------------------------
-- Core engine
-- ------------------------------------------------------------
local core = CreateFrame("Frame")

core:SetScript("OnUpdate", function(self, e)
	if not db or not db.active then
		return
	end
	if not db.message or db.message == "" then
		return -- nothing to advertise until the user writes a message
	end
	-- each channel advertises on its own interval (staggered)
	for name, iv in pairs(db.channelIntervals) do
		if iv and iv > 0 then
			chElapsed[name] = (chElapsed[name] or 0) + e
			if chElapsed[name] >= iv then
				chElapsed[name] = 0
				SendToChannel(name, brand(db.message))
			end
		end
	end
	if db.customChannel ~= "" and (db.customInterval or 0) > 0 then
		chElapsed.__custom = (chElapsed.__custom or 0) + e
		if chElapsed.__custom >= db.customInterval then
			chElapsed.__custom = 0
			SendToChannel(db.customChannel, brand(db.message))
		end
	end
end)

core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_LOGIN")
core:RegisterEvent("CHAT_MSG_WHISPER")
core:RegisterEvent("CHAT_MSG_SYSTEM")

core:SetScript("OnEvent", function(self, event, arg1, arg2)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		RecruitDB = RecruitDB or {}
		for k, v in pairs(defaults) do
			if RecruitDB[k] == nil then
				if type(v) == "table" then
					RecruitDB[k] = {}
					for kk, vv in pairs(v) do
						RecruitDB[k][kk] = vv
					end
				else
					RecruitDB[k] = v
				end
			end
		end
		db = RecruitDB
		db.active = false
		if GuildRoster then
			GuildRoster()
		end
		-- register as a Okanvil plugin (Okanvil builds it lazily into its panel)
		Okanvil_Plugins = Okanvil_Plugins or {}
		Okanvil_Plugins[ADDON] = {
			title = "Recruit",
			icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
			build = function(panel)
				Rec_BuildUI(panel)
			end,
			refresh = function()
				Rec_RefreshUI()
			end,
		}
		return
	end

	if event == "PLAYER_LOGIN" then
		if not db then
			return
		end
		if Okanvil and Okanvil.Register then
			Okanvil:Register(ADDON) -- hosted: UI builds when you open the Recruit tab
			Print("loaded -- hosted by Okanvil. |cff00ff00/recruit|r opens it.")
		else
			Rec_BuildUI() -- no Okanvil: standalone window + minimap
			Rec_BuildMinimap()
			Print("loaded (standalone). |cff00ff00/recruit|r or the minimap button.")
		end
		return
	end

	if event == "CHAT_MSG_WHISPER" then
		if not db.active then
			return -- only act / log while advertising is ON
		end
		local msg, sender = arg1, arg2
		if not sender then
			return
		end
		local clean = stripRealm(sender)
		local brandedReply, brandedAfk = brand(db.reply), brand(db.afkReply)
		if msg == brandedReply or msg == brandedAfk then
			return -- ignore our own auto-reply echoing back
		end
		if isKnownContact(clean) then
			return -- guildies / party / friends: ignore entirely
		end

		local ctx = {
			known = false,
			now = GetTime(),
			lastInvite = recentInvites[clean],
			lastReply = repliedTo[clean],
			isEcho = (msg == brandedReply or msg == brandedAfk),
		}
		local decision = RecruitLogic.decide(db, msg, ctx)
		local sentReply, didInvite = nil, false
		if decision.invite then
			recentInvites[clean] = ctx.now
			GuildInvite(clean)
			didInvite = true
			Print("Guild-invited |cff00ff00" .. clean .. "|r.")
		end
		if decision.reply then
			repliedTo[clean] = ctx.now
			sentReply = brand(decision.reply)
			SendChatMessage(sentReply, "WHISPER", nil, sender)
		end

		db.session[clean] = db.session[clean] or {}
		if didInvite then
			db.session[clean].invited = true
		end
		if sentReply then
			db.session[clean].replied = true
		end

		local classFile = resolveClass(clean)
		table.insert(db.log, 1, { who = clean, msg = msg or "", inv = didInvite, state = (didInvite and "sent" or nil), reply = sentReply, class = classFile, t = date("%H:%M"), ts = time() })
		while #db.log > 50 do
			table.remove(db.log)
		end
		if RecruitFrame and RecruitFrame.logPanel and RecruitFrame.logPanel:IsShown() then
			Rec_RefreshLog()
		end
	end

	if event == "CHAT_MSG_SYSTEM" and db then
		local m = arg1 or ""
		if PAT_JOIN then
			local who = m:match(PAT_JOIN)
			if who then
				who = stripRealm(who)
				setInviteState(who, "joined")
				if db.toastOnJoin and (not db.toastOnlyActive or db.active) then
					Rec_ShowToast(who, resolveClass(who))
				end
				return
			end
		end
		if PAT_DECLINE then
			local who = m:match(PAT_DECLINE)
			if who then
				setInviteState(stripRealm(who), "declined")
				return
			end
		end
		if PAT_OFFLINE then
			local who = m:match(PAT_OFFLINE)
			if who then
				setInviteState(stripRealm(who), "offline")
				return
			end
		end
		if PAT_FRIEND_ONLINE then
			local who = m:match(PAT_FRIEND_ONLINE)
			if who then
				who = stripRealm(who)
				local s = db.session[who]
				if s and s.watch then
					s.watch = nil
					Rec_ShowToast(who, resolveClass(who), "|cff66ddffOnline now -- re-invite!|r")
				end
				return
			end
		end
		for _, p in ipairs(PAT_FAILS) do
			local who = m:match(p)
			if who then
				setInviteState(stripRealm(who), "failed")
				return
			end
		end
	end
end)

function Rec_ToggleActive(state)
	if state == nil then
		state = not db.active
	end
	db.active = state
	chElapsed = {}
	if db.active then
		local i = 0
		for name, iv in pairs(db.channelIntervals) do
			if iv and iv > 0 then
				i = i + 1
				chElapsed[name] = -(i - 1) * 5
			end
		end
	end
	if RecruitFrame then
		Rec_RefreshUI()
	end
	Rec_UpdateMinimap()
	if db.active then
		Print("advertising |cff00ff00ON|r.")
	else
		Print("advertising |cffff5555OFF|r.")
	end
end

-- ============================================================
-- UI
-- ============================================================
local CH_LIST = { "Global", "Trade", "LookingForGroup", "General", "GUILD" }

local CLASS_COLORS = {
	DEATHKNIGHT = "C41F3B",
	DRUID = "FF7D0A",
	HUNTER = "ABD473",
	MAGE = "69CCF0",
	PALADIN = "F58CBA",
	PRIEST = "FFFFFF",
	ROGUE = "FFF569",
	SHAMAN = "0070DE",
	WARLOCK = "9482C9",
	WARRIOR = "C79C6E",
}
local function nameColor(name, classFile)
	return "|cff" .. ((classFile and CLASS_COLORS[classFile]) or "F1C40F")
end

local function flatBackdrop(frame, r, g, b, a, br, bgc, bb)
	frame:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
	frame:SetBackdropColor(r, g, b, a)
	frame:SetBackdropBorderColor(br or 0.35, bgc or 0.35, bb or 0.4, 1)
end

local function makeLabel(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function makeBox(parent, name, x, y, w, h)
	local bd = CreateFrame("Frame", nil, parent)
	bd:SetPoint("TOPLEFT", x, y)
	bd:SetSize(w, h)
	flatBackdrop(bd, 0.1, 0.1, 0.12, 0.9, 0.4, 0.4, 0.45)
	local e = CreateFrame("EditBox", "Rec_" .. name, bd)
	e:SetMultiLine(false)
	e:SetMaxLetters(255)
	e:SetFontObject(ChatFontNormal)
	e:SetTextInsets(5, 5, 3, 3)
	e:SetPoint("TOPLEFT", 2, -2)
	e:SetPoint("BOTTOMRIGHT", -2, 2)
	e:SetAutoFocus(false)
	e.bd = bd
	e:SetScript("OnEscapePressed", function(s)
		s:ClearFocus()
	end)
	e:SetScript("OnEnterPressed", function(s)
		s:ClearFocus()
	end)
	e:SetScript("OnEditFocusGained", function()
		bd:SetBackdropBorderColor(0.95, 0.78, 0.2, 1)
	end)
	return e
end

-- responsive multi-line box: stretches to the parent's right edge (minus rightMargin)
local function makeScrollBox(parent, name, x, y, rightMargin, h)
	local bd = CreateFrame("Frame", nil, parent)
	bd:SetPoint("TOPLEFT", x, y)
	bd:SetPoint("RIGHT", parent, "RIGHT", -(rightMargin or 12), 0)
	bd:SetHeight(h)
	flatBackdrop(bd, 0.1, 0.1, 0.12, 0.9, 0.4, 0.4, 0.45)
	local sf = CreateFrame("ScrollFrame", "Rec_" .. name .. "SF", bd, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 5, -5)
	sf:SetPoint("BOTTOMRIGHT", -28, 5)
	local e = CreateFrame("EditBox", "Rec_" .. name, sf)
	e:SetMultiLine(true)
	e:SetMaxLetters(255)
	e:SetFontObject(ChatFontNormal)
	e:SetAutoFocus(false)
	e.bd = bd
	local function fit()
		e:SetWidth(math.max(40, sf:GetWidth() or 200))
	end
	sf:SetScript("OnSizeChanged", fit)
	fit()
	e:SetScript("OnEscapePressed", function(s)
		s:ClearFocus()
	end)
	e:SetScript("OnEditFocusGained", function()
		bd:SetBackdropBorderColor(0.95, 0.78, 0.2, 1)
	end)
	e:SetScript("OnCursorChanged", function(self, _, ypos, _, height)
		local frame = self:GetParent()
		local offset = frame:GetVerticalScroll()
		local viewH = frame:GetHeight()
		ypos = -ypos
		if ypos < offset then
			frame:SetVerticalScroll(ypos)
		elseif (ypos + height) > (offset + viewH) then
			frame:SetVerticalScroll(math.max(0, ypos + height - viewH))
		end
	end)
	sf:SetScrollChild(e)
	return e
end

local function makeCheck(parent, name, label, x, y)
	local c = CreateFrame("CheckButton", "Rec_" .. name, parent, "UICheckButtonTemplate")
	c:SetPoint("TOPLEFT", x, y)
	c:SetSize(24, 24)
	getglobal(c:GetName() .. "Text"):SetText(label)
	return c
end

local function makeFlatButton(parent, text, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	flatBackdrop(b, 0.2, 0.2, 0.24, 1, 0.4, 0.4, 0.45)
	local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	t:SetPoint("CENTER")
	t:SetText(text)
	b.text = t
	b:SetScript("OnEnter", function(s)
		s:SetBackdropColor(0.3, 0.3, 0.35, 1)
	end)
	b:SetScript("OnLeave", function(s)
		if s._active then
			s:SetBackdropColor(0.35, 0.28, 0.08, 1)
		else
			s:SetBackdropColor(0.2, 0.2, 0.24, 1)
		end
	end)
	return b
end

local function numHook(box, key, lo, hi)
	box:SetScript("OnEditFocusLost", function(s)
		local v = tonumber(s:GetText())
		if v then
			db[key] = math.max(lo, math.min(hi, math.floor(v)))
		end
		s:SetText(db[key])
		if s.bd then
			s.bd:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
		end
	end)
end

local function strHook(box, key)
	box:SetScript("OnEditFocusLost", function(s)
		db[key] = (s:GetText() or ""):gsub("\n", " ")
		if s.bd then
			s.bd:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
		end
	end)
end

-- ============================================================
-- "New member!" toast -- pops when someone joins the guild
-- ============================================================
local toast
local function Rec_ApplyToastPoint()
	if not toast then
		return
	end
	toast:ClearAllPoints()
	local p = db.toastPoint
	if p and p.point then
		toast:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
	else
		toast:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -180)
	end
end

local function Rec_BuildToast()
	if toast then
		return
	end
	local t = CreateFrame("Frame", "Recruit_Toast", UIParent)
	t:SetSize(236, 56)
	t:SetFrameStrata("FULLSCREEN_DIALOG")
	flatBackdrop(t, 0.09, 0.09, 0.11, 0.96, 0.85, 0.66, 0.2)
	t:EnableMouse(true)
	t:SetMovable(true)
	t:RegisterForDrag("LeftButton")
	t:SetScript("OnMouseDown", function(self)
		if not self.unlocked then
			self:Hide()
		end
	end)
	t:SetScript("OnDragStart", function(self)
		if self.unlocked then
			self:StartMoving()
		end
	end)
	t:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		db.toastPoint = { point = point, relPoint = relPoint, x = x, y = y }
	end)
	t:Hide()

	local icon = t:CreateTexture(nil, "ARTWORK")
	icon:SetSize(38, 38)
	icon:SetPoint("LEFT", 9, 0)
	icon:SetTexture("Interface\\Icons\\Ability_Warrior_BattleShout")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local top = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	top:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -4)
	t.top = top

	local bottom = t:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	bottom:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -4)
	t.bottom = bottom

	t:SetScript("OnUpdate", function(self, e)
		if self.unlocked then
			return
		end
		self.life = (self.life or 0) - e
		if self.life <= 0 then
			self:Hide()
		elseif self.life < 1 then
			self:SetAlpha(self.life)
		end
	end)
	toast = t
	Rec_ApplyToastPoint()
end

function Rec_ShowToast(name, classFile, title)
	if not name then
		return
	end
	Rec_BuildToast()
	if toast.unlocked then
		return
	end
	toast.top:SetText(title or ("|cffF1C40FNew member joined " .. gname() .. "!|r"))
	toast.bottom:SetText(nameColor(name, classFile) .. name .. "|r")
	toast:SetAlpha(1)
	toast.life = 5
	toast:Show()
	PlaySound("UI_BnetToast")
end

function Rec_SetToastMove(on)
	Rec_BuildToast()
	toast.unlocked = on
	if on then
		toast.top:SetText("|cffF1C40FToast preview|r")
		toast.bottom:SetText("|cff00ff00drag me, untick to lock|r")
		toast:SetAlpha(1)
		toast:Show()
		Print("Toast |cff00ff00unlocked|r -- drag it where you want, then untick to lock.")
	else
		toast:Hide()
		Print("Toast position |cffffcc00locked|r.")
	end
end

function Rec_BuildUI(parent)
	if RecruitFrame then
		return
	end

	local embedded = parent ~= nil
	local topInset = embedded and -8 or -36
	local f
	if embedded then
		f = parent -- Okanvil gives us a content panel; it owns the window chrome
	else
		f = CreateFrame("Frame", "RecruitWindow", UIParent)
		f:SetSize(480, 580)
		f:SetPoint("CENTER")
		flatBackdrop(f, 0.11, 0.11, 0.13, 0.96, 0.85, 0.66, 0.2)
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		f:SetClampedToScreen(true)
		f:Hide()

		local hdr = f:CreateTexture(nil, "ARTWORK")
		hdr:SetTexture(FLAT)
		hdr:SetVertexColor(0.18, 0.18, 0.22, 1)
		hdr:SetPoint("TOPLEFT", 2, -2)
		hdr:SetPoint("TOPRIGHT", -2, -2)
		hdr:SetHeight(28)

		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -9)
		title:SetText("|cffF1C40FRecruit|r")

		local close = makeFlatButton(f, "X", 22, 22)
		close:SetPoint("TOPRIGHT", -6, -5)
		close:SetScript("OnClick", function()
			f:Hide()
		end)

		local logo = f:CreateTexture(nil, "OVERLAY")
		logo:SetSize(20, 20)
		logo:SetPoint("TOPLEFT", 8, -5)
		logo:SetTexture("Interface\\Icons\\Ability_Warrior_BattleShout")
		logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end

	RecruitFrame = f

	-- content panels sit below the top bar (status + START) and above the tabs.
	-- Pass a content height -> the panel becomes vertically SCROLLABLE (ElvUI-style)
	-- so it never overflows onto the tabs when the window is short. The boxes inside
	-- already stretch horizontally, so the whole thing is responsive both ways.
	local hosts = {} -- content frame -> the frame to Show/Hide (scrollframe or itself)
	f._hosts = hosts
	local function newPanel(key, contentHeight)
		local host, content
		if contentHeight then
			host = CreateFrame("ScrollFrame", "Rec_panel_" .. key, f, "UIPanelScrollFrameTemplate")
			host:SetPoint("TOPLEFT", 12, topInset - 26)
			host:SetPoint("BOTTOMRIGHT", -30, 40) -- room for the scrollbar
			content = CreateFrame("Frame", nil, host)
			content:SetSize(10, contentHeight)
			host:SetScrollChild(content)
			content:SetWidth(host:GetWidth() or 400)
			host:SetScript("OnSizeChanged", function(s, w)
				content:SetWidth(w or s:GetWidth() or 400)
			end)
			host:EnableMouseWheel(true)
			host:SetScript("OnMouseWheel", function(s, delta)
				local maxs = s:GetVerticalScrollRange() or 0
				local cur = s:GetVerticalScroll() or 0
				s:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 30)))
			end)
		else
			host = CreateFrame("Frame", nil, f)
			host:SetPoint("TOPLEFT", 12, topInset - 26)
			host:SetPoint("BOTTOMRIGHT", -12, 40)
			content = host
		end
		host:Hide()
		hosts[content] = host
		return content
	end
	local tp = newPanel("text", 350) -- Text
	local stp = newPanel("settings", 410) -- Settings
	local fp = newPanel("filters", 320) -- Filters
	local lp = newPanel("log") -- Whispers (fills; has its own inner scrolls)
	local sp2 = newPanel("summary", 260) -- Summary
	f.textPanel, f.setPanel, f.filterPanel, f.logPanel, f.sumPanel = tp, stp, fp, lp, sp2

	local X = 4

	-- ---------- TEXT panel ----------
	makeLabel(tp, "Guild name (used by {guild} + toast):", X, -6)
	f.guildName = makeBox(tp, "guildName", X, -26, 260, 22)
	strHook(f.guildName, "guildName")

	makeLabel(tp, "Advertise message:  (tip: write {guild} for the name)", X, -56)
	f.msg = makeScrollBox(tp, "msg", X, -74, 12, 74)
	makeLabel(tp, "Auto-reply (on whisper):", X, -156)
	f.reply = makeScrollBox(tp, "reply", X, -174, 12, 74)
	makeLabel(tp, "AFK reply (used when AFK mode is on):", X, -256)
	f.afkReply = makeScrollBox(tp, "afkReply", X, -274, 12, 70)
	strHook(f.msg, "message")
	strHook(f.reply, "reply")
	strHook(f.afkReply, "afkReply")

	-- ---------- SETTINGS panel ----------
	makeLabel(stp, "Keywords -- whisper triggers invite (typos ok):", X, -10)
	f.keywords = makeScrollBox(stp, "keywords", X, -30, 12, 56)
	strHook(f.keywords, "keywords")

	makeLabel(stp, "Channel spam intervals (sec, 0 = off -- stagger them):", X, -98)
	f.chInputs = {}
	local function chHook(box, name)
		box:SetScript("OnEditFocusLost", function(s)
			local v = math.max(0, math.min(3600, math.floor(tonumber(s:GetText()) or 0)))
			db.channelIntervals[name] = v
			s:SetText(v)
			if s.bd then
				s.bd:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
			end
		end)
	end
	local CH_LABELS = { Global = "Global", Trade = "Trade", LookingForGroup = "LFG", General = "General", GUILD = "Guild" }
	local COL2 = X + 224
	local cols = { { lx = X, bx = X + 70 }, { lx = COL2, bx = COL2 + 70 } }
	local rowY = -124
	for i, name in ipairs(CH_LIST) do
		local col = cols[((i - 1) % 2) + 1]
		makeLabel(stp, CH_LABELS[name], col.lx, rowY)
		local box = makeBox(stp, "iv_" .. name, col.bx, rowY + 2, 48, 22)
		chHook(box, name)
		f.chInputs[name] = box
		if i % 2 == 0 then
			rowY = rowY - 30
		end
	end

	makeLabel(stp, "Custom channel + interval:", X, -214)
	f.custom = makeBox(stp, "custom", X, -234, 286, 22)
	strHook(f.custom, "customChannel")
	f.customIv = makeBox(stp, "iv_custom", COL2 + 70, -234, 48, 22)
	numHook(f.customIv, "customInterval", 0, 3600)

	makeLabel(stp, "Reply CD (s):", X, -272)
	f.replyCd = makeBox(stp, "replyCd", X + 88, -272, 48, 22)
	makeLabel(stp, "Invite CD (s):", COL2, -272)
	f.inviteCd = makeBox(stp, "inviteCd", COL2 + 88, -272, 48, 22)
	numHook(f.replyCd, "replyCooldown", 0, 3600)
	numHook(f.inviteCd, "inviteCooldown", 0, 3600)

	local cdNote = stp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	cdNote:SetPoint("TOPLEFT", X, -300)
	cdNote:SetWidth(440)
	cdNote:SetJustifyH("LEFT")
	cdNote:SetText("Give each channel a different interval to stagger spam (not all at once). Cooldown = silence per person after replying/inviting. 0 = off.")

	f.cInvite = makeCheck(stp, "autoInvite", "Auto-invite (+ welcome)", X, -334)
	f.cInvite:SetScript("OnClick", function(s)
		db.autoInvite = s:GetChecked() and true or false
	end)
	f.cAfk = makeCheck(stp, "afkMode", "AFK mode", COL2, -334)
	f.cAfk:SetScript("OnClick", function(s)
		db.afkMode = s:GetChecked() and true or false
		Rec_RefreshUI()
	end)
	f.cToast = makeCheck(stp, "toastOnJoin", "Toast on guild join", X, -362)
	f.cToast:SetScript("OnClick", function(s)
		db.toastOnJoin = s:GetChecked() and true or false
	end)
	f.cToastActive = makeCheck(stp, "toastOnlyActive", "only while advertising ON", COL2, -362)
	f.cToastActive:SetScript("OnClick", function(s)
		db.toastOnlyActive = s:GetChecked() and true or false
	end)
	f.cToastMove = makeCheck(stp, "toastMove", "Move toast (drag it, untick to lock)", X, -390)
	f.cToastMove:SetScript("OnClick", function(s)
		Rec_SetToastMove(s:GetChecked() and true or false)
	end)

	-- ---------- FILTERS panel ----------
	makeLabel(fp, "Don't auto-reply / invite if the whisperer is:", X, -8)
	f.fGuild = makeCheck(fp, "filterGuild", "In my guild", X, -36)
	f.fGuild:SetScript("OnClick", function(s)
		db.filterGuild = s:GetChecked() and true or false
	end)
	f.fGroup = makeCheck(fp, "filterGroup", "In my party / raid", X, -66)
	f.fGroup:SetScript("OnClick", function(s)
		db.filterGroup = s:GetChecked() and true or false
	end)
	f.fFriends = makeCheck(fp, "filterFriends", "On my friends list", X, -96)
	f.fFriends:SetScript("OnClick", function(s)
		db.filterFriends = s:GetChecked() and true or false
	end)
	local note = fp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", X, -136)
	note:SetWidth(430)
	note:SetJustifyH("LEFT")
	note:SetText("Turn a filter OFF to test on yourself/guildies. The addon only ever replies/invites on a keyword whisper anyway.")

	makeLabel(fp, "Block words -- ignore whisper if it has any (gold sellers / ads):", X, -176)
	f.blacklist = makeScrollBox(fp, "blacklist", X, -196, 12, 70)
	strHook(f.blacklist, "blacklist")
	local bnote = fp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	bnote:SetPoint("TOPLEFT", X, -272)
	bnote:SetWidth(440)
	bnote:SetJustifyH("LEFT")
	bnote:SetText("Comma-separated. Beats keywords -- e.g. 'inv pls i pay 10 gold' is ignored because of 'gold'. Typos caught too.")

	-- ---------- WHISPERS panel ----------
	local function makeSMF(parent)
		local s = CreateFrame("ScrollingMessageFrame", nil, parent)
		s:SetPoint("TOPLEFT", 6, -6)
		s:SetPoint("BOTTOMRIGHT", -6, 6)
		s:SetFontObject(GameFontHighlightSmall)
		s:SetJustifyH("LEFT")
		s:SetMaxLines(120)
		s:SetFading(false)
		s:EnableMouseWheel(true)
		s:SetScript("OnMouseWheel", function(self, delta)
			if delta > 0 then
				self:ScrollUp()
			else
				self:ScrollDown()
			end
		end)
		return s
	end
	-- contacts column (fixed width, right side); log fills everything to its left
	local namebg = CreateFrame("Frame", nil, lp)
	namebg:SetPoint("TOPRIGHT", 0, -20)
	namebg:SetPoint("BOTTOMRIGHT", 0, 30)
	namebg:SetWidth(240)
	flatBackdrop(namebg, 0.08, 0.08, 0.1, 0.85, 0.4, 0.4, 0.45)

	local logbg = CreateFrame("Frame", nil, lp)
	logbg:SetPoint("TOPLEFT", 0, -20)
	logbg:SetPoint("BOTTOMRIGHT", namebg, "BOTTOMLEFT", -8, 0)
	flatBackdrop(logbg, 0.08, 0.08, 0.1, 0.85, 0.4, 0.4, 0.45)
	f.logBox = makeSMF(logbg)

	local logsLbl = lp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	logsLbl:SetPoint("BOTTOMLEFT", logbg, "TOPLEFT", 2, 2)
	logsLbl:SetText("Logs")
	local contactsLbl = lp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	contactsLbl:SetPoint("BOTTOMLEFT", namebg, "TOPLEFT", 2, 2)
	contactsLbl:SetText("Contacts made")

	local leg = namebg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	leg:SetPoint("TOPLEFT", 6, -6)
	leg:SetPoint("TOPRIGHT", -6, -6)
	leg:SetJustifyH("LEFT")
	leg:SetText("|cffffcc00+ sent|r\n|cff00ff00OK joined|r\n|cffff5555X declined|r\n|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12|t|cffff5555 in guild|r\n|cffaaaaaaoff offline -- [+f] = friend & ping when online|r")
	local div = namebg:CreateTexture(nil, "ARTWORK")
	div:SetTexture(FLAT)
	div:SetVertexColor(0.4, 0.4, 0.45, 1)
	div:SetHeight(1)
	div:SetPoint("TOPLEFT", 6, -78)
	div:SetPoint("TOPRIGHT", -6, -78)

	local csf = CreateFrame("ScrollFrame", "Rec_contactSF", namebg, "UIPanelScrollFrameTemplate")
	csf:SetPoint("TOPLEFT", 6, -84)
	csf:SetPoint("BOTTOMRIGHT", -24, 6)
	local cchild = CreateFrame("Frame", nil, csf)
	cchild:SetSize(196, 1)
	csf:SetScrollChild(cchild)
	f.contactChild = cchild
	f.contactRows = {}
	local clr = makeFlatButton(lp, "Clear log", 110, 22)
	clr:SetPoint("BOTTOM", 0, 4)
	clr:SetScript("OnClick", function()
		wipe(db.log)
		Rec_RefreshLog()
	end)

	lp:SetScript("OnUpdate", function(self, el)
		self._t = (self._t or 0) + el
		if self._t > 1 then
			self._t = 0
			Rec_RenderContacts()
		end
	end)

	-- ---------- SUMMARY panel ----------
	makeLabel(sp2, "Recruiting summary (this session):", X, -6)
	f.summary = sp2:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.summary:SetPoint("TOPLEFT", X, -34)
	f.summary:SetPoint("TOPRIGHT", -X, -34)
	f.summary:SetJustifyH("LEFT")
	f.summary:SetJustifyV("TOP")
	local sclr = makeFlatButton(sp2, "Clear summary", 140, 24)
	sclr:SetPoint("BOTTOM", 0, 6)
	sclr:SetScript("OnClick", function()
		wipe(db.session)
		Rec_RefreshSummary()
	end)

	-- ----- top bar: status + START (top-right, never overlaps content) -----
	local btn = makeFlatButton(f, "START advertising", 150, 22)
	btn:SetPoint("TOPRIGHT", -10, topInset)
	btn:SetScript("OnClick", function()
		Rec_ToggleActive()
	end)
	f.toggleBtn = btn

	f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.status:SetPoint("RIGHT", btn, "LEFT", -10, 0)
	f.status:SetJustifyH("RIGHT")

	-- ----- tabs -----
	local tabs = {}
	local function showTab(which)
		hosts[tp]:Hide()
		hosts[stp]:Hide()
		hosts[fp]:Hide()
		hosts[lp]:Hide()
		hosts[sp2]:Hide()
		if which == "text" then
			hosts[tp]:Show()
		elseif which == "settings" then
			hosts[stp]:Show()
		elseif which == "filters" then
			hosts[fp]:Show()
		elseif which == "summary" then
			hosts[sp2]:Show()
			Rec_RefreshSummary()
		else
			hosts[lp]:Show()
			Rec_RefreshLog()
		end
		for key, b in pairs(tabs) do
			b._active = (key == which)
			b:GetScript("OnLeave")(b)
		end
	end

	local defs = { { "text", "Text" }, { "settings", "Settings" }, { "filters", "Filters" }, { "log", "Whispers" }, { "summary", "Summary" } }
	local prev
	for _, d in ipairs(defs) do
		local b = makeFlatButton(f, d[2], 84, 24)
		if prev then
			b:SetPoint("LEFT", prev, "RIGHT", 5, 0)
		else
			b:SetPoint("BOTTOMLEFT", 12, 12)
		end
		b:SetScript("OnClick", function()
			showTab(d[1])
		end)
		tabs[d[1]] = b
		prev = b
	end
	f.showTab = showTab

	showTab("text")
	Rec_RefreshUI()
end

function Rec_RefreshUI()
	local f = RecruitFrame
	if not f then
		return
	end
	f.guildName:SetText(db.guildName or "")
	f.msg:SetText(db.message or "")
	f.reply:SetText(db.reply or "")
	f.afkReply:SetText(db.afkReply or "")
	f.keywords:SetText(db.keywords or "")
	f.custom:SetText(db.customChannel or "")
	f.customIv:SetText(db.customInterval or 0)
	f.replyCd:SetText(db.replyCooldown or 600)
	f.inviteCd:SetText(db.inviteCooldown or 300)
	f.cInvite:SetChecked(db.autoInvite)
	f.cAfk:SetChecked(db.afkMode)
	f.cToast:SetChecked(db.toastOnJoin)
	f.cToastActive:SetChecked(db.toastOnlyActive)
	f.fGuild:SetChecked(db.filterGuild)
	f.fGroup:SetChecked(db.filterGroup)
	f.fFriends:SetChecked(db.filterFriends)
	f.blacklist:SetText(db.blacklist or "")
	for name, box in pairs(f.chInputs) do
		box:SetText(db.channelIntervals[name] or 0)
	end
	local afkTag = db.afkMode and "  |cff88aaff(AFK reply active)|r" or ""
	if db.active then
		f.toggleBtn.text:SetText("STOP advertising")
		f.status:SetText("|cff00ff00Advertising ON|r" .. afkTag)
	else
		f.toggleBtn.text:SetText("START advertising")
		f.status:SetText("|cffff5555Advertising OFF|r" .. afkTag)
	end
end

local SKULL = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12|t"

local function stateTag(state)
	if state == "sent" then
		return "|cffffcc00[sent]|r "
	elseif state == "joined" then
		return "|cff00ff00[joined]|r "
	elseif state == "declined" then
		return "|cffff5555[declined]|r "
	elseif state == "failed" then
		return SKULL .. "|cffff5555[failed]|r "
	elseif state == "offline" then
		return "|cffaaaaaa[offline]|r "
	end
	return ""
end

local function stateMark(state)
	if state == "sent" then
		return " |cffffcc00+|r"
	elseif state == "joined" then
		return " |cff00ff00OK|r"
	elseif state == "declined" then
		return " |cffff5555X|r"
	elseif state == "failed" then
		return " " .. SKULL
	elseif state == "offline" then
		return " |cffaaaaaaoff|r"
	end
	return ""
end

local function fmtCD(remain)
	remain = math.floor(remain)
	if remain >= 60 then
		return string.format("%dm%02ds", math.floor(remain / 60), remain % 60)
	end
	return remain .. "s"
end

function Rec_InviteContact(name)
	recentInvites[name] = GetTime()
	GuildInvite(name)
	db.session[name] = db.session[name] or {}
	db.session[name].invited = true
	for i = 1, #db.log do
		if db.log[i].who == name then
			db.log[i].state = "sent"
			break
		end
	end
	Print("Guild-invited |cff00ff00" .. name .. "|r.")
	Rec_RenderContacts()
end

function Rec_AddWatchFriend(name)
	if not name or name == "" then
		return
	end
	if AddFriend then
		AddFriend(name)
	end
	db.session[name] = db.session[name] or {}
	db.session[name].watch = true
	Print("Added |cff00ff00" .. name .. "|r to friends -- you'll get a toast when they come online.")
	Rec_RenderContacts()
end

function Rec_RenderContacts()
	local f = RecruitFrame
	if not f or not f.contactChild then
		return
	end
	for _, row in ipairs(f.contactRows) do
		row:Hide()
	end
	local seen, list = {}, {}
	for i = 1, #db.log do
		local e = db.log[i]
		if not seen[e.who] then
			seen[e.who] = true
			list[#list + 1] = e
		end
	end
	local n = #list
	local now = GetTime()
	for k = 1, n do
		local e = list[n - k + 1]
		local row = f.contactRows[k]
		if not row then
			row = CreateFrame("Frame", nil, f.contactChild)
			row:SetSize(196, 18)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			row.label:SetPoint("LEFT", 0, 0)
			row.label:SetJustifyH("LEFT")
			row.label:SetWordWrap(false)
			row.btn = makeFlatButton(row, "inv", 34, 16)
			row.btn:SetPoint("RIGHT", 0, 0)
			row.fbtn = makeFlatButton(row, "+f", 28, 16)
			row.fbtn:SetPoint("RIGHT", row.btn, "LEFT", -4, 0)
			f.contactRows[k] = row
		end
		row:SetPoint("TOPLEFT", 0, -(k - 1) * 20)
		row:Show()
		row.label:SetText(nameColor(e.who, e.class) .. e.who .. "|r" .. stateMark(e.state))
		local who = e.who
		if e.state == "offline" and not (db.session[e.who] and db.session[e.who].watch) then
			row.fbtn:Show()
			row.fbtn:SetScript("OnClick", function()
				Rec_AddWatchFriend(who)
			end)
		else
			row.fbtn:Hide()
		end
		if e.state == "joined" or isInMyGuild(e.who) then
			row.btn:Hide()
			row.label:SetWidth(160)
		else
			row.btn:Show()
			local last = recentInvites[e.who]
			local remain = last and ((db.inviteCooldown or 300) - (now - last)) or 0
			row.btn.text:SetText(remain > 0 and fmtCD(remain) or "inv")
			row.btn:SetScript("OnClick", function()
				Rec_InviteContact(who)
			end)
			row.label:SetWidth(row.fbtn:IsShown() and 122 or 160)
		end
	end
	local h = math.max(1, n * 20)
	f.contactChild:SetHeight(h)
	local sf = f.contactChild:GetParent()
	if n > (f._lastContactCount or 0) then
		sf:SetVerticalScroll(math.max(0, h - sf:GetHeight()))
	end
	f._lastContactCount = n
end

function Rec_RefreshLog()
	local f = RecruitFrame
	if not f or not f.logBox then
		return
	end
	f.logBox:Clear()
	if #db.log == 0 then
		f.logBox:AddMessage("|cff888888No whispers yet.|r")
		Rec_RenderContacts()
		return
	end
	for i = #db.log, 1, -1 do
		local e = db.log[i]
		f.logBox:AddMessage(
			"|cff888888" .. e.t .. "|r " .. stateTag(e.state) .. nameColor(e.who, e.class) .. e.who .. "|r|cffdddddd: " .. (e.msg or "") .. "|r"
		)
		if e.reply and e.reply ~= "" then
			f.logBox:AddMessage("    |cff66bbff>> " .. e.reply .. "|r")
		end
	end
	Rec_RenderContacts()
end

function Rec_RefreshSummary()
	local f = RecruitFrame
	if not f or not f.summary then
		return
	end
	local contacts, joined, declined, failed, offline, sent, noState, replied = 0, 0, 0, 0, 0, 0, 0, 0
	for _, v in pairs(db.session) do
		contacts = contacts + 1
		if v.state == "joined" then
			joined = joined + 1
		elseif v.state == "declined" then
			declined = declined + 1
		elseif v.state == "failed" then
			failed = failed + 1
		elseif v.state == "offline" then
			offline = offline + 1
		elseif v.invited then
			sent = sent + 1
		else
			noState = noState + 1
		end
		if v.replied then
			replied = replied + 1
		end
	end
	f.summary:SetText(table.concat({
		"|cffffffffContacts reached:|r  " .. contacts,
		"|cffffffffInvited:|r  " .. (sent + joined + declined + failed + offline),
		"   |cff00ff00joined guild:|r  " .. joined,
		"   |cffff5555declined:|r  " .. declined,
		"   " .. SKULL .. "|cffff5555 already in a guild:|r  " .. failed,
		"   |cffaaaaaaoffline (retry):|r  " .. offline,
		"   |cffffcc00sent, waiting:|r  " .. sent,
		" ",
		"|cff88aaffReplied to:|r  " .. replied,
		"|cffffcc00To follow up later:|r  " .. (sent + noState + offline),
	}, "\n"))
end

function Rec_Toggle()
	if not RecruitFrame then
		Rec_BuildUI()
	end
	if RecruitFrame:IsShown() then
		RecruitFrame:Hide()
	else
		Rec_RefreshUI()
		RecruitFrame:Show()
	end
end

-- ============================================================
-- Minimap button
-- ============================================================
function Rec_UpdateMinimap()
	if not Recruit_MinimapButton or not Recruit_MinimapButton.icon then
		return
	end
	local icon = Recruit_MinimapButton.icon
	if db and db.active then
		icon:SetDesaturated(false)
		icon:SetVertexColor(1, 1, 1)
	else
		icon:SetDesaturated(true)
		icon:SetVertexColor(0.5, 0.5, 0.5)
	end
end

function Rec_BuildMinimap()
	if Recruit_MinimapButton then
		return
	end
	local b = CreateFrame("Button", "Recruit_MinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")

	local overlay = b:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetTexture("Interface\\Icons\\Ability_Warrior_BattleShout")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("CENTER", 1, 1)
	b.icon = icon

	local function updatePos()
		local angle = math.rad(db.minimapAngle or 210)
		local r = 80
		b:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(angle), r * math.sin(angle))
	end
	updatePos()

	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			px, py = px / scale, py / scale
			db.minimapAngle = math.deg(math.atan2(py - my, px - mx))
			updatePos()
		end)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	b:SetScript("OnClick", function(self, button)
		if IsShiftKeyDown() then
			Rec_Toggle()
		elseif button == "RightButton" then
			Rec_ToggleActive()
		else
			Rec_Toggle()
		end
	end)

	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("|cffF1C40FRecruit|r")
		GameTooltip:AddLine("Left-click / Shift-click: open", 1, 1, 1)
		GameTooltip:AddLine("Right-click: toggle advertising", 1, 1, 1)
		GameTooltip:AddLine("Drag: move button", 1, 1, 1)
		GameTooltip:AddLine(db.active and "|cff00ff00Status: ON|r" or "|cffff5555Status: OFF|r")
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	Rec_UpdateMinimap()
end

-- ============================================================
-- Slash
-- ============================================================
SLASH_RECRUIT1 = "/recruit"
SLASH_RECRUIT2 = "/okrec"
SlashCmdList["RECRUIT"] = function(arg)
	arg = string.lower(arg or "")
	if arg == "on" then
		Rec_ToggleActive(true)
	elseif arg == "off" then
		Rec_ToggleActive(false)
	elseif arg == "afk" then
		db.afkMode = not db.afkMode
		Rec_RefreshUI()
		Print("AFK mode " .. (db.afkMode and "|cff00ff00ON|r" or "|cffff5555OFF|r") .. ".")
	elseif arg == "clear" then
		wipe(db.log)
		if RecruitFrame then
			Rec_RefreshLog()
		end
		Print("whisper log cleared.")
	elseif arg == "toast" then
		Rec_ShowToast(UnitName("player"), select(2, UnitClass("player")))
	elseif arg == "channels" then
		local list = { GetChannelList() }
		if #list == 0 then
			Print("you are not in any channels.")
		else
			Print("your channels (number = name):")
			for i = 1, #list - 1, 2 do
				Print("  |cff00ff00" .. tostring(list[i]) .. "|r = " .. tostring(list[i + 1]))
			end
		end
	elseif Okanvil and Okanvil.Toggle then
		Okanvil:Toggle() -- hosted: open the Okanvil window (pick Recruit in the list)
	else
		Rec_Toggle() -- standalone window
	end
end
