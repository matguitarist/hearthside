-- Tooltip lines the 1.12 client leaves out: what a vendor pays for an item, a creature's health
-- in numbers (the client knows only a percentage; `infodb.lua` has each creature's), and what a
-- quest in the log still needs from the unit or item under the mouse.

local AP = AzerothPlus

-- A creature's most health at `level`, between its lowest and highest level's, or nil.
function AP:CreatureHealth(name, level)
  local h = name and AzerothPlusInfoDB and AzerothPlusInfoDB.health[name]
  if not h then return nil end
  if h[2] <= h[1] or not level or level < 0 then return h[4] end
  local t = (level - h[1]) / (h[2] - h[1])
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return math.floor(h[3] + (h[4] - h[3]) * t + 0.5)
end

-- A unit's health as numbers: its own for players and pets, which the client knows; a creature's
-- worked out from the percentage and its health in `infodb.lua`.
function AP:UnitHealthNumbers(unit)
  local cur, max = UnitHealth(unit), UnitHealthMax(unit)
  if not max or max <= 0 then return nil end
  if UnitIsPlayer(unit) or UnitPlayerControlled(unit) or max ~= 100 then return cur, max end
  local full = self:CreatureHealth(UnitName(unit), UnitLevel(unit))
  if not full then return nil end
  return math.floor(full * cur / 100 + 0.5), full
end

-- The quest log's unfinished board lines that this unit or item counts for, as "Title: line".
local function questLines(unitName, itemName)
  local lines = {}
  local DB = AzerothPlusQuestDB
  for index = 1, GetNumQuestLogEntries() do
    local title, level, _, isHeader, _, complete = GetQuestLogTitle(index)
    if title and not isHeader and complete ~= 1 then
      local quest = AP.QuestLookup and AP.QuestLookup(title, level)
      -- The objectives this creature drops for, by name: a board line starts with its objective.
      local wanted = {}
      if unitName and quest and DB and DB.names then
        for k = 1, table.getn(quest[3]) do
          local units = quest[3][k][2]
          for u = 1, table.getn(units) do
            if DB.names[units[u]] == unitName then wanted[quest[3][k][1]] = true end
          end
        end
      end
      for j = 1, GetNumQuestLeaderBoards(index) do
        local text, _, done = GetQuestLogLeaderBoard(j, index)
        if text and not done then
          local _, _, name = string.find(text, "^(.-):")
          local hit = false
          if name then
            name = string.gsub(name, " slain$", "")
            hit = wanted[name] or name == unitName or name == itemName
          end
          if hit then table.insert(lines, title .. ": " .. text) end
        end
      end
    end
  end
  return lines
end

local function addQuestLines(tip, unitName, itemName)
  if not AP:Setting("tipQuest") then return end
  local lines = questLines(unitName, itemName)
  for i = 1, table.getn(lines) do
    tip:AddLine(lines[i], 1, 0.82, 0)
  end
end

local function addItem(tip, link, count)
  if not link then return end
  local id = AP:ItemId(link)
  if AP:Setting("tipPrice") then
    local price = AP:VendorPrice(id)
    if price then
      count = count or 1
      tip:AddDoubleLine(count > 1 and "Vendor (" .. count .. ")" or "Vendor",
        AP:Money(price * count), 1, 1, 1, 1, 1, 1)
    end
  end
  local _, _, name = string.find(link, "%[(.-)%]")
  addQuestLines(tip, nil, name)
  tip:Show() -- grows the tooltip to its new lines
end

-- Each stock Set* method, then the lines for what it showed.
local function hook(method, after)
  local stock = GameTooltip[method]
  if not stock then return end
  GameTooltip[method] = function(self, a, b, c)
    local r1, r2, r3 = stock(self, a, b, c)
    after(self, a, b, c)
    return r1, r2, r3
  end
end

hook("SetBagItem", function(tip, bag, slot)
  local _, count = GetContainerItemInfo(bag, slot)
  addItem(tip, GetContainerItemLink(bag, slot), count)
end)
hook("SetInventoryItem", function(tip, unit, slot)
  addItem(tip, GetInventoryItemLink(unit, slot), GetInventoryItemCount(unit, slot))
end)
hook("SetLootItem", function(tip, slot)
  local _, _, count = GetLootSlotInfo(slot)
  addItem(tip, GetLootSlotLink(slot), count)
end)
hook("SetMerchantItem", function(tip, index)
  addItem(tip, GetMerchantItemLink(index))
end)
hook("SetQuestItem", function(tip, kind, index)
  addItem(tip, GetQuestItemLink(kind, index))
end)
hook("SetQuestLogItem", function(tip, kind, index)
  addItem(tip, GetQuestLogItemLink(kind, index))
end)
hook("SetHyperlink", function(tip, link)
  if link and string.find(link, "^item:") then addItem(tip, "|H" .. link .. "|h[" .. (GameTooltipTextLeft1:GetText() or "") .. "]|h") end
end)

-- A unit's tooltip: its health under its name, then the quests it counts for. A unit in the world
-- reaches it by UPDATE_MOUSEOVER_UNIT, a unit frame by SetUnit, some by both: added once.
local function has(tip, text)
  for i = 1, tip:NumLines() do
    local line = getglobal(tip:GetName() .. "TextLeft" .. i)
    if line and line:GetText() == text then return true end
  end
  return false
end

local function addUnit(tip, unit)
  if not unit or not UnitExists(unit) then return end
  local added = false
  if AP:Setting("tipHealth") then
    local cur, max = AP:UnitHealthNumbers(unit)
    local line = cur and AP:FormatNumber(cur) .. " / " .. AP:FormatNumber(max) .. " health"
    if line and not has(tip, line) then
      tip:AddLine(line, 0.5, 1, 0.5)
      added = true
    end
  end
  if not UnitIsPlayer(unit) and AP:Setting("tipQuest") then
    local lines = questLines(UnitName(unit), nil)
    for i = 1, table.getn(lines) do
      if not has(tip, lines[i]) then
        tip:AddLine(lines[i], 1, 0.82, 0)
        added = true
      end
    end
  end
  if added then tip:Show() end
end
hook("SetUnit", addUnit)
local mouseover = CreateFrame("Frame")
mouseover:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
mouseover:SetScript("OnEvent", function()
  if GameTooltip:IsShown() then addUnit(GameTooltip, "mouseover") end
end)

-- The target frame's health bar, as numbers too.
local text = TargetFrameHealthBar and TargetFrameHealthBar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
if text then
  text:SetPoint("CENTER", TargetFrameHealthBar, "CENTER", 0, 0)
  local function update()
    local cur, max
    if AP:Setting("tipHealth") and UnitExists("target") then cur, max = AP:UnitHealthNumbers("target") end
    text:SetText(cur and (AP:FormatNumber(cur) .. " / " .. AP:FormatNumber(max)) or "")
  end
  local events = CreateFrame("Frame")
  events:RegisterEvent("PLAYER_TARGET_CHANGED")
  events:RegisterEvent("UNIT_HEALTH")
  events:RegisterEvent("UNIT_MAXHEALTH")
  events:SetScript("OnEvent", function()
    if event == "PLAYER_TARGET_CHANGED" or arg1 == "target" then update() end
  end)
  AP:Register("tipHealth", { enable = update })
end
