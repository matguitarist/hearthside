-- Quest markers: where your tracked quests' objectives are, as dots on the world map and the
-- minimap in the quest's color, with an arrow on the minimap's rim toward the nearest spot while
-- none is in sight; a quest that is done, or has nothing to collect, points to who takes it in. The
-- map's quest panel unticks the quests to leave out. The places are in questdb.lua, built from a
-- CMaNGOS world database by scripts/questdb.py.
--
-- Places are world yards on a continent: the shown map's bounds turn them into map spots and the
-- player's map position back into yards, so the minimap needs no zone of its own.

local AP = AzerothPlus
local DB = AzerothPlusQuestDB

local COLORS = {
  { 1, 0.82, 0 }, { 0.35, 0.8, 1 }, { 0.45, 1, 0.45 }, { 1, 0.5, 0.9 },
  { 1, 0.55, 0.2 }, { 0.7, 0.6, 1 }, { 0.3, 1, 0.85 }, { 0.95, 0.95, 0.95 },
}
-- A white disc, tinted per quest, over a dark one a little bigger so it reads on any map.
local DOT = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TURN_IN = "Interface\\GossipFrame\\ActiveQuestIcon"
local ARROW = "Interface\\Minimap\\MinimapArrow"
local MAX_MAP_PINS = 500
local MAX_MINIMAP_PINS = 80

-- The minimap's width in yards per zoom index (the client's radii doubled), outdoors and in.
local OUTDOOR = { [0] = 466.667, 400, 333.333, 266.667, 200, 133.333 }
local INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

local RACES = { Human = 1, Orc = 2, Dwarf = 4, NightElf = 8, Scourge = 16, Tauren = 32, Gnome = 64, Troll = 128 }

-- `bits` has `bit` set; Lua 5.0 has no bit operators.
local function hasBit(bits, bit)
  return math.floor(bits / bit) - 2 * math.floor(bits / bit / 2) == 1
end

-- A creature's or object's spots, {map, x, y} each, read from its string on first use.
local spotCache = { units = {}, objects = {} }
local function spots(kind, id)
  local cached = spotCache[kind][id]
  if cached then return cached end
  cached = {}
  local packed = DB[kind][id]
  if packed then
    local n, m, x = 0, nil, nil
    for v in string.gfind(packed, "%S+") do
      n = n + 1
      local r = n - 3 * math.floor((n - 1) / 3)
      if r == 1 then m = tonumber(v)
      elseif r == 2 then x = tonumber(v)
      else table.insert(cached, { m, x, tonumber(v) }) end
    end
  end
  spotCache[kind][id] = cached
  return cached
end

local function addSpots(into, units, objects)
  for i = 1, table.getn(units) do
    local s = spots("units", units[i])
    for j = 1, table.getn(s) do table.insert(into, s[j]) end
  end
  for i = 1, table.getn(objects) do
    local s = spots("objects", objects[i])
    for j = 1, table.getn(s) do table.insert(into, s[j]) end
  end
end

-- The quest of this title for your race, the one of this level when titles repeat.
local function lookup(title, level)
  local variants = DB.quests[title]
  if not variants then return nil end
  local _, race = UnitRace("player")
  local bit = RACES[race or ""] or 0
  local best
  for i = 1, table.getn(variants) do
    local v = variants[i]
    if v[2] == 0 or bit == 0 or hasBit(v[2], bit) then
      if v[1] == level then return v end
      best = best or v
    end
  end
  return best
end

-- The tooltips' quest lines match the log the same way.
AP.QuestLookup = lookup

-- What to show: one target per unfinished objective (or turn-in), {title, label, color, spots, turnIn}.
local targets = {}

local function build()
  targets = {}
  local color = 0
  for index = 1, GetNumQuestLogEntries() do
    local title, level, _, isHeader, _, complete = GetQuestLogTitle(index)
    local quest = not isHeader and title and AP:IsTracked(title) and lookup(title, level)
    if quest then
      color = color + 1
      local rgb = COLORS[color - table.getn(COLORS) * math.floor((color - 1) / table.getn(COLORS))]
      local objectives, matched, shown = quest[3], {}, 0
      if complete ~= 1 then
        -- A board line names its objective ("Kobold Vermin slain: 3/10"); unnamed ones take the
        -- quest's objectives left over, in order.
        local open = {}
        for j = 1, GetNumQuestLeaderBoards(index) do
          local text, _, done = GetQuestLogLeaderBoard(j, index)
          local found
          for k = 1, table.getn(objectives) do
            local name = objectives[k][1]
            if not matched[k] and name ~= "" and text and string.find(text, name, 1, true) == 1 then
              found = k
              break
            end
          end
          if found then matched[found] = true end
          table.insert(open, { found = found, text = text, done = done })
        end
        for j = 1, table.getn(open) do
          local line = open[j]
          if not line.found then
            for k = 1, table.getn(objectives) do
              if not matched[k] then
                matched[k] = true
                line.found = k
                break
              end
            end
          end
          if line.found and not line.done then
            local o = objectives[line.found]
            local into = {}
            addSpots(into, o[2], o[3])
            if table.getn(into) > 0 then
              table.insert(targets, { title = title, label = line.text or o[1], color = rgb, spots = into })
              shown = shown + 1
            end
          end
        end
      end
      if shown == 0 then
        local into = {}
        addSpots(into, quest[4], quest[5])
        if table.getn(into) > 0 then
          table.insert(targets, {
            title = title, label = complete == 1 and "Turn in" or "Ends here", color = rgb,
            spots = into, turnIn = true,
          })
        end
      end
    end
  end
end

-- The shown map's bounds: {map, left, right, top, bottom} or nil (the world, an instance).
local function shownBounds()
  local name = GetMapInfo()
  return name and DB.zones[name]
end

-- Where you are: continent and world yards, read off whichever map is set.
local function playerPlace()
  local b = shownBounds()
  local x, y = GetPlayerMapPosition("player")
  if (not b or (x == 0 and y == 0)) and not WorldMapFrame:IsShown() then
    SetMapToCurrentZone()
    b = shownBounds()
    x, y = GetPlayerMapPosition("player")
  end
  if not b or (x == 0 and y == 0) then return nil end
  return b[1], b[4] - y * (b[4] - b[5]), b[2] - x * (b[2] - b[3])
end

local tooltipOwner
local function showTooltip()
  local pin = this
  GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
  -- Every target under the cursor, so stacked dots all show.
  local seen = {}
  for i = 1, table.getn(pin.pool) do
    local other = pin.pool[i]
    if other:IsShown() and other.target and MouseIsOver(other) then
      local t = other.target
      local key = t.title .. "\n" .. t.label
      if not seen[key] then
        seen[key] = true
        GameTooltip:AddLine(t.title, t.color[1], t.color[2], t.color[3])
        GameTooltip:AddLine(t.label, 1, 1, 1)
      end
    end
  end
  GameTooltip:Show()
  tooltipOwner = pin
end

local function hideTooltip()
  if tooltipOwner == this then GameTooltip:Hide() end
end

local function newPin(parent, pool, size)
  local pin = CreateFrame("Frame", nil, parent)
  pin:SetWidth(size)
  pin:SetHeight(size)
  pin.rim = pin:CreateTexture(nil, "ARTWORK")
  pin.rim:SetAllPoints(pin)
  pin.rim:SetTexture(DOT)
  pin.rim:SetVertexColor(0, 0, 0, 0.85)
  pin.tex = pin:CreateTexture(nil, "OVERLAY")
  pin:EnableMouse(true)
  pin:SetScript("OnEnter", showTooltip)
  pin:SetScript("OnLeave", hideTooltip)
  pin.pool = pool
  table.insert(pool, pin)
  return pin
end

local function paint(pin, t, size)
  pin.target = t
  pin:SetWidth(t.turnIn and size + 4 or size)
  pin:SetHeight(t.turnIn and size + 4 or size)
  pin.tex:ClearAllPoints()
  if t.turnIn then
    pin.rim:Hide()
    pin.tex:SetAllPoints(pin)
    pin.tex:SetTexture(TURN_IN)
    pin.tex:SetVertexColor(1, 1, 1)
  else
    pin.rim:Show()
    pin.tex:SetPoint("TOPLEFT", pin, "TOPLEFT", 2, -2)
    pin.tex:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", -2, 2)
    pin.tex:SetTexture(DOT)
    pin.tex:SetVertexColor(t.color[1], t.color[2], t.color[3])
  end
  pin.tex:SetTexCoord(0, 1, 0, 1)
  pin:Show()
end

-- The world map: every spot of every target on the shown zone or continent.
local mapPins = {}
local function drawMap()
  local used = 0
  local b = WorldMapFrame:IsShown() and AzerothPlusDB.questMarkers and shownBounds()
  if b then
    local w, h = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
    local level = WorldMapButton:GetFrameLevel() + 5
    for i = table.getn(targets), 1, -1 do -- the first quests drawn last, on top
      local t = targets[i]
      for j = 1, table.getn(t.spots) do
        local s = t.spots[j]
        local mx, my = (b[2] - s[3]) / (b[2] - b[3]), (b[4] - s[2]) / (b[4] - b[5])
        if s[1] == b[1] and mx >= 0 and mx <= 1 and my >= 0 and my <= 1 and used < MAX_MAP_PINS then
          used = used + 1
          local pin = mapPins[used] or newPin(WorldMapButton, mapPins, 12)
          pin:SetFrameLevel(level)
          paint(pin, t, 12)
          pin:ClearAllPoints()
          pin:SetPoint("CENTER", WorldMapButton, "TOPLEFT", mx * w, -my * h)
        end
      end
    end
  end
  for i = used + 1, table.getn(mapPins) do mapPins[i]:Hide() end
end

-- `true` indoors, where the minimap uses its own zoom: the zoom CVar that matches tells, and when
-- both hold the same index a one-step zoom and back tells them apart.
local function indoors()
  local zoom = Minimap:GetZoom()
  local inside, outside = tonumber(GetCVar("minimapInsideZoom")), tonumber(GetCVar("minimapZoom"))
  if inside ~= outside then return inside == zoom end
  Minimap:SetZoom(zoom < 2 and zoom + 1 or zoom - 1)
  local isInside = tonumber(GetCVar("minimapInsideZoom")) == Minimap:GetZoom()
  Minimap:SetZoom(zoom)
  return isInside
end

-- Turns `tex` by `a` radians clockwise; the corners are pulled in so the turned art stays inside.
local function rotate(tex, a)
  local c, s = math.cos(a) * 0.7071, math.sin(a) * 0.7071
  local function at(dx, dy) return 0.5 + dx * c + dy * s, 0.5 - dx * s + dy * c end
  local ulx, uly = at(-0.5, -0.5)
  local llx, lly = at(-0.5, 0.5)
  local urx, ury = at(0.5, -0.5)
  local lrx, lry = at(0.5, 0.5)
  tex:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end

-- The minimap: the spots in its circle, and for a target with none, an arrow on the rim.
local miniPins, arrows = {}, {}
local function drawMinimap()
  local used, arrowsUsed = 0, 0
  local m, px, py
  if AzerothPlusDB.questMarkers and table.getn(targets) > 0 then m, px, py = playerPlace() end
  if m then
    local yards = (indoors() and INDOOR or OUTDOOR)[Minimap:GetZoom()] or 266.667
    local radius = Minimap:GetWidth() / 2
    local scale = radius / (yards / 2)
    local level = Minimap:GetFrameLevel() + 5
    for i = table.getn(targets), 1, -1 do
      local t = targets[i]
      local nearest, nx, ny
      for j = 1, table.getn(t.spots) do
        local s = t.spots[j]
        if s[1] == m then
          -- North is +x in world yards, west is +y.
          local east, north = (py - s[3]) * scale, (s[2] - px) * scale
          local d = east * east + north * north
          if d <= (radius - 6) * (radius - 6) then
            if used < MAX_MINIMAP_PINS then
              used = used + 1
              local pin = miniPins[used] or newPin(Minimap, miniPins, 10)
              pin:SetFrameLevel(level)
              paint(pin, t, 10)
              pin:ClearAllPoints()
              pin:SetPoint("CENTER", Minimap, "CENTER", east, north)
            end
            nearest = false
          elseif nearest ~= false and (not nearest or d < nearest) then
            nearest, nx, ny = d, east, north
          end
        end
      end
      if nearest then
        arrowsUsed = arrowsUsed + 1
        local arrow = arrows[arrowsUsed] or newPin(Minimap, arrows, 18)
        arrow:SetFrameLevel(level + 1)
        arrow.target = t
        arrow.rim:Hide()
        arrow.tex:ClearAllPoints()
        arrow.tex:SetAllPoints(arrow)
        arrow.tex:SetTexture(ARROW)
        arrow.tex:SetVertexColor(t.color[1], t.color[2], t.color[3])
        local a = math.atan2(nx, ny)
        rotate(arrow.tex, a)
        arrow:ClearAllPoints()
        arrow:SetPoint("CENTER", Minimap, "CENTER", math.sin(a) * (radius + 2), math.cos(a) * (radius + 2))
        arrow:Show()
      end
    end
  end
  for i = used + 1, table.getn(miniPins) do miniPins[i]:Hide() end
  for i = arrowsUsed + 1, table.getn(arrows) do arrows[i]:Hide() end
end

local dirty, since = true, 0
local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnEvent", function()
  if event == "WORLD_MAP_UPDATE" then
    drawMap()
  else
    dirty = true
  end
end)
driver:SetScript("OnUpdate", function()
  since = since + arg1
  if since < 0.1 then return end
  since = 0
  if dirty then
    dirty = false
    build()
    drawMap()
  end
  drawMinimap()
end)

-- The map's quest panel changes what is tracked without a quest log event.
function AP:RefreshQuestMarkers()
  dirty = true
end

local stockShow = WorldMapFrame:GetScript("OnShow")
WorldMapFrame:SetScript("OnShow", function()
  if stockShow then stockShow() end
  drawMap()
end)

AP:Register("questMarkers", {
  enable = function(on)
    if not DB then return end
    if on then
      driver:RegisterEvent("QUEST_LOG_UPDATE")
      driver:RegisterEvent("PLAYER_ENTERING_WORLD")
      driver:RegisterEvent("WORLD_MAP_UPDATE")
      dirty = true
      driver:Show()
    else
      driver:UnregisterAllEvents()
      driver:Hide()
      targets = {}
      drawMap()
      drawMinimap()
    end
  end,
})
