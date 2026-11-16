-- AzerothAdmin's pages: each button is one GM command of the Pandaria server (TrinityCore's
-- `src/server/scripts/Commands/cs_*.cpp`, and the playerbots module's `.playerbots`). They need a
-- game master account, which `pandaria-account --gm` creates; the bot ones work for any player.

local AA = AzerothAdmin
local COL = { 0, 140, 280 }
local MAX_LEVEL = MAX_PLAYER_LEVEL_TABLE and MAX_PLAYER_LEVEL_TABLE[GetExpansionLevel()] or 90

-- Character -----------------------------------------------------------------------------------

local char = AA:Page("Character")
AA:Label(char, "Level", 0, 0)
AA:CmdButton(char, "+1 level", COL[1], -18, 130, ".levelup 1")
AA:CmdButton(char, "+10 levels", COL[2], -18, 130, ".levelup 10")
AA:CmdButton(char, "Level " .. MAX_LEVEL, COL[3], -18, 130, function()
  local up = MAX_LEVEL - UnitLevel("player")
  if up > 0 then return ".levelup " .. up end
end)

AA:Label(char, "Gold", 0, -50)
AA:CmdButton(char, "+100 gold", COL[1], -68, 130, ".modify money 1000000")
AA:CmdButton(char, "+1000 gold", COL[2], -68, 130, ".modify money 10000000")
AA:CmdButton(char, "+10000 gold", COL[3], -68, 130, ".modify money 100000000")

AA:Label(char, "Abilities and gear", 0, -100)
AA:CmdButton(char, "Learn class spells", COL[1], -118, 130, ".learn all my class")
AA:CmdButton(char, "Max skills", COL[2], -118, 130, ".maxskill")
AA:CmdButton(char, "Reset talents", COL[3], -118, 130, ".reset talents")
AA:CmdButton(char, "Repair all", COL[1], -144, 130, ".repairitems")
AA:CmdButton(char, "Revive", COL[2], -144, 130, ".revive")
AA:CmdButton(char, "Save", COL[3], -144, 130, ".save")

AA:Label(char, "Travel", 0, -176)
AA:CmdButton(char, "All flight paths", COL[1], -194, 130, ".cheat taxi on")
-- On the selected player, which is you with no target.
AA:CmdButton(char, "Reveal the map", COL[2], -194, 130, function()
  if UnitExists("target") and not UnitIsUnit("target", "player") then
    AA.reply:SetText("|cffff8888Clear your target first: it reveals the map of the selected player.|r")
    return
  end
  return ".cheat explore 1"
end)
AA:CmdButton(char, "Unstuck", COL[3], -194, 130, ".unstuck")

AA:Label(char, "Run speed", 0, -226)
for i, speed in ipairs({ 1, 1.5, 2, 3, 5 }) do
  AA:CmdButton(char, speed .. "x", (i - 1) * 70, -244, 66, ".modify speed " .. speed)
end

-- Cheats ----------------------------------------------------------------------------------------

local cheats = AA:Page("Cheats")
AA:Label(cheats, "On your character, until switched off", 0, 0)
local rows = {
  { "god", "God mode: no damage kills you", ".cheat god on", ".cheat god off" },
  { "cooldown", "No cooldowns", ".cheat cooldown on", ".cheat cooldown off" },
  { "casttime", "Instant casts", ".cheat casttime on", ".cheat casttime off" },
  { "power", "No mana, rage, energy or other cost", ".cheat power on", ".cheat power off" },
  { "waterwalk", "Walk on water", ".cheat waterwalk on", ".cheat waterwalk off" },
  { "fly", "Fly anywhere", ".gm fly on", ".gm fly off" },
  { "gm", "GM mode: monsters ignore you, the GM tag shows", ".gm on", ".gm off" },
  { "invisible", "Invisible to players", ".gm visible off", ".gm visible on" },
}
for i, row in ipairs(rows) do
  AA:Toggle(cheats, row[2], 0, -18 - (i - 1) * 28, row[1], row[3], row[4])
end
AA:CmdButton(cheats, "What is on", 4, -18 - #rows * 28 - 6, 130, ".cheat status")

-- Teleport --------------------------------------------------------------------------------------

-- Names from the world database's `game_tele`.
local tele = AA:Page("Teleport")
local PLACES = {
  { "Cities", { "Stormwind", "Ironforge", "Darnassus", "TheExodar", "Orgrimmar", "ThunderBluff", "Undercity",
    "SilvermoonCity", "ShrineofSevenStars", "ShrineofTwoMoons", "Shattrath", "Dalaran", "BootyBay",
    "Gadgetzan", "TolBaradPeninsula", "DarkmoonFaire" } },
  { "Pandaria", { "TheWanderingIsle", "TheJadeForest", "ValleyoftheFourWinds", "KrasarangWilds", "KunLaiSummit",
    "TownlongSteppes", "DreadWastes", "ValeofEternalBlossoms", "TheVeiledStair", "IsleofGiants",
    "TimelessIsle" } },
  { "Dungeons", { "TempleoftheJadeSerpent", "StormstoutBrewery", "ShadoPanMonastery", "MogushanPalace",
    "GateoftheSettingSun", "SiegeofNiuzaoTemple", "ScarletMonastery", "Scholomance", "MogushanVaults",
    "HearthofFear", "TerraceofEndlessSpring", "ThroneofThunder", "SiegeofOrgrimmar" } },
  { "Older", { "HellfirePeninsula", "Zangarmarsh", "Nagrand", "Netherstorm", "BoreanTundra", "HowlingFjord",
    "GrizzlyHills", "SholazarBasin", "StormPeaks", "Icecrown", "MountHyjal", "Deepholm", "Uldum",
    "TwilightHighlands", "MoltenCore", "Karazhan", "BlackTemple", "Ulduar", "IcecrownCitadelRaid",
    "Firelands", "DragonSoul" } },
}
local placeButtons = {}
for i = 1, 36 do
  local b = AA:Button(tele, "", 0, 0, 104, nil)
  b:ClearAllPoints()
  local index = i - 1
  b:SetPoint("TOPLEFT", tele, "TOPLEFT", (index % 4) * 106, -26 - math.floor(index / 4) * 23)
  b:SetHeight(21)
  b:Hide()
  placeButtons[i] = b
end
local function showPlaces(group)
  local list = PLACES[group][2]
  for i, b in ipairs(placeButtons) do
    local id = list[i]
    if id then
      b:SetText(AA:Pretty(id))
      b:SetScript("OnClick", function() AA:Cmd(".tele " .. id) end)
      b:Show()
    else
      b:Hide()
    end
  end
end
for i, group in ipairs(PLACES) do
  AA:Button(tele, group[1], (i - 1) * 106, 0, 104, function() showPlaces(i) end)
end
showPlaces(1)
local teleBox = AA:Input(tele, "Any place (.tele name), or search", 0, -238, 200, function(text)
  if text ~= "" then AA:Cmd(".tele " .. text) end
end)
AA:Button(tele, "Go", 214, -250, 60, function()
  if teleBox:GetText() ~= "" then AA:Cmd(".tele " .. teleBox:GetText()) end
end)
AA:Button(tele, "Search", 278, -250, 70, function()
  if teleBox:GetText() ~= "" then AA:Cmd(".lookup tele " .. teleBox:GetText()) end
end)

-- Items -----------------------------------------------------------------------------------------

local items = AA:Page("Items")
local results, resultRows = {}, {}
local searching = 0
local search = AA:Input(items, "Search items by name", 0, 0, 230, nil)
local function runSearch()
  local text = search:GetText()
  if text == "" then return end
  results = {}
  for _, row in ipairs(resultRows) do row:Hide() end
  searching = GetTime() + 3
  AA:Cmd(".lookup item " .. text)
end
search:SetScript("OnEnterPressed", function(self) runSearch(); self:ClearFocus() end)
AA:Button(items, "Search", 244, -12, 80, runSearch)

for i = 1, 9 do
  local row = CreateFrame("Frame", nil, items)
  row:SetWidth(AA.WIDTH - 36)
  row:SetHeight(22)
  row:SetPoint("TOPLEFT", items, "TOPLEFT", 0, -40 - (i - 1) * 23)
  row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
  row.text:SetWidth(270)
  row.text:SetJustifyH("LEFT")
  row.one = AA:Button(row, "Add", 280, 0, 56, nil)
  row.many = AA:Button(row, "Add 20", 340, 0, 66, nil)
  row:Hide()
  resultRows[i] = row
end

local function showResults()
  for i, row in ipairs(resultRows) do
    local r = results[i]
    if r then
      row.text:SetText(r.link)
      row.one:SetScript("OnClick", function() AA:Cmd(".additem " .. r.id) end)
      row.many:SetScript("OnClick", function() AA:Cmd(".additem " .. r.id .. " 20") end)
      row:Show()
    else
      row:Hide()
    end
  end
end

local idBox = AA:Input(items, "Item ID", 0, -252, 80, nil)
local countBox = AA:Input(items, "Count", 100, -252, 50, nil)
AA:Button(items, "Add item", 170, -264, 90, function()
  local id = tonumber(idBox:GetText())
  if id then AA:Cmd(".additem " .. id .. " " .. (tonumber(countBox:GetText()) or 1)) end
end)

-- Bots --------------------------------------------------------------------------------------------

-- The playerbots module: random bots play the world on their own; `addclass` brings one of your
-- level into your party. They take orders in party chat.
local bots = AA:Page("Bots")
AA:Label(bots, "Add a bot of your level", 0, 0)
local CLASSES = { { "Warrior", "warrior" }, { "Paladin", "paladin" }, { "Hunter", "hunter" },
  { "Rogue", "rogue" }, { "Priest", "priest" }, { "Death Knight", "dk" }, { "Shaman", "shaman" },
  { "Mage", "mage" }, { "Warlock", "warlock" }, { "Monk", "monk" }, { "Druid", "druid" } }
for i, c in ipairs(CLASSES) do
  local index = i - 1
  AA:CmdButton(bots, c[1], COL[index % 3 + 1], -18 - math.floor(index / 3) * 26, 130,
    ".playerbots bot addclass " .. c[2])
end
AA:CmdButton(bots, "Remove target bot", COL[3], -18 - 3 * 26, 130, function()
  if UnitExists("target") and UnitIsPlayer("target") then return ".playerbots bot remove " .. UnitName("target") end
end)

AA:Label(bots, "Orders to your party's bots", 0, -130)
local ORDERS = { { "Follow me", "follow" }, { "Stay here", "stay" }, { "Attack my target", "attack" },
  { "Leave the party", "leave" } }
for i, order in ipairs(ORDERS) do
  local index = i - 1
  local say = order[2]
  AA:Button(bots, order[1], COL[index % 3 + 1], -148 - math.floor(index / 3) * 26, 130, function()
    if IsInGroup() then
      SendChatMessage(say, IsInRaid() and "RAID" or "PARTY")
      AA.reply:SetText("|cff888888> /p " .. say .. "|r")
    end
  end)
end
AA:Button(bots, "Invite target", COL[2], -174, 130, function()
  if UnitExists("target") and UnitIsPlayer("target") then InviteUnit(UnitName("target")) end
end)
AA:CmdButton(bots, "List my bots", COL[3], -174, 130, ".playerbots bot list")
AA:CmdButton(bots, "Bots online", COL[1], -200, 130, ".playerbots rndbot stats")
local note = bots:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
note:SetPoint("TOPLEFT", bots, "TOPLEFT", 0, -232)
note:SetWidth(AA.WIDTH - 40)
note:SetJustifyH("LEFT")
note:SetText("Bots level, quest and group across the world. Invite one like any player, or add one of a class. In party chat they also answer other orders: \"help\" lists them.")

-- Target and world ------------------------------------------------------------------------------

local world = AA:Page("World")
AA:Label(world, "Your target", 0, 0)
AA:CmdButton(world, "Kill", COL[1], -18, 130, ".die")
AA:CmdButton(world, "Revive player", COL[2], -18, 130, ".revive")
AA:CmdButton(world, "Info", COL[3], -18, 130, ".npc info")
AA:CmdButton(world, "Summon to me", COL[1], -44, 130, function()
  if UnitExists("target") and UnitIsPlayer("target") then return ".summon " .. UnitName("target") end
end)
AA:CmdButton(world, "Go to them", COL[2], -44, 130, function()
  if UnitExists("target") and UnitIsPlayer("target") then return ".appear " .. UnitName("target") end
end)
AA:CmdButton(world, "Stop combat", COL[3], -44, 130, ".combatstop")

AA:Label(world, "Around you", 0, -76)
AA:CmdButton(world, "Respawn nearby", COL[1], -94, 130, ".respawn")
AA:CmdButton(world, "Where am I", COL[2], -94, 130, ".gps")
AA:CmdButton(world, "Recall", COL[3], -94, 130, ".recall")

AA:Label(world, "Server", 0, -126)
AA:CmdButton(world, "Server info", COL[1], -144, 130, ".server info")
AA:CmdButton(world, "Save everyone", COL[2], -144, 130, ".saveall")
AA:CmdButton(world, "All commands", COL[3], -144, 130, ".commands")
AA:Input(world, "Announce to everyone", 0, -176, 300, function(text)
  if text ~= "" then AA:Cmd(".announce " .. text) end
end)

-- The server's answers ------------------------------------------------------------------------------

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_SYSTEM")
listener:RegisterEvent("ADDON_LOADED")
listener:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= "AzerothAdmin" then return end
    AzerothAdminDB = AzerothAdminDB or {}
    -- Every cheat starts off at login, so the boxes do too.
    AzerothAdminDB.toggles = {}
    AA:Show(math.min(AzerothAdminDB.tab or 1, #AA.pages))
    AA.placeButton(AzerothAdminDB.minimapAngle or 200)
    return
  end
  AA.reply:SetText(arg1)
  -- `.lookup item` answers one line per item: "<id> - |cffffffff|Hitem:<id>:...|h[<name>]|h|r".
  if GetTime() < searching then
    local id = string.match(arg1, "|Hitem:(%d+):")
    local link = string.match(arg1, "(|c%x+|Hitem:.-|h|r)")
    if id and link and #results < #resultRows then
      table.insert(results, { id = id, link = link })
      showResults()
    end
  end
end)

-- The minimap button and /aa: a round button on the minimap's rim, dragged around it, as the stock
-- tracking button is drawn (`Minimap.xml`).
local button = CreateFrame("Button", "AzerothAdminMinimapButton", Minimap)
button:SetWidth(33)
button:SetHeight(33)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
button:RegisterForClicks("LeftButtonUp")
button:RegisterForDrag("LeftButton")
local background = button:CreateTexture(nil, "BACKGROUND")
background:SetWidth(20)
background:SetHeight(20)
background:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetWidth(20)
icon:SetHeight(20)
icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)
icon:SetTexture("Interface\\Icons\\Trade_Engineering")
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
local border = button:CreateTexture(nil, "OVERLAY")
border:SetWidth(52)
border:SetHeight(52)
border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

-- On the rim at `angle` degrees, counter-clockwise from the right.
local function place(angle)
  local r = math.rad(angle)
  button:ClearAllPoints()
  button:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 52 - 80 * math.cos(r), 80 * math.sin(r) - 52)
end
place(200)
AA.placeButton = place

local function follow()
  local x, y = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  local cx, cy = Minimap:GetCenter()
  local angle = math.deg(math.atan2(y / scale - cy, x / scale - cx))
  AzerothAdminDB.minimapAngle = angle
  place(angle)
end
button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", follow) end)
button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
button:SetScript("OnClick", function() AA:ToggleWindow() end)
button:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText("Azeroth Admin")
  GameTooltip:AddLine("Click: game master tools for your server (/aa).", 1, 1, 1)
  GameTooltip:AddLine("Drag: move this button around the minimap.", 1, 1, 1)
  GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

function AA:ToggleWindow()
  if self.window:IsShown() then self.window:Hide() else self.window:Show() end
end

SLASH_AZEROTHADMIN1 = "/aa"
SLASH_AZEROTHADMIN2 = "/azerothadmin"
SlashCmdList["AZEROTHADMIN"] = function() AA:ToggleWindow() end
