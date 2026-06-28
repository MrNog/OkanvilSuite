-- ============================================================
--   ██████╗██╗███████╗███████╗██████╗
--  ██╔════╝██║██╔════╝██╔════╝██╔══██╗
--  ██║     ██║█████╗  █████╗  ██████╔╝
--  ██║     ██║██╔══╝  ██╔══╝  ██╔══██╗
--  ╚██████╗██║██║     ███████╗██║  ██║
--   ╚═════╝╚═╝╚═╝     ╚══════╝╚═╝  ╚═╝
--  Okanvil-IDs -- find a spell/item ID by NAME (no need to own the item).
--  Spells: scanned fully offline from the client (Spell.dbc), so every
--  spell/aura/proc/talent is searchable. Items: HARVESTED from anything
--  your client loads (tooltips you hover -- incl. AtlasLoot --, bags, bank,
--  merchant, chat links) + a "Sweep loaded items" button. Optional "Full
--  scan" brute-forces every item id (risky on private servers).
--  Click a result -> the ID drops into a Ctrl+C-ready box.
--  Works standalone OR embeds into Okanvil.
-- ============================================================

local ADDON = "Okanvil-IDs"
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"
local QMARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local MAX_SPELL_ID = 80000 -- WotLK 3.3.5a tops out well under this
local MAX_ITEM_ID = 56000 -- upper bound for the optional full item scan
local MAX_RESULTS = 300 -- cap matches per search (keeps the UI snappy)
local ROW_H, NUM_ROWS = 18, 14

local defaults = {
	items = {}, -- [itemID] = name   (harvested; account-wide)
	auras = {}, -- [spellID] = name  (buffs/debuffs caught on you/your target)
	links = {}, -- [itemID] = { [spellID] = spellName }  -- your saved item<->buff library
	snippet = false, -- copy-box shows GetItemCount(id) instead of the raw id
}
local db

OkanvilIDs = OkanvilIDs or {} -- namespace for slash / standalone

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
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ddff[Okanvil-IDs]|r " .. tostring(msg))
end

-- transient toast (success/failure feedback)
local toastF
local function toast(msg, color)
	PlaySound("UI_BnetToast")
	if not toastF then
		toastF = CreateFrame("Frame", nil, UIParent)
		toastF:SetSize(300, 32)
		toastF:SetPoint("TOP", 0, -110)
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
	toastF._life = 4
	toastF:Show()
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

-- ------------------------------------------------------------
-- item DB (harvest)
-- ------------------------------------------------------------
local itemCount = 0
local function recountItems()
	itemCount = 0
	for _ in pairs(db.items) do
		itemCount = itemCount + 1
	end
end

-- record an item link/id (only works when the item is in the client cache,
-- which it is whenever it just showed in a tooltip/bag/etc). Returns true if new.
local function recordItem(link)
	if not link then
		return false
	end
	local id = tonumber(string.match(link, "item:(%d+)"))
	if not id then
		return false
	end
	local name = GetItemInfo(id)
	if name and db.items[id] ~= name then
		db.items[id] = name
		itemCount = itemCount + 1
		return true
	end
	return false
end

-- sweep everything currently loaded (no server requests -- all already cached)
local function sweepLoaded()
	local before = itemCount
	for slot = 1, 19 do -- equipped
		recordItem(GetInventoryItemLink("player", slot))
	end
	for bag = -1, 11 do -- backpack/bags (0-4) + bank (-1, 5-11)
		local n = GetContainerNumSlots(bag) or 0
		for s = 1, n do
			recordItem(GetContainerItemLink(bag, s))
		end
	end
	if MerchantFrame and MerchantFrame:IsShown() then
		for i = 1, GetMerchantNumItems() do
			recordItem(GetMerchantItemLink(i))
		end
	end
	-- AtlasLoot / any addon item buttons get harvested automatically when you
	-- HOVER them (the tooltip hook below), so an open AtlasLoot page fills up
	-- as you mouse over it; sweep grabs your own gear/bags/vendor instantly.
	local added = itemCount - before
	Print("swept " .. added .. " new item(s). DB now holds " .. itemCount .. ".")
	if OkanvilIDs.RefreshStatus then
		OkanvilIDs.RefreshStatus()
	end
end

-- ------------------------------------------------------------
-- aura catcher  (a proc/use buff has its OWN spell id, usually different
-- from the item id. The reliable way to get a trinket's proc id is to SEE
-- the buff land -- so every aura on you/your target is recorded here.)
-- ------------------------------------------------------------
local auraCount = 0
local recentAuras = {} -- this session, newest-first: { {id=, name=} ... }
local seenSession = {} -- [id] = true, first time caught this session

local function recountAuras()
	auraCount = 0
	for _ in pairs(db.auras) do
		auraCount = auraCount + 1
	end
end

-- store an aura; track first-seen-this-session so the Auras tab can show the
-- buff you JUST procced at the top (equip trinket -> proc -> it's right there).
local function noteAura(id, name)
	if not id or not name then
		return
	end
	if db.auras[id] == nil then
		auraCount = auraCount + 1
	end
	db.auras[id] = name
	if not seenSession[id] then
		seenSession[id] = true
		table.insert(recentAuras, 1, { id = id, name = name }) -- newest first
	end
end

local function recordAura(unit)
	if not unit or not UnitExists(unit) then
		return
	end
	for i = 1, 40 do -- buffs
		local name = UnitBuff(unit, i)
		if not name then
			break
		end
		noteAura(select(11, UnitBuff(unit, i)), name)
	end
	for i = 1, 40 do -- debuffs
		local name = UnitDebuff(unit, i)
		if not name then
			break
		end
		noteAura(select(11, UnitDebuff(unit, i)), name)
	end
end

-- ------------------------------------------------------------
-- spell index (built once per session from the client, in memory)
-- ------------------------------------------------------------
local spellIndex = {} -- { {id=, name=, nl=lower} ... }
local spellBuilt, spellBuilding = false, false
local builder = CreateFrame("Frame")

local function startSpellBuild(onDone)
	if spellBuilt then
		if onDone then
			onDone()
		end
		return
	end
	if spellBuilding then
		return
	end
	spellBuilding = true
	spellIndex = {}
	local i = 0
	builder:SetScript("OnUpdate", function(self)
		local stop = i + 2500
		while i < stop and i < MAX_SPELL_ID do
			i = i + 1
			local name = GetSpellInfo(i)
			if name and name ~= "" then
				spellIndex[#spellIndex + 1] = { id = i, name = name, nl = string.lower(name) }
			end
		end
		if OkanvilIDs.SetStatus then
			OkanvilIDs.SetStatus(string.format("Building spell index... %d%%", math.floor(i / MAX_SPELL_ID * 100)))
		end
		if i >= MAX_SPELL_ID then
			self:SetScript("OnUpdate", nil)
			spellBuilding, spellBuilt = false, true
			Print("spell index ready (" .. #spellIndex .. " spells).")
			toast("Spell index ready -- " .. #spellIndex .. " spells loaded!", "00ff00")
			if OkanvilIDs.SetStatus then
				OkanvilIDs.SetStatus(#spellIndex .. " spells indexed.")
			end
			if onDone then
				onDone()
			end
		end
	end)
end

-- ------------------------------------------------------------
-- optional FULL item scan (brute-force GetItemInfo -- risky: fires a server
-- request per uncached id). Throttled + abortable. Test once.
-- ------------------------------------------------------------
local scanning, scanFrame = false, CreateFrame("Frame")
local function stopFullScan()
	if not scanning then
		return
	end
	scanning = false
	scanFrame:SetScript("OnUpdate", nil)
	recountItems()
	Print("full scan stopped. DB holds " .. itemCount .. " item(s).")
	if OkanvilIDs.RefreshStatus then
		OkanvilIDs.RefreshStatus()
	end
end

local function startFullScan()
	if scanning then
		return
	end
	scanning = true
	local i, acc = 0, 0
	scanFrame:SetScript("OnUpdate", function(self, e)
		acc = acc + e
		if acc < 0.1 then -- ~10 batches/sec to keep the request rate low
			return
		end
		acc = 0
		local stop = i + 100 -- 100 ids/batch  -> ~1000 ids/sec
		while i < stop and i < MAX_ITEM_ID do
			i = i + 1
			local name = GetItemInfo(i) -- nil for uncached -> queues a server request
			if name and db.items[i] ~= name then
				db.items[i] = name
			end
		end
		if OkanvilIDs.SetStatus then
			OkanvilIDs.SetStatus(string.format("Full scan %d%%  (id %d) -- watch for lag/disconnect", math.floor(i / MAX_ITEM_ID * 100), i))
		end
		if i >= MAX_ITEM_ID then
			scanning = false
			self:SetScript("OnUpdate", nil)
			recountItems()
			Print("full scan complete. DB holds " .. itemCount .. " item(s).")
			toast("Full scan complete -- " .. itemCount .. " items, server held up!", "00ff00")
			if OkanvilIDs.RefreshStatus then
				OkanvilIDs.RefreshStatus()
			end
		end
	end)
	Print("|cffff5555FULL SCAN started|r -- if you lag out or disconnect, click Stop / relog and just use harvest.")
end

-- ------------------------------------------------------------
-- search helpers (the actual matching lives in buildUI's gather* funcs)
-- ------------------------------------------------------------
-- in-memory lowercase caches for name maps (rebuilt when the DB grows)
local itemLower, itemLowerN = {}, -1
local function refreshItemLower()
	if itemLowerN == itemCount then
		return
	end
	itemLower = {}
	for id, name in pairs(db.items) do
		itemLower[id] = string.lower(name)
	end
	itemLowerN = itemCount
end

local auraLower, auraLowerN = {}, -1
local function refreshAuraLower()
	if auraLowerN == auraCount then
		return
	end
	auraLower = {}
	for id, name in pairs(db.auras) do
		auraLower[id] = string.lower(name)
	end
	auraLowerN = auraCount
end

-- ------------------------------------------------------------
-- UI  (built into `parent`: standalone body OR Okanvil content panel)
-- ------------------------------------------------------------
local function buildUI(parent)
	local X = 12
	local copyBox, pickLabel, statusFS, searchBox, relatedBtn
	local linkHeader, linkRows, linkBtn
	local updateLinkedList -- forward decl (defined after the link rows exist)
	local pick = {} -- { id=, isItem= }
	local lastItem, lastSpell = {}, {} -- the last item / last spell picked, for "Link"

	-- ---- copy box rendering ----
	local function renderCopy()
		if not pick.id then
			copyBox:SetText("")
			pickLabel:SetText("")
			return
		end
		local txt
		if db.snippet and pick.isItem then
			txt = "GetItemCount(" .. pick.id .. ")"
		else
			txt = tostring(pick.id)
		end
		copyBox:SetText(txt)
		copyBox:HighlightText()
		copyBox:SetFocus()
		pickLabel:SetText((pick.name or "") .. "  |cffffd100" .. pick.id .. "|r")
	end

	-- resolve a spell name -> id via the offline spell index (exact match)
	local function findSpellIdByName(name)
		if not spellBuilt or not name then
			return nil
		end
		local nl = string.lower(name)
		for i = 1, #spellIndex do
			if spellIndex[i].nl == nl then
				return spellIndex[i].id
			end
		end
		return nil
	end

	-- when an ITEM is picked, surface its use/proc spell (no need to own it --
	-- GetItemSpell reads the cached item). Click it to copy that spell id.
	local function updateRelated()
		relatedBtn:Hide()
		relatedBtn._sid = nil
		if not (pick.id and pick.isItem) then
			return
		end
		local sName, a, b = GetItemSpell(pick.id)
		if not sName then
			return
		end
		local sId = (type(a) == "number" and a) or (type(b) == "number" and b) or findSpellIdByName(sName)
		if sId then
			relatedBtn._sid, relatedBtn._sname = sId, sName
			relatedBtn.text:SetText("|cff66ddff↳ use/proc spell:|r " .. sName .. " |cffffd100" .. sId .. "|r |cff777777(click to copy)|r")
		else
			relatedBtn.text:SetText("|cff66ddff↳ use/proc spell:|r " .. sName .. " |cff777777(search it in the Spells tab)|r")
		end
		relatedBtn:Show()
	end

	local function setPick(id, isItem, name)
		pick.id, pick.isItem, pick.name = id, isItem, name
		if isItem then
			lastItem = { id = id, name = name }
		else
			lastSpell = { id = id, name = name }
		end
		renderCopy()
		updateRelated()
		if updateLinkedList then
			updateLinkedList()
		end
	end

	local colSpell, colItem, colAura -- forward decl (the 3 result columns)

	-- shared row renderer (icon + name + id), used by every column
	local function renderRow(r, d)
		if not d then
			r._d = nil
			r:Hide()
			return
		end
		r._d = d
		local icon
		if d.isItem then
			icon = select(10, GetItemInfo(d.id))
			local q = select(3, GetItemInfo(d.id))
			if q then
				local cr, cg, cb = GetItemQualityColor(q)
				r.name:SetTextColor(cr, cg, cb)
			else
				r.name:SetTextColor(0.9, 0.9, 0.9)
			end
		else
			icon = select(3, GetSpellInfo(d.id)) -- 3rd return = icon path (reliable)
			if d.linked then
				r.name:SetTextColor(0.55, 0.8, 1.0) -- linked buff = light blue
			elseif d.proc then
				r.name:SetTextColor(0.7, 0.95, 0.7) -- GetItemSpell proc = green
			else
				r.name:SetTextColor(0.9, 0.9, 0.9)
			end
		end
		if not icon or icon == "" then
			icon = QMARK
		end
		r.icon:SetTexture(icon)
		r.name:SetText((d.linked and "» " or "") .. (d.name or "?"))
		r.id:SetText("|cffffd100" .. d.id .. "|r")
		r:Show()
	end

	-- the buffs/spells tied to an item: saved links + GetItemSpell proc
	local function aurasForItem(itemID)
		local out, seen = {}, {}
		local t = db.links[itemID]
		if t then
			for sid, sname in pairs(t) do
				if not seen[sid] then
					seen[sid] = true
					out[#out + 1] = { id = sid, name = sname, linked = true }
				end
			end
		end
		local sName, a, b = GetItemSpell(itemID)
		local sId = (type(a) == "number" and a) or (type(b) == "number" and b)
		if sName and sId and not seen[sId] then
			out[#out + 1] = { id = sId, name = sName, proc = true }
		end
		return out
	end

	-- click any row: copy its id; clicking an ITEM also pulls its buffs into col 3
	local function onRowClick(d)
		setPick(d.id, d.isItem, d.name)
		if d.isItem and colAura then
			colAura.set(aurasForItem(d.id))
		end
	end

	-- build one result column (header + scrolling list)
	local COL_W, COL_ROWS = 220, 11
	local function makeColumn(x, header, key)
		local col = { results = {} }
		local rowW = COL_W - 18
		local h = newText(parent, "OVERLAY", 12)
		h:SetPoint("TOPLEFT", x, -56)
		h:SetText("|cff66ddff" .. header .. "|r")
		col.count = newText(parent, "OVERLAY")
		col.count:SetPoint("LEFT", h, "RIGHT", 6, 0)
		local scroll = CreateFrame("ScrollFrame", "OkanvilIDs_Col" .. key, parent, "FauxScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", x, -74)
		scroll:SetSize(rowW, COL_ROWS * ROW_H)
		local bg = CreateFrame("Frame", nil, parent)
		bg:SetPoint("TOPLEFT", scroll, -3, 3)
		bg:SetPoint("BOTTOMRIGHT", scroll, 21, -3)
		flat(bg, 0.4, true)
		bg:SetFrameLevel(scroll:GetFrameLevel() - 1)
		local rows = {}
		local function update()
			local off = FauxScrollFrame_GetOffset(scroll)
			for i = 1, COL_ROWS do
				renderRow(rows[i], col.results[off + i])
			end
			FauxScrollFrame_Update(scroll, #col.results, COL_ROWS, ROW_H)
		end
		col.update = update
		scroll:SetScript("OnVerticalScroll", function(self, o)
			FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, update)
		end)
		for i = 1, COL_ROWS do
			local r = CreateFrame("Button", nil, parent)
			r:SetSize(rowW, ROW_H)
			if i == 1 then
				r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
			else
				r:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0)
			end
			r.icon = r:CreateTexture(nil, "ARTWORK")
			r.icon:SetSize(16, 16)
			r.icon:SetPoint("LEFT", 2, 0)
			r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			r.name = newText(r, "OVERLAY")
			r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
			r.name:SetJustifyH("LEFT")
			r.name:SetWidth(rowW - 16 - 46)
			r.id = newText(r, "OVERLAY")
			r.id:SetPoint("RIGHT", -4, 0)
			r.hl = r:CreateTexture(nil, "BACKGROUND")
			r.hl:SetAllPoints()
			r.hl:SetTexture(0.3, 0.5, 0.9, 0.25)
			r.hl:Hide()
			r:SetScript("OnEnter", function(s)
				s.hl:Show()
				if s._d then
					GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
					GameTooltip:SetHyperlink((s._d.isItem and "item:" or "spell:") .. s._d.id)
					GameTooltip:Show()
				end
			end)
			r:SetScript("OnLeave", function(s)
				s.hl:Hide()
				GameTooltip:Hide()
			end)
			r:SetScript("OnClick", function(s)
				if s._d then
					onRowClick(s._d)
				end
			end)
			rows[i] = r
		end
		col.set = function(list)
			col.results = list or {}
			local sb = _G["OkanvilIDs_Col" .. key .. "ScrollBar"]
			if sb then
				sb:SetValue(0)
			end
			update()
			col.count:SetText("|cff888888(" .. #col.results .. ")|r")
		end
		return col
	end

	colSpell = makeColumn(X, "Spells", "S")
	colItem = makeColumn(X + COL_W + 8, "Items", "I")
	colAura = makeColumn(X + (COL_W + 8) * 2, "Auras / linked", "A")

	-- ---- gather matches for one query ----
	local function gatherSpells(q, num)
		local out = {}
		if num then
			local n = GetSpellInfo(num)
			if n and n ~= "" then
				out[#out + 1] = { id = num, name = n }
			end
		end
		for i = 1, #spellIndex do
			local s = spellIndex[i]
			if string.find(s.nl, q, 1, true) then
				out[#out + 1] = { id = s.id, name = s.name }
				if #out >= MAX_RESULTS then
					break
				end
			end
		end
		return out
	end
	local function gatherItems(q, num, matched)
		refreshItemLower()
		local out = {}
		if num then
			local n = db.items[num] or GetItemInfo(num)
			if n then
				out[#out + 1] = { id = num, name = n, isItem = true }
				matched[num] = true
			end
		end
		for id, nl in pairs(itemLower) do
			if string.find(nl, q, 1, true) then
				out[#out + 1] = { id = id, name = db.items[id], isItem = true }
				matched[id] = true
				if #out >= MAX_RESULTS then
					break
				end
			end
		end
		return out
	end
	-- Auras / buffs ARE spells -> search the static spell library (no live listening).
	local function gatherAuras(q, num)
		local out, seen = {}, {}
		if num then
			local nm = GetSpellInfo(num)
			if nm and nm ~= "" then
				out[#out + 1] = { id = num, name = nm }
				seen[num] = true
			end
		end
		for i = 1, #spellIndex do
			local s = spellIndex[i]
			if not seen[s.id] and string.find(s.nl, q, 1, true) then
				out[#out + 1] = { id = s.id, name = s.name }
				seen[s.id] = true
				if #out >= MAX_RESULTS then
					break
				end
			end
		end
		return out
	end

	local function runSearch()
		local q = string.lower(string.gsub(searchBox:GetText() or "", "^%s*(.-)%s*$", "%1"))
		if q == "" then
			colSpell.set({})
			colItem.set({})
			colAura.set({})
			if statusFS then
				statusFS:SetText("|cffaaaaaatype a name or id -> searches the item + spell/aura library.|r")
			end
			return
		end
		local num = tonumber(q)
		local matched = {}
		colItem.set(gatherItems(q, num, matched))
		colSpell.set(gatherSpells(q, num))
		colAura.set(gatherAuras(q, num))
		if statusFS then
			statusFS:SetText("|cffaaaaaaSpells " .. #colSpell.results .. "   Items " .. #colItem.results .. "   Auras " .. #colAura.results .. "|r")
		end
	end

	local function doRun()
		if not spellBuilt then
			startSpellBuild(runSearch) -- build the spell index once, then search
		else
			runSearch()
		end
	end

	-- ---- header: title + search + item-scan buttons ----
	local title = newText(parent, "OVERLAY", 13)
	title:SetPoint("TOPLEFT", X, -10)
	title:SetText("|cff66ddffSearch a name -> Spells | Items | Auras. Click an item -> its buffs fill the Auras column.|r")

	searchBox = CreateFrame("EditBox", nil, parent)
	searchBox:SetSize(300, 24)
	searchBox:SetPoint("TOPLEFT", X, -30)
	searchBox:SetAutoFocus(false)
	searchBox:SetFontObject("GameFontHighlight")
	searchBox:SetTextInsets(6, 6, 0, 0)
	flat(searchBox, 1, true)
	searchBox:SetScript("OnEnterPressed", doRun)
	searchBox:SetScript("OnEscapePressed", function(s)
		s:ClearFocus()
	end)
	local ghost = newText(searchBox, "OVERLAY")
	ghost:SetPoint("LEFT", 6, 0)
	ghost:SetText("|cff777777type a name, press Enter|r")
	searchBox:SetScript("OnTextChanged", function(s)
		if s:GetText() == "" then
			ghost:Show()
		else
			ghost:Hide()
		end
	end)
	searchBox:SetScript("OnEditFocusGained", function()
		ghost:Hide()
	end)

	local sweep = flatButton(parent, "Sweep loaded", 110, 22)
	sweep:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
	sweep:SetScript("OnClick", function()
		sweepLoaded()
		runSearch() -- refresh the Items column with anything new
	end)
	local full = flatButton(parent, "|cffff8888Full scan|r", 90, 22)
	full:SetPoint("LEFT", sweep, "RIGHT", 6, 0)
	full:SetScript("OnClick", startFullScan)
	local stopb = flatButton(parent, "|cffff5555Stop|r", 56, 22)
	stopb:SetPoint("LEFT", full, "RIGHT", 6, 0)
	stopb:SetScript("OnClick", stopFullScan)

	-- ---- copy row ----
	local copyLabel = newText(parent, "OVERLAY")
	copyLabel:SetPoint("TOPLEFT", X, -290)
	copyLabel:SetText("Copy (|cff00ff00Ctrl+C|r):")

	copyBox = CreateFrame("EditBox", nil, parent)
	copyBox:SetSize(120, 22)
	copyBox:SetPoint("LEFT", copyLabel, "RIGHT", 8, 0)
	copyBox:SetAutoFocus(false)
	copyBox:SetFontObject("GameFontHighlight")
	copyBox:SetTextInsets(6, 6, 0, 0)
	flat(copyBox, 1, true)
	copyBox:SetScript("OnEscapePressed", function(s)
		s:ClearFocus()
	end)
	copyBox:SetScript("OnEditFocusGained", function(s)
		s:HighlightText()
	end)
	-- keep the picked value sticky: re-fill if the user clears/edits it
	copyBox:SetScript("OnTextChanged", function() end)

	local snipBtn = flatButton(parent, "", 80, 22)
	snipBtn:SetPoint("LEFT", copyBox, "RIGHT", 8, 0)
	local function paintSnip()
		snipBtn.text:SetText(db.snippet and "|cff66ddffsnippet|r" or "raw id")
	end
	paintSnip()
	snipBtn:SetScript("OnClick", function()
		db.snippet = not db.snippet
		paintSnip()
		renderCopy()
	end)

	-- "Link" creates an item<->spell association in your saved library
	local function saveLink()
		if not (lastItem.id and lastSpell.id) then
			Print("pick an ITEM (Items tab) and a SPELL/BUFF (Spells/Auras tab), then click Link.")
			return
		end
		db.links[lastItem.id] = db.links[lastItem.id] or {}
		db.links[lastItem.id][lastSpell.id] = lastSpell.name
		toast("Linked: " .. (lastItem.name or lastItem.id) .. " -> " .. (lastSpell.name or lastSpell.id), "00ff00")
		updateLinkedList()
	end
	linkBtn = flatButton(parent, "|cff66ddff⇄ Link|r", 70, 22)
	linkBtn:SetPoint("LEFT", snipBtn, "RIGHT", 8, 0)
	linkBtn:SetScript("OnClick", saveLink)
	linkBtn:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_TOP")
		GameTooltip:AddLine("Save an item<->buff link")
		GameTooltip:AddLine("item:  |cffffd100" .. (lastItem.name or "(pick one on Items tab)") .. "|r", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("spell: |cffffd100" .. (lastSpell.name or "(pick one on Spells/Auras tab)") .. "|r", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	linkBtn:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	pickLabel = newText(parent, "OVERLAY")
	pickLabel:SetPoint("TOPLEFT", copyLabel, "BOTTOMLEFT", 0, -8)
	pickLabel:SetWidth(660)
	pickLabel:SetJustifyH("LEFT")

	relatedBtn = CreateFrame("Button", nil, parent)
	relatedBtn:SetSize(660, 16)
	relatedBtn:SetPoint("TOPLEFT", pickLabel, "BOTTOMLEFT", 0, -4)
	relatedBtn.text = newText(relatedBtn, "OVERLAY")
	relatedBtn.text:SetPoint("LEFT")
	relatedBtn.text:SetJustifyH("LEFT")
	relatedBtn:SetScript("OnClick", function(s)
		if s._sid then
			setPick(s._sid, false, s._sname)
		end
	end)
	relatedBtn:Hide()

	-- ---- saved link library (item <-> buff/spell) ----
	linkHeader = newText(parent, "OVERLAY")
	linkHeader:SetPoint("TOPLEFT", relatedBtn, "BOTTOMLEFT", 0, -4)
	linkHeader:SetJustifyH("LEFT")
	linkHeader:Hide()

	local LINK_ROWS = 4
	linkRows = {}
	for i = 1, LINK_ROWS do
		local lr = CreateFrame("Button", nil, parent)
		lr:SetSize(420, 15)
		if i == 1 then
			lr:SetPoint("TOPLEFT", linkHeader, "BOTTOMLEFT", 0, -1)
		else
			lr:SetPoint("TOPLEFT", linkRows[i - 1], "BOTTOMLEFT", 0, -1)
		end
		lr.text = newText(lr, "OVERLAY")
		lr.text:SetPoint("LEFT")
		lr.text:SetJustifyH("LEFT")
		lr:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		lr:SetScript("OnClick", function(s, button)
			if not s._lid then
				return
			end
			if button == "RightButton" then
				if s._remItem and db.links[s._remItem] then
					db.links[s._remItem][s._remSpell] = nil
					local empty = true
					for _ in pairs(db.links[s._remItem]) do
						empty = false
						break
					end
					if empty then
						db.links[s._remItem] = nil
					end
				end
				updateLinkedList()
			else
				setPick(s._lid, s._lisItem, s._lname)
			end
		end)
		lr:Hide()
		linkRows[i] = lr
	end

	-- show the saved links for whatever is picked (item -> its buffs, or
	-- a buff -> the items that grant it). Click = copy, right-click = unlink.
	updateLinkedList = function()
		for i = 1, LINK_ROWS do
			linkRows[i]:Hide()
		end
		linkHeader:Hide()
		if not pick.id then
			return
		end
		local entries = {}
		if pick.isItem then
			local t = db.links[pick.id]
			if t then
				for sid, sname in pairs(t) do
					entries[#entries + 1] = { id = sid, name = sname, isItem = false, remItem = pick.id, remSpell = sid }
				end
			end
			linkHeader:SetText("|cff88ccffLinked buffs/spells:|r |cff666666(click=copy, right-click=unlink)|r")
		else
			for iid, t in pairs(db.links) do
				if t[pick.id] then
					local nm = db.items[iid] or GetItemInfo(iid) or ("item " .. iid)
					entries[#entries + 1] = { id = iid, name = nm, isItem = true, remItem = iid, remSpell = pick.id }
				end
			end
			linkHeader:SetText("|cff88ccffComes from items:|r |cff666666(click=copy, right-click=unlink)|r")
		end
		if #entries == 0 then
			return
		end
		linkHeader:Show()
		for i = 1, LINK_ROWS do
			local e, lr = entries[i], linkRows[i]
			if e then
				lr._lid, lr._lisItem, lr._lname = e.id, e.isItem, e.name
				lr._remItem, lr._remSpell = e.remItem, e.remSpell
				lr.text:SetText("   |cffffffff" .. e.name .. "|r |cffffd100" .. e.id .. "|r")
				lr:Show()
			end
		end
		if #entries > LINK_ROWS then
			linkRows[LINK_ROWS].text:SetText("   |cff888888...and " .. (#entries - LINK_ROWS + 1) .. " more (search to narrow)|r")
		end
	end

	statusFS = newText(parent, "OVERLAY")
	statusFS:SetPoint("TOPLEFT", linkRows[LINK_ROWS], "BOTTOMLEFT", 0, -8)
	statusFS:SetWidth(660)
	statusFS:SetJustifyH("LEFT")

	-- expose status setters for the background builders/scanners
	function OkanvilIDs.SetStatus(msg)
		if statusFS then
			statusFS:SetText("|cffaaaaaa" .. msg .. "|r")
		end
	end
	function OkanvilIDs.RefreshStatus()
		if statusFS then
			statusFS:SetText("|cffaaaaaaitem DB: " .. itemCount .. "   aura DB: " .. auraCount .. "|r")
		end
	end

	searchBox:SetFocus()
	runSearch() -- initial: empty box shows recent auras + the helper line
end

-- ------------------------------------------------------------
-- standalone window (only when Okanvil isn't hosting us)
-- ------------------------------------------------------------
local function buildStandalone()
	if OkanvilIDs.win then
		return
	end
	local f = CreateFrame("Frame", "OkanvilIDs_Window", UIParent)
	f:SetSize(700, 512)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	flat(f, 0.96)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	local titlefs = newText(f, "OVERLAY", 14)
	titlefs:SetPoint("TOP", 0, -8)
	titlefs:SetText("|cff66ddffOkanvil-IDs|r")
	local close = flatButton(f, "X", 22, 20)
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function()
		f:Hide()
	end)
	local body = CreateFrame("Frame", nil, f)
	body:SetPoint("TOPLEFT", 4, -30)
	body:SetPoint("BOTTOMRIGHT", -4, 4)
	buildUI(body)
	OkanvilIDs.win = f
	f:Hide()
end

function OkanvilIDs.Toggle()
	buildStandalone()
	if OkanvilIDs.win:IsShown() then
		OkanvilIDs.win:Hide()
	else
		OkanvilIDs.win:Show()
	end
end

-- ------------------------------------------------------------
-- universal item harvester (hover any item anywhere -> recorded)
-- ------------------------------------------------------------
GameTooltip:HookScript("OnTooltipSetItem", function(self)
	if not db then
		return
	end
	local _, link = self:GetItem()
	recordItem(link)
end)
ItemRefTooltip:HookScript("OnTooltipSetItem", function(self)
	if not db then
		return
	end
	local _, link = self:GetItem()
	recordItem(link)
end)

-- ------------------------------------------------------------
-- events / boot
-- ------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		OkanvilIDsDB = OkanvilIDsDB or {}
		for k, v in pairs(defaults) do
			if OkanvilIDsDB[k] == nil then
				OkanvilIDsDB[k] = (type(v) == "table") and {} or v
			end
		end
		db = OkanvilIDsDB
		recountItems()
		recountAuras()
	elseif event == "PLAYER_LOGIN" then
		sweepLoaded() -- seed the item DB from your own gear/bags once (no server hits)
		-- register with Okanvil if present, else run standalone
		Okanvil_Plugins = Okanvil_Plugins or {}
		Okanvil_Plugins[ADDON] = {
			title = "ID Finder",
			icon = "Interface\\Icons\\INV_Misc_Spyglass_02",
			build = function(panel)
				buildUI(panel)
			end,
		}
		if Okanvil and Okanvil.Register then
			Okanvil:Register(ADDON)
			Print("loaded -- hosted by Okanvil. |cff00ff00/cid|r opens the finder.")
		else
			Print("loaded (standalone). |cff00ff00/cid|r opens the finder.")
		end
	end
end)

-- ------------------------------------------------------------
-- slash
-- ------------------------------------------------------------
SLASH_OkanvilIDS1 = "/cid"
SLASH_OkanvilIDS2 = "/idfind"
SlashCmdList["OkanvilIDS"] = function(arg)
	arg = string.lower(arg or "")
	if arg == "sweep" then
		sweepLoaded()
	elseif Okanvil and Okanvil.Toggle then
		Okanvil:Toggle() -- embedded: open the Okanvil window
	else
		OkanvilIDs.Toggle()
	end
end
