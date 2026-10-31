-- All objectives: the quests in the log with their objectives, down the right of the screen, as
-- newer clients track them; the map's quest panel unticks those to leave out. It takes the stock
-- quest watch's place while on. A click opens the quest in the quest log; the header folds the list.

local AP = AzerothPlus

local WIDTH = 250
local MAX_LINES = 32
local LINE = 13

local frame = CreateFrame("Frame", "AzerothPlusObjectives", UIParent)
frame:SetWidth(WIDTH)
frame:SetHeight(24)
AP:Movable(frame, "objectives", "All objectives", "TOPRIGHT", -12, -210)

local header = CreateFrame("Button", nil, frame)
header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
header:SetHeight(20)
local headerBg = header:CreateTexture(nil, "BACKGROUND")
headerBg:SetAllPoints(header)
headerBg:SetTexture(0, 0, 0, 0.5)
local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
headerText:SetPoint("LEFT", header, "LEFT", 6, 0)
local fold = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
fold:SetPoint("RIGHT", header, "RIGHT", -6, 0)

local list = AP:QuestList(frame, WIDTH, {
  moreText = function(entries, last)
    return "and " .. (table.getn(entries) - last) .. " more in the quest log"
  end,
})

local function update()
  if not AzerothPlusDB.objectives then return end
  local quests = {}
  local all = AP:Quests(AzerothPlusDB.questLevels)
  for i = 1, table.getn(all) do
    if AP:IsTracked(all[i].key) then table.insert(quests, all[i]) end
  end
  headerText:SetText("All Objectives (" .. table.getn(quests) .. ")")
  local folded = AzerothPlusDB.objectivesFolded
  fold:SetText(folded and "+" or "-")
  local used = list:Fill(folded and {} or quests, frame, 0, -24, MAX_LINES, nil)
  frame:SetHeight(24 + used * LINE)
end
AP.UpdateObjectives = update

header:SetScript("OnClick", function()
  AzerothPlusDB.objectivesFolded = not AzerothPlusDB.objectivesFolded
  update()
end)

local events = CreateFrame("Frame")
events:SetScript("OnEvent", update)

-- The stock watch would list the same quests a second time.
local function silenceWatch(on)
  if on then
    QuestWatchFrame:Hide()
    QuestWatchFrame:SetScript("OnShow", function() this:Hide() end)
  else
    QuestWatchFrame:SetScript("OnShow", nil)
    QuestWatch_Update()
  end
end

frame.refresh = function()
  if AzerothPlusDB.objectives then frame:Show() else frame:Hide() end
end

AP:Register("objectives", {
  enable = function(on)
    if on then
      events:RegisterEvent("QUEST_LOG_UPDATE")
      events:RegisterEvent("PLAYER_ENTERING_WORLD")
      frame:Show()
      update()
    else
      events:UnregisterAllEvents()
      frame:Hide()
    end
    silenceWatch(on)
  end,
})
