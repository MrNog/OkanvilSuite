-- ============================================================
-- Okanvil -- UI shell: resizable window, left nav, content panels,
-- a Home page and a built-in Okanvil settings tab (LibSharedMedia).
-- ============================================================

local Okanvil = Okanvil
local LSM = Okanvil.LSM
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"

Okanvil.panels = {}      -- key -> content frame (lazy)
Okanvil._navButtons = {} -- pooled nav buttons
Okanvil._themed = {}     -- frames to re-backdrop on alpha change
local HOME, SETTINGS = "__home", "__settings"

-- ------------------------------------------------------------
-- small widget helpers
-- ------------------------------------------------------------
local function themed(f, dark)
	Okanvil:Backdrop(f, nil, dark)
	Okanvil._themed[f] = dark and "dark" or "light"
	return f
end

local function makeButton(parent, text, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	Okanvil:Backdrop(b, 1)
	local t = Okanvil:NewText(b, "OVERLAY")
	t:SetPoint("CENTER")
	t:SetText(text)
	b.text = t
	b:SetScript("OnEnter", function(s)
		s:SetBackdropColor(0.2, 0.2, 0.25, 1)
	end)
	b:SetScript("OnLeave", function(s)
		if s._active then
			s:SetBackdropColor(0.30, 0.24, 0.10, 1)
		else
			s:SetBackdropColor(0.10, 0.10, 0.12, 1)
		end
	end)
	return b
end

-- ElvUI-ish nav entry: text + icon, highlight bar (no per-row border)
local function makeNavEntry(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetHeight(22)
	local hl = b:CreateTexture(nil, "BACKGROUND")
	hl:SetAllPoints()
	hl:SetTexture(FLAT)
	hl:SetVertexColor(0, 0, 0, 0)
	b.hl = hl
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetSize(14, 14)
	b.icon:SetPoint("LEFT", 4, 0)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b.text = Okanvil:NewText(b, "OVERLAY")
	b.text:SetPoint("LEFT", b.icon, "RIGHT", 5, 0)
	b.text:SetJustifyH("LEFT")
	b:SetScript("OnEnter", function(s)
		if not s._active then
			s.hl:SetVertexColor(0.45, 0.45, 0.55, 0.25)
		end
	end)
	b:SetScript("OnLeave", function(s)
		if not s._active then
			s.hl:SetVertexColor(0, 0, 0, 0)
		end
	end)
	return b
end

-- flat ElvUI-ish slider (no Blizzard template): thin track + small thumb + label above
local function makeSlider(parent, label, x, y, lo, hi, step, getFn, setFn, onRelease)
	local s = CreateFrame("Slider", nil, parent)
	s:SetPoint("TOPLEFT", x, y)
	s:SetSize(200, 14)
	s:SetOrientation("HORIZONTAL")
	s:SetMinMaxValues(lo, hi)
	s:SetValueStep(step)
	if s.SetObeyStepOnDrag then
		s:SetObeyStepOnDrag(true)
	end
	Okanvil:Backdrop(s, 1, true) -- the track
	s:EnableMouse(true)

	local thumb = s:CreateTexture(nil, "OVERLAY")
	thumb:SetTexture(FLAT)
	thumb:SetVertexColor(0.45, 0.45, 0.55, 1)
	thumb:SetSize(10, 18)
	s:SetThumbTexture(thumb)

	local title = Okanvil:NewText(s, "OVERLAY", "GameFontHighlightSmall")
	title:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 4)
	local function label_(v)
		title:SetText(label .. ": |cff66ddff" .. v .. "|r")
	end
	label_(getFn())
	s:SetValue(getFn())

	s:SetScript("OnValueChanged", function(_, v)
		v = math.floor(v / step + 0.5) * step
		label_(v)
		s._pending = v
		if not onRelease then
			setFn(v) -- live
		end
	end)
	if onRelease then
		-- apply only when the drag ends (scaling the window mid-drag fights the slider)
		s:SetScript("OnMouseUp", function()
			if s._pending then
				setFn(s._pending)
			end
		end)
	end
	s:SetScript("OnEnter", function()
		thumb:SetVertexColor(0.6, 0.6, 0.72, 1)
	end)
	s:SetScript("OnLeave", function()
		thumb:SetVertexColor(0.45, 0.45, 0.55, 1)
	end)
	return s
end

-- thin, flat scrollbar (ElvUI-ish) on a named Blizzard scroll frame
local function skinScroll(sf)
	local name = sf:GetName()
	if not name then
		return
	end
	local bar = _G[name .. "ScrollBar"]
	if not bar then
		return
	end
	local up, down = _G[name .. "ScrollBarScrollUpButton"], _G[name .. "ScrollBarScrollDownButton"]
	if up then
		up:SetAlpha(0)
		up:EnableMouse(false)
	end
	if down then
		down:SetAlpha(0)
		down:EnableMouse(false)
	end
	for _, r in ipairs({ bar:GetRegions() }) do
		if r.GetObjectType and r:GetObjectType() == "Texture" and r ~= bar:GetThumbTexture() then
			r:SetTexture(nil)
		end
	end
	bar:SetWidth(6)
	local thumb = bar:GetThumbTexture()
	if thumb then
		thumb:SetTexture(0.35, 0.35, 0.42, 0.9)
		thumb:SetSize(6, 50)
	end
end
Okanvil.skinScroll = skinScroll

-- custom flat dropdown with a SCROLLABLE list (handles long LSM lists)
local openDD
local function makeDropdown(parent, x, y, width, listFn, getFn, setFn, preview)
	local dd = CreateFrame("Button", nil, parent)
	dd:SetPoint("TOPLEFT", x, y)
	dd:SetSize(width, 22)
	Okanvil:Backdrop(dd, 1)
	local txt = Okanvil:NewText(dd, "OVERLAY")
	txt:SetPoint("LEFT", 6, 0)
	txt:SetPoint("RIGHT", -16, 0)
	txt:SetJustifyH("LEFT")
	dd.text = txt
	local arrow = Okanvil:NewText(dd, "OVERLAY")
	arrow:SetPoint("RIGHT", -6, 0)
	arrow:SetText("|cff888888v|r")
	local function refreshText()
		local v = getFn() or ""
		txt:SetText(v)
		if preview == "font" then
			local fp = LSM and LSM:Fetch("font", v, true)
			txt:SetFont(fp or (Okanvil:Font()), 13)
		end
	end
	refreshText()
	dd:SetScript("OnEnter", function(s)
		s:SetBackdropColor(0.18, 0.18, 0.22, 1)
	end)
	dd:SetScript("OnLeave", function(s)
		s:SetBackdropColor(0.10, 0.10, 0.12, 1)
	end)

	-- popup
	local pop = CreateFrame("Frame", nil, dd)
	pop:SetFrameStrata("FULLSCREEN_DIALOG")
	pop:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
	pop:SetWidth(width)
	Okanvil:Backdrop(pop, 1, true)
	pop:EnableMouse(true)
	pop:Hide()

	local sf = CreateFrame("ScrollFrame", nil, pop)
	sf:SetPoint("TOPLEFT", 3, -3)
	sf:SetPoint("BOTTOMRIGHT", -9, 3)
	local child = CreateFrame("Frame", nil, sf)
	child:SetSize(width - 12, 1)
	sf:SetScrollChild(child)

	local sb = CreateFrame("Slider", nil, pop)
	sb:SetPoint("TOPRIGHT", -3, -3)
	sb:SetPoint("BOTTOMRIGHT", -3, 3)
	sb:SetWidth(5)
	sb:SetOrientation("VERTICAL")
	sb:SetValueStep(1)
	local th = sb:CreateTexture(nil, "OVERLAY")
	th:SetTexture(0.4, 0.4, 0.46, 1)
	th:SetSize(5, 40)
	sb:SetThumbTexture(th)
	sb:SetScript("OnValueChanged", function(_, v)
		sf:SetVerticalScroll(v)
	end)
	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function(_, d)
		sb:SetValue(sb:GetValue() - d * 18)
	end)

	pop.rows = {}
	local function build()
		for _, r in ipairs(pop.rows) do
			r:Hide()
		end
		local font = Okanvil:Font()
		local rowH = (preview == "statusbar") and 20 or 18
		local items, y2 = listFn(), 0
		for i, val in ipairs(items) do
			local r = pop.rows[i]
			if not r then
				r = CreateFrame("Button", nil, child)
				r.tex = r:CreateTexture(nil, "ARTWORK") -- statusbar swatch preview
				r.tex:SetPoint("TOPLEFT", 1, -1)
				r.tex:SetPoint("BOTTOMRIGHT", -1, 1)
				r.tex:Hide()
				r.t = r:CreateFontString(nil, "OVERLAY") -- not registered: keep per-row preview font
				r.t:SetPoint("LEFT", 5, 0)
				r.t:SetJustifyH("LEFT")
				r.t:SetShadowColor(0, 0, 0, 1) -- readable on top of bright textures
				r.t:SetShadowOffset(1, -1)
				local hl = r:CreateTexture(nil, "HIGHLIGHT")
				hl:SetAllPoints()
				hl:SetTexture(0.3, 0.3, 0.42, 0.5)
				pop.rows[i] = r
			end
			r:SetHeight(rowH)
			r:SetWidth(width - 12)
			r:SetPoint("TOPLEFT", 0, -y2)
			local cur = (val == getFn())

			-- per-row preview
			if preview == "font" then
				local fp = LSM and LSM:Fetch("font", val, true)
				r.t:SetFont(fp or font, 13)
			else
				r.t:SetFont(font, 12)
			end
			if preview == "statusbar" then
				local tp = LSM and LSM:Fetch("statusbar", val, true)
				r.tex:SetTexture(tp or FLAT)
				r.tex:SetVertexColor(1, 1, 1, 1) -- true texture look (no tint, like ElvUI)
				r.tex:Show()
			elseif r.tex then
				r.tex:Hide()
			end

			r.t:SetText(val)
			if cur then
				r.t:SetTextColor(0.4, 0.87, 1)
			elseif preview == "statusbar" then
				r.t:SetTextColor(1, 1, 1)
			else
				r.t:SetTextColor(0.9, 0.9, 0.9)
			end

			r:SetScript("OnClick", function()
				setFn(val)
				refreshText()
				pop:Hide()
				openDD = nil
			end)
			r:Show()
			y2 = y2 + rowH
		end
		child:SetHeight(math.max(1, y2))
		local maxH = 220
		local ph = math.min(y2 + 6, maxH)
		pop:SetHeight(ph)
		local maxScroll = math.max(0, y2 - (ph - 6))
		sb:SetMinMaxValues(0, maxScroll)
		sb:SetValue(0)
		if maxScroll > 0 then
			sb:Show()
		else
			sb:Hide()
		end
	end

	dd:SetScript("OnClick", function()
		if pop:IsShown() then
			pop:Hide()
			openDD = nil
			return
		end
		if openDD and openDD ~= pop then
			openDD:Hide()
		end
		build()
		pop:Show()
		openDD = pop
	end)
	dd.refreshText = refreshText
	return dd
end
Okanvil._closeDropdown = function()
	if openDD then
		openDD:Hide()
		openDD = nil
	end
end

-- ------------------------------------------------------------
-- Shell (window)
-- ------------------------------------------------------------
function Okanvil:BuildShell()
	if self.win then
		return
	end
	local db = self.db

	local f = CreateFrame("Frame", "Okanvil_Window", UIParent)
	f:SetSize(db.window.width, db.window.height)
	f:SetPoint(db.window.point, UIParent, db.window.point, db.window.x, db.window.y)
	f:SetScale(db.scale or 1)
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetResizable(true)
	if f.SetMinResize then
		f:SetMinResize(520, 380)
	end
	themed(f)
	self.win = f

	-- header (drag)
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetPoint("TOPLEFT", 2, -2)
	hdr:SetPoint("TOPRIGHT", -2, -2)
	hdr:SetHeight(26)
	hdr:EnableMouse(true)
	hdr:RegisterForDrag("LeftButton")
	hdr:SetScript("OnDragStart", function()
		f:StartMoving()
	end)
	hdr:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		local p, _, _, x, y = f:GetPoint(1)
		db.window.point, db.window.x, db.window.y = p, x, y
	end)
	local hbg = hdr:CreateTexture(nil, "ARTWORK")
	hbg:SetTexture(FLAT)
	hbg:SetVertexColor(0.16, 0.16, 0.20, 1)
	hbg:SetAllPoints()

	local logo = f:CreateTexture(nil, "OVERLAY")
	logo:SetSize(18, 18)
	logo:SetPoint("LEFT", hdr, "LEFT", 7, 0)
	logo:SetTexture("Interface\\Icons\\Spell_Shadow_RaiseDead") -- dark necro
	logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local title = self:NewText(f, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", logo, "RIGHT", 6, 0)
	title:SetText("|cff66ddffOkanvil|r")

	local close = makeButton(hdr, "X", 22, 20)
	close:SetPoint("RIGHT", hdr, "RIGHT", -3, 0)
	close:SetFrameLevel(hdr:GetFrameLevel() + 5)
	close:SetScript("OnClick", function()
		f:Hide()
	end)

	-- left nav
	local nav = CreateFrame("Frame", nil, f)
	nav:SetPoint("TOPLEFT", 6, -32)
	nav:SetPoint("BOTTOMLEFT", 6, 6)
	nav:SetWidth(184)
	themed(nav, true)
	local navSF = CreateFrame("ScrollFrame", "Okanvil_NavSF", nav, "UIPanelScrollFrameTemplate")
	navSF:SetPoint("TOPLEFT", 4, -4)
	navSF:SetPoint("BOTTOMRIGHT", -10, 4)
	local navChild = CreateFrame("Frame", nil, navSF)
	navChild:SetSize(162, 1)
	navSF:SetScrollChild(navChild)
	skinScroll(navSF) -- thin flat scrollbar
	self.navChild = navChild

	-- content
	local content = CreateFrame("Frame", nil, f)
	content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 6, 0)
	content:SetPoint("BOTTOMRIGHT", -6, 6)
	themed(content, true)
	self.content = content

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
		db.window.width, db.window.height = f:GetWidth(), f:GetHeight()
	end)

	self:RefreshNav()
	self:ShowPanel(HOME)
	f:Hide()
end

-- ------------------------------------------------------------
-- Nav list
-- ------------------------------------------------------------
function Okanvil:RefreshNav()
	if not self.navChild then
		return
	end
	for _, b in ipairs(self._navButtons) do
		b:Hide()
	end

	-- ordered list: Home, plugins (alphabetical), Settings
	local list = { { key = HOME, title = "Home", icon = nil } }
	local names = {}
	for name in pairs(self.entries) do
		names[#names + 1] = name
	end
	table.sort(names, function(a, b)
		return (self.entries[a].title or a) < (self.entries[b].title or b)
	end)
	for _, name in ipairs(names) do
		list[#list + 1] = { key = name, title = self.entries[name].title or name, icon = self.entries[name].icon }
	end
	list[#list + 1] = { key = SETTINGS, title = "Okanvil Settings", icon = "Interface\\Icons\\Trade_Engineering" }

	local y = 0
	for i, item in ipairs(list) do
		local b = self._navButtons[i]
		if not b then
			b = makeNavEntry(self.navChild)
			self._navButtons[i] = b
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 0, -y)
		b:SetWidth(156)
		b.text:SetText(item.title)
		if item.icon then
			b.icon:SetTexture(item.icon)
			b.icon:Show()
		else
			b.icon:Hide()
		end
		local key = item.key
		b._key = key
		b:SetScript("OnClick", function()
			Okanvil:ShowPanel(key)
		end)
		b:Show()
		y = y + 24
	end
	self.navChild:SetHeight(math.max(1, y))
end

-- ------------------------------------------------------------
-- Panels
-- ------------------------------------------------------------
local function newPanel()
	local p = CreateFrame("Frame", nil, Okanvil.content)
	p:SetAllPoints(Okanvil.content)
	p:Hide()
	return p
end

function Okanvil:ShowPanel(key)
	if self._closeDropdown then
		self:_closeDropdown()
	end
	-- highlight active nav button
	for _, b in ipairs(self._navButtons) do
		b._active = (b._key == key)
		if b.hl then
			if b._active then
				b.hl:SetVertexColor(0.30, 0.24, 0.10, 0.85) -- gold = active
			else
				b.hl:SetVertexColor(0, 0, 0, 0)
			end
		end
	end

	-- build lazily
	local panel = self.panels[key]
	if not panel then
		if key == HOME then
			panel = self:BuildHome()
		elseif key == SETTINGS then
			panel = self:BuildSettings()
		else
			local entry = self.entries[key]
			if entry and entry.build then
				panel = newPanel()
				entry.build(panel) -- plugin draws its UI into `panel`
			end
		end
		self.panels[key] = panel
	end

	-- hide all, show this
	for _, p in pairs(self.panels) do
		p:Hide()
	end
	if panel then
		panel:Show()
		local entry = self.entries[key]
		if entry and entry.refresh then
			entry.refresh()
		end
	end
	self._current = key
end

function Okanvil:BuildHome()
	local p = newPanel()
	-- logo slot: if a Okanvil\Media\logo.tga is added later, show it; else big text
	local logo = p:CreateTexture(nil, "ARTWORK")
	logo:SetSize(220, 64)
	logo:SetPoint("TOP", 0, -20)
	logo:SetTexture("Interface\\AddOns\\Okanvil\\Media\\logo")
	local title = self:NewText(p, "OVERLAY")
	title._cifSize = 40
	title:SetFont(self:Font(), 40, "")
	title:SetPoint("TOP", 0, -28)
	title:SetTextColor(0.4, 0.87, 1)
	title:SetText("Okanvil")
	if logo:GetTexture() then
		title:Hide() -- real logo present -> use it
	else
		logo:Hide()
	end
	local sub = self:NewText(p, "OVERLAY", "GameFontHighlight")
	sub:SetPoint("TOP", title:IsShown() and title or logo, "BOTTOM", 0, -10)
	sub:SetText("v" .. (self.version or "1.0") .. "  --  the void in your stack trace")

	local desc = self:NewText(p, "OVERLAY", "GameFontHighlightSmall")
	desc:SetPoint("TOP", sub, "BOTTOM", 0, -24)
	desc:SetWidth(340)
	desc:SetJustifyH("CENTER")
	desc:SetText("A host for your addons. Each plugin you install shows up in the list on the left -- configure them all from one window.\n\nInstalled plugins are listed below.")

	p.count = self:NewText(p, "OVERLAY", "GameFontNormal")
	p.count:SetPoint("TOP", desc, "BOTTOM", 0, -20)

	p:SetScript("OnShow", function()
		local n = Okanvil:CountPlugins()
		if n == 0 then
			p.count:SetText("|cff888888No plugins installed yet.|r")
		else
			local names = {}
			for name, e in pairs(Okanvil.entries) do
				names[#names + 1] = "|cff66ddff* |r" .. (e.title or name)
			end
			table.sort(names)
			p.count:SetText(n .. " plugin(s):\n" .. table.concat(names, "\n"))
		end
	end)
	return p
end

function Okanvil:BuildSettings()
	local p = newPanel()
	local db = self.db
	local X = 16

	local h = self:NewText(p, "OVERLAY", "GameFontNormalLarge")
	h:SetPoint("TOPLEFT", X, -16)
	h:SetText("Okanvil Settings")

	-- Scale
	makeSlider(p, "Window scale", X, -56, 0.6, 1.4, 0.05, function()
		return db.scale
	end, function(v)
		db.scale = v
		Okanvil.win:SetScale(v)
	end, true) -- apply on release (mid-drag scaling fights the slider)

	-- BG alpha
	makeSlider(p, "Background opacity", X, -100, 0.3, 1.0, 0.05, function()
		return db.bgAlpha
	end, function(v)
		db.bgAlpha = v
		for f, kind in pairs(Okanvil._themed) do
			Okanvil:Backdrop(f, v, kind == "dark")
		end
	end)

	-- Font size
	makeSlider(p, "Font size", X, -144, 8, 20, 1, function()
		return db.fontSize
	end, function(v)
		db.fontSize = v
		Okanvil:ApplyFonts()
	end)

	-- Font (LSM)
	local fl = self:NewText(p, "OVERLAY", "GameFontNormal")
	fl:SetPoint("TOPLEFT", X, -188)
	fl:SetText("Font (text format)")
	makeDropdown(p, X, -208, 160, function()
		return (LSM and LSM:List("font")) or { db.font }
	end, function()
		return db.font
	end, function(v)
		db.font = v
		Okanvil:ApplyFonts()
	end, "font")

	-- Statusbar texture (LSM) -- for plugins that draw bars
	local tl = self:NewText(p, "OVERLAY", "GameFontNormal")
	tl:SetPoint("TOPLEFT", X + 220, -188)
	tl:SetText("Bar texture")
	makeDropdown(p, X + 220, -208, 160, function()
		return (LSM and LSM:List("statusbar")) or { db.statusbar }
	end, function()
		return db.statusbar
	end, function(v)
		db.statusbar = v
	end, "statusbar")

	if not LSM then
		local warn = self:NewText(p, "OVERLAY", "GameFontDisableSmall")
		warn:SetPoint("BOTTOMLEFT", X, 12)
		warn:SetText("LibSharedMedia not found -- using defaults.")
	end
	return p
end

-- ------------------------------------------------------------
-- Toggle
-- ------------------------------------------------------------
function Okanvil:Toggle()
	if not self.win then
		self:BuildShell()
	end
	if self.win:IsShown() then
		self.win:Hide()
	else
		self:RefreshNav()
		self.win:Show()
		self:ShowPanel(self._current or HOME)
	end
end

-- ------------------------------------------------------------
-- Minimap button
-- ------------------------------------------------------------
function Okanvil:BuildMinimap()
	if self.minimap then
		return
	end
	local b = CreateFrame("Button", "Okanvil_MinimapButton", Minimap)
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
	icon:SetTexture("Interface\\Icons\\Spell_Shadow_RaiseDead")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("CENTER", 1, 1)

	local function pos()
		local a = math.rad(Okanvil.db.minimapAngle or 200)
		b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
	end
	pos()
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local s = Minimap:GetEffectiveScale()
			Okanvil.db.minimapAngle = math.deg(math.atan2(py / s - my, px / s - mx))
			pos()
		end)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	b:SetScript("OnClick", function()
		Okanvil:Toggle()
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("|cff66ddffOkanvil|r")
		GameTooltip:AddLine("Click: open", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	self.minimap = b
end
