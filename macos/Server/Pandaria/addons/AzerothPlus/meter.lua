-- Damage meter: damage done by you, your group and its pets and guardians (they count for their
-- owner), for the current fight and overall, read from the combat log.

local AP = AzerothPlus

local BARS, WIDTH, BAR_H = 8, 210, 16

-- Where each damage event's amount sits among the combat log's arguments (after the 11 every
-- event has: timestamp, event, hideCaster, source guid/name/flags/raid flags, dest the same).
local AMOUNT = {
  SWING_DAMAGE = 12,
  RANGE_DAMAGE = 15,
  SPELL_DAMAGE = 15,
  SPELL_PERIODIC_DAMAGE = 15,
  SPELL_BUILDING_DAMAGE = 15,
  DAMAGE_SHIELD = 15,
  DAMAGE_SPLIT = 15,
}

-- Who counts, by GUID: the player, the group, and every pet mapped to its owner's name.
local owners = {}
local classes = {}
local function roster()
  owners, classes = {}, {}
  local function add(unit, pet)
    if UnitExists(unit) then
      local name = UnitName(unit)
      owners[UnitGUID(unit)] = name
      classes[name] = select(2, UnitClass(unit))
      if UnitExists(pet) then owners[UnitGUID(pet)] = name end
    end
  end
  add("player", "pet")
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do add("raid" .. i, "raidpet" .. i) end
  else
    for i = 1, GetNumSubgroupMembers() do add("party" .. i, "partypet" .. i) end
  end
end

local MINE = COMBATLOG_OBJECT_AFFILIATION_MINE
local CONTROLLED = bit.bor(COMBATLOG_OBJECT_TYPE_PET, COMBATLOG_OBJECT_TYPE_GUARDIAN)

-- The owner's name for a source, or nil when it is nobody of ours. Your own totems, guardians
-- and summons are not in the roster but carry your affiliation.
local function ownerOf(guid, flags)
  local name = owners[guid]
  if name then return name end
  if flags and bit.band(flags, MINE) ~= 0 and bit.band(flags, CONTROLLED) ~= 0 then
    return UnitName("player")
  end
end

local function classColor(name)
  local c = RAID_CLASS_COLORS and classes[name] and RAID_CLASS_COLORS[classes[name]]
  if c then return c.r, c.g, c.b end
  return 0.6, 0.6, 0.6
end

-- Two segments; a fight starts with the first hit or entering combat and ends leaving combat.
local segments = {
  current = { damage = {}, total = 0, time = 0 },
  overall = { damage = {}, total = 0, time = 0 },
}
local fightStart
local view = "current"

local window = CreateFrame("Frame", "AzerothPlusMeter", UIParent)
window:SetWidth(WIDTH)
window:SetHeight(20 + BARS * (BAR_H + 1) + 4)
window:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
window:SetBackdropColor(0, 0, 0, 0.7)
window:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
window.alwaysDrag = true
AP:Movable(window, "meter", "Damage meter", "BOTTOMRIGHT", -200, 160)
window:EnableMouse(true)

local title = CreateFrame("Button", nil, window)
title:SetPoint("TOPLEFT", window, "TOPLEFT", 6, -4)
title:SetPoint("TOPRIGHT", window, "TOPRIGHT", -24, -4)
title:SetHeight(14)
title.text = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title.text:SetPoint("LEFT", title, "LEFT", 0, 0)
title:RegisterForClicks("LeftButtonUp")

local reset = CreateFrame("Button", nil, window)
reset:SetWidth(14)
reset:SetHeight(14)
reset:SetPoint("TOPRIGHT", window, "TOPRIGHT", -6, -4)
reset.text = reset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
reset.text:SetPoint("CENTER", reset, "CENTER", 0, 0)
reset.text:SetText("R")

local bars = {}
for i = 1, BARS do
  local bar = CreateFrame("StatusBar", nil, window)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetHeight(BAR_H)
  bar:SetPoint("TOPLEFT", window, "TOPLEFT", 5, -20 - (i - 1) * (BAR_H + 1))
  bar:SetPoint("TOPRIGHT", window, "TOPRIGHT", -5, -20 - (i - 1) * (BAR_H + 1))
  bar:SetMinMaxValues(0, 1)
  bar.left = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.left:SetPoint("LEFT", bar, "LEFT", 3, 0)
  bar.right = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.right:SetPoint("RIGHT", bar, "RIGHT", -3, 0)
  bar:Hide()
  bars[i] = bar
end

local function seconds(seg)
  local t = seg.time
  if fightStart then t = t + (GetTime() - fightStart) end
  return math.max(t, 1)
end

local function redraw()
  local seg = segments[view]
  title.text:SetText(view == "current" and "Damage: current fight" or "Damage: overall")
  local list = {}
  for name, amount in pairs(seg.damage) do table.insert(list, { name = name, amount = amount }) end
  table.sort(list, function(a, b) return a.amount > b.amount end)
  local top = list[1] and list[1].amount or 1
  local t = seconds(seg)
  for i = 1, BARS do
    local bar, row = bars[i], list[i]
    if row then
      bar:SetValue(row.amount / top)
      bar:SetStatusBarColor(classColor(row.name))
      bar.left:SetText(i .. ". " .. row.name)
      bar.right:SetText(AP:FormatNumber(row.amount) .. " (" .. AP:FormatNumber(row.amount / t) .. ")")
      bar:Show()
    else
      bar:Hide()
    end
  end
end

local function startFight()
  if fightStart then return end
  segments.current = { damage = {}, total = 0, time = 0 }
  fightStart = GetTime()
end

local function endFight()
  if not fightStart then return end
  local t = GetTime() - fightStart
  segments.current.time = segments.current.time + t
  segments.overall.time = segments.overall.time + t
  fightStart = nil
  redraw()
end

local function record(owner, amount)
  startFight()
  for _, seg in pairs(segments) do
    seg.damage[owner] = (seg.damage[owner] or 0) + amount
    seg.total = seg.total + amount
  end
end

window:SetScript("OnEvent", function(self, event, ...)
  if event == "COMBAT_LOG_EVENT_UNFILTERED" then
    local _, kind, _, sourceGUID, _, sourceFlags = ...
    local at = AMOUNT[kind]
    if not at then return end
    local owner = ownerOf(sourceGUID, sourceFlags)
    local amount = owner and select(at, ...)
    if amount and amount > 0 then record(owner, amount) end
  elseif event == "PLAYER_REGEN_DISABLED" then
    startFight()
  elseif event == "PLAYER_REGEN_ENABLED" then
    endFight()
  else
    roster()
  end
end)

local since = 0
window:SetScript("OnUpdate", function(self, elapsed)
  since = since + elapsed
  if since >= 0.5 then
    since = 0
    redraw()
  end
end)

title:SetScript("OnClick", function()
  view = view == "current" and "overall" or "current"
  redraw()
end)

local function resetAll()
  segments.current = { damage = {}, total = 0, time = 0 }
  segments.overall = { damage = {}, total = 0, time = 0 }
  if fightStart then fightStart = GetTime() end
  redraw()
end
reset:SetScript("OnClick", resetAll)

local EVENTS = { "COMBAT_LOG_EVENT_UNFILTERED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
  "GROUP_ROSTER_UPDATE", "UNIT_PET", "PLAYER_ENTERING_WORLD" }

local function enable(on)
  for _, e in ipairs(EVENTS) do
    if on then window:RegisterEvent(e) else window:UnregisterEvent(e) end
  end
  if on then
    roster()
    redraw()
    window:Show()
  else
    window:Hide()
  end
end
window.refresh = function() enable(AzerothPlusDB.meter) end

AP:Register("meter", { enable = enable, reset = resetAll })
