-- AzerothPlus's vendor, tooltip, quest and bot features against a stubbed 1.12 client. Run from
-- the repository root with Lua 5.1 or later:
--   lua scripts/addon-tests/features.lua addons/AzerothPlus
table.getn = table.getn or function(t) return #t end
math.mod = math.mod or math.fmod
local A = arg[1]
local unpack = unpack or table.unpack

-- A frame answers every method; the ones a test reads are real.
local frames = {}
local function frame(name)
  local f = { scripts = {}, shown = false, lines = {}, events = {}, name = name }
  function f:SetScript(k, v) self.scripts[k] = v end
  function f:GetScript(k) return self.scripts[k] end
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:IsShown() return self.shown end
  function f:GetName() return self.name end
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:CreateFontString() return frame() end
  function f:CreateTexture() return frame() end
  function f:SetText(t) self.text = t end
  function f:GetText() return self.text end
  function f:GetChecked() return self.checked end
  function f:SetChecked(c) self.checked = c end
  function f:GetID() return self.id or 0 end
  function f:NumLines() return #self.lines end
  function f:AddLine(t) table.insert(self.lines, t) end
  function f:AddDoubleLine(l, r) table.insert(self.lines, l .. "|" .. r) end
  setmetatable(f, { __index = function() return function() end end })
  table.insert(frames, f)
  if name then _G[name] = f end
  return f
end
CreateFrame = function(_, name)
  if name then frame(name .. "Text") end -- a template's label
  return frame(name)
end
UIParent, Minimap, FriendsFrame = frame(), frame(), frame()
GameTooltip = frame("GameTooltip")
for i = 1, 30 do frame("GameTooltipTextLeft" .. i) end
function GameTooltip:AddLine(t) table.insert(self.lines, t); _G["GameTooltipTextLeft" .. #self.lines].text = t end
UISpecialFrames, NUM_CONTAINER_FRAMES, QUESTS_DISPLAYED = {}, 12, 6
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) printed = m end }
getglobal = function(n) return _G[n] end
SlashCmdList, WorldMapFrame, WorldMapButton = {}, frame(), frame()
TargetFrameHealthBar = frame()

local function fire(e, a1)
  event, arg1 = e, a1
  for _, f in ipairs(frames) do
    if f.events[e] and f.scripts.OnEvent then this = f; f.scripts.OnEvent() end
  end
end
local function check(ok, what) if not ok then error("FAIL: " .. what, 2) end print("ok - " .. what) end

-- The bags: a grey Broken Fang (1 copper to a vendor... 5 of them), Linen Cloth.
local bags = { [0] = {
  { link = "|cff9d9d9d|Hitem:7073:0:0:0|h[Broken Fang]|h|r", count = 5 },
  { link = "|cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r", count = 5 },
} }
GetContainerNumSlots = function(b) return bags[b] and #bags[b] or 0 end
GetContainerItemLink = function(b, s) return bags[b] and bags[b][s] and bags[b][s].link end
GetContainerItemInfo = function(b, s) local i = bags[b][s]; return "tex", i.count, false end
local used = {}
UseContainerItem = function(b, s) table.insert(used, b .. ":" .. s) end
local shift, repaired = false, false
IsShiftKeyDown = function() return shift end
CanMerchantRepair = function() return true end
GetRepairAllCost = function() return 1234 end
GetMoney = function() return 100000 end
RepairAllItems = function() repaired = true end

-- A human in Elwynn with a kill quest and a collect quest.
local log = {
  { "Elwynn Forest", 0, nil, 1 },
  { "Kobold Camp Cleanup", 2, nil, nil, nil, nil, { { "Kobold Vermin slain: 3/10", "monster", nil } } },
  { "Wolves Across the Border", 2, nil, nil, nil, 1, {} },
}
GetNumQuestLogEntries = function() return #log end
GetQuestLogTitle = function(i) local q = log[i]; return q[1], q[2], q[3], q[4], nil, q[6] end
GetNumQuestLeaderBoards = function(i) return #(log[i][7] or {}) end
GetQuestLogLeaderBoard = function(j, i) local l = log[i][7][j]; return l[1], l[2], l[3] end
UnitRace = function() return "Human", "Human" end

local units = { mouseover = { name = "Kobold Vermin", level = 2, hp = 50, max = 100 } }
UnitExists = function(u) return units[u] ~= nil end
UnitName = function(u) return units[u].name end
UnitLevel = function(u) return units[u] and units[u].level or 10 end
UnitHealth = function(u) return units[u].hp end
UnitHealthMax = function(u) return units[u].max end
UnitIsPlayer = function() return false end
UnitPlayerControlled = function() return false end

AzerothPlusDB = nil
for _, file in ipairs({ "core.lua", "questdb.lua", "infodb.lua", "questmap.lua", "merchant.lua",
                        "bagsearch.lua", "tooltips.lua", "quests.lua", "bots.lua", "options.lua" }) do
  dofile(A .. "/" .. file)
end
fire("VARIABLES_LOADED")
local AP = AzerothPlus

-- Vendors.
fire("MERCHANT_SHOW")
check(#used == 1 and used[1] == "0:1", "only the grey item is sold")
check(repaired, "everything repaired")
check(printed and printed:find("sold 1 grey item"), "the sale is said in the chat")
used, repaired = {}, false
shift = true; fire("MERCHANT_SHOW"); shift = false
check(#used == 0 and not repaired, "Shift keeps both")

-- Tooltips.
check(AP:CreatureHealth("Hogger", 11) == 666, "Hogger's health")
check(AP:CreatureHealth("Kobold Vermin", 2) == 55, "a creature's health at its highest level")
local cur, max = AP:UnitHealthNumbers("mouseover")
check(cur == 28 and max == 55, "half a kobold's health in numbers")
GameTooltip.lines = {}
GameTooltip:Show()
fire("UPDATE_MOUSEOVER_UNIT")
local text = table.concat(GameTooltip.lines, "\n")
check(text:find("28 / 55 health", 1, true), "health line on the unit tooltip")
check(text:find("Kobold Camp Cleanup: Kobold Vermin slain: 3/10", 1, true), "quest line on the unit tooltip")
local n = #GameTooltip.lines
GameTooltip:SetUnit("mouseover")
check(#GameTooltip.lines == n, "the same unit's lines added once")
GameTooltip.lines = {}
GameTooltip:SetBagItem(0, 2)
check(GameTooltip.lines[1] == "Vendor (5)|" .. AP:Money(65), "a stack's vendor price")

-- Quests.
local calls = {}
for _, f in ipairs({ "AcceptQuest", "CompleteQuest", "GetQuestReward", "SelectGossipActiveQuest",
                     "SelectGossipAvailableQuest" }) do
  _G[f] = function(a) table.insert(calls, f .. "(" .. tostring(a) .. ")") end
end
IsQuestCompletable = function() return true end
AzerothPlusDB.autoQuest = true
fire("QUEST_DETAIL")
check(calls[1] == "AcceptQuest(nil)", "a quest is accepted")
calls = {}
GetNumQuestChoices = function() return 2 end
fire("QUEST_COMPLETE")
check(#calls == 0, "a reward to choose is left alone")
GetNumQuestChoices = function() return 0 end
fire("QUEST_COMPLETE")
check(calls[1] == "GetQuestReward(0)", "no reward to choose: handed in")
calls = {}
GetGossipActiveQuests = function() return "Kobold Camp Cleanup", 2, "Wolves Across the Border", 2 end
GetGossipAvailableQuests = function() return "A Threat Within", 1 end
fire("GOSSIP_SHOW")
check(calls[1] == "SelectGossipActiveQuest(2)", "the finished quest is picked at a gossip")
GetGossipActiveQuests = function() return "Kobold Camp Cleanup", 2 end
calls = {}
fire("GOSSIP_SHOW")
check(calls[1] == "SelectGossipAvailableQuest(1)", "then a new one")
shift = true; calls = {}
fire("GOSSIP_SHOW")
check(#calls == 0, "Shift talks by hand")
shift = false

-- Bots.
local said = {}
SendChatMessage = function(m, c) table.insert(said, c .. ":" .. m) end
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 1 end
AP:ToggleBots()
check(AzerothPlusBots:IsShown() and AzerothPlusDB.botPanel, "/ap bots opens the panel")
for _, f in ipairs(frames) do
  if f.text == "Attack" and f.scripts.OnClick then this = f; f.scripts.OnClick() end
end
check(said[1] == "PARTY:attack", "a command goes to the party")
