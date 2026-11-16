-- Quest helpers: each quest's level in the quest log ("[12] Title", "[30+]" for an elite one),
-- and quests taken and handed in without the clicks. Shift held at a quest giver does it by hand;
-- a reward to choose from, a quest that costs money or flags you for PvP, and grey quests are
-- always left to you.

local AP = AzerothPlus

local TAGS = { [ELITE or "Elite"] = "+", [GROUP or "Group"] = "G", [RAID or "Raid"] = "R",
  ["Dungeon"] = "D", ["Heroic"] = "H", ["Scenario"] = "S" }

local function levelTag(level, tag)
  if not level or level <= 0 then return "" end
  return "[" .. level .. (tag and TAGS[tag] or "") .. "] "
end

-- The stock log writes each title in QuestLog_Update (`QuestLogFrame.lua`); the level goes in
-- front after, and the button is sized again for the longer text.
local function addLevels()
  if not AP:Setting("questLevels") or not QuestLogScrollFrame.buttons then return end
  -- The colorblind mode writes the level itself.
  if ENABLE_COLORBLIND_MODE == "1" then return end
  local offset = HybridScrollFrame_GetOffset(QuestLogScrollFrame)
  local entries = GetNumQuestLogEntries()
  for i, button in ipairs(QuestLogScrollFrame.buttons) do
    local index = i + offset
    if index <= entries then
      local title, level, tag, _, isHeader, _, _, _, questID, _, displayID = GetQuestLogTitle(index)
      if title and not isHeader then
        if questID and displayID then title = questID .. " - " .. title end
        button:SetText("  " .. levelTag(level, tag) .. title)
        QuestLogTitleButton_Resize(button)
      end
    end
  end
end
hooksecurefunc("QuestLog_Update", addLevels)
-- The scroll frame calls the function it was given at load, not the global.
if QuestLogScrollFrame then QuestLogScrollFrame.update = QuestLog_Update end

local function auto()
  return AP:Setting("autoQuest") and not IsShiftKeyDown()
end

-- Whether the log holds a quest of this title finished.
local function finished(title)
  for index = 1, GetNumQuestLogEntries() do
    local t, _, _, _, header, _, complete = GetQuestLogTitle(index)
    if not header and t == title and complete == 1 then return true end
  end
  return false
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_GREETING", "GOSSIP_SHOW" }) do
  events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(self, event)
  if not auto() then return end
  if event == "QUEST_DETAIL" then
    if QuestFlagsPVP() then return end
    if QuestGetAutoAccept() then AcknowledgeAutoAcceptQuest() else AcceptQuest() end
  elseif event == "QUEST_PROGRESS" then
    if IsQuestCompletable() then CompleteQuest() end
  elseif event == "QUEST_COMPLETE" then
    local choices = GetNumQuestChoices()
    local money = GetQuestMoneyToGet()
    if choices <= 1 and not (money and money > 0) then GetQuestReward(choices) end
  elseif event == "QUEST_GREETING" then
    -- Finished quests first, then new ones; the server answers with the next window.
    for i = 1, GetNumActiveQuests() do
      local title, complete = GetActiveTitle(i)
      if complete or finished(title) then SelectActiveQuest(i) return end
    end
    for i = 1, GetNumAvailableQuests() do
      if not GetAvailableQuestInfo(i) then SelectAvailableQuest(i) return end
    end
  elseif event == "GOSSIP_SHOW" then
    -- Five values a quest: title, level, trivial, complete, legendary (`GossipFrame.lua`).
    local active = { GetGossipActiveQuests() }
    for i = 1, #active / 5 do
      if active[i * 5 - 1] then SelectGossipActiveQuest(i) return end
    end
    -- Six: title, level, trivial, daily, repeatable, legendary.
    local available = { GetGossipAvailableQuests() }
    for i = 1, #available / 6 do
      if not available[i * 6 - 3] then SelectGossipAvailableQuest(i) return end
    end
  end
end)

AP:Register("questLevels", {
  enable = function() if QuestLogFrame and QuestLogFrame:IsShown() then QuestLog_Update() end end,
})
