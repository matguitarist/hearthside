-- Quest helpers: each quest's level in the quest log ("[12] Title", "[30+]" for an elite one),
-- and quests taken and handed in without the clicks. Shift held at a quest giver does it by hand;
-- a reward to choose from is always left to you.

local AP = AzerothPlus

local function levelTag(level, tag)
  if not level or level <= 0 then return "" end
  local extra = ""
  if tag == ELITE then extra = "+" elseif tag == RAID then extra = "R" elseif tag == "Dungeon" then extra = "D" end
  return "[" .. level .. extra .. "] "
end

-- The stock log writes each title in QuestLog_Update; the level goes in front after.
local stockUpdate = QuestLog_Update
if stockUpdate then
  QuestLog_Update = function()
    stockUpdate()
    if not AP:Setting("questLevels") then return end
    local offset = FauxScrollFrame_GetOffset(QuestLogListScrollFrame)
    for i = 1, QUESTS_DISPLAYED do
      local button = getglobal("QuestLogTitle" .. i)
      local index = i + offset
      if button and index <= GetNumQuestLogEntries() then
        local title, level, tag, isHeader = GetQuestLogTitle(index)
        if title and not isHeader then
          button:SetText("  " .. levelTag(level, tag) .. title)
        end
      end
    end
  end
end

-- Whether the log holds this quest finished: gossip and greetings give titles, not states.
local function finished(title, level)
  for index = 1, GetNumQuestLogEntries() do
    local t, l, _, header, _, complete = GetQuestLogTitle(index)
    if not header and t == title and (not level or l == level) and complete == 1 then return true end
  end
  return false
end

local function auto()
  return AP:Setting("autoQuest") and not IsShiftKeyDown()
end

local events = CreateFrame("Frame")
events:RegisterEvent("QUEST_DETAIL")
events:RegisterEvent("QUEST_PROGRESS")
events:RegisterEvent("QUEST_COMPLETE")
events:RegisterEvent("QUEST_GREETING")
events:RegisterEvent("GOSSIP_SHOW")
events:SetScript("OnEvent", function()
  if not auto() then return end
  if event == "QUEST_DETAIL" then
    AcceptQuest()
  elseif event == "QUEST_PROGRESS" then
    if IsQuestCompletable() then CompleteQuest() end
  elseif event == "QUEST_COMPLETE" then
    local choices = GetNumQuestChoices()
    if choices <= 1 then GetQuestReward(choices) end
  elseif event == "QUEST_GREETING" then
    -- Finished quests first, then new ones; the server answers with the next window.
    for i = 1, GetNumActiveQuests() do
      if finished(GetActiveTitle(i)) then SelectActiveQuest(i) return end
    end
    if GetNumAvailableQuests() > 0 then SelectAvailableQuest(1) end
  elseif event == "GOSSIP_SHOW" then
    -- Name and level pairs.
    local active = { GetGossipActiveQuests() }
    for i = 1, table.getn(active) / 2 do
      if finished(active[i * 2 - 1], active[i * 2]) then
        SelectGossipActiveQuest(i)
        return
      end
    end
    if GetGossipAvailableQuests() then SelectGossipAvailableQuest(1) end
  end
end)

function AP:QuestLevelTag(level, tag) return levelTag(level, tag) end

AP:Register("questLevels", { enable = function() if QuestLogFrame and QuestLogFrame:IsShown() then QuestLog_Update() end end })
