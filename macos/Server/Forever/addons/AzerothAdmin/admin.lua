-- AzerothAdmin's pages: each button is one GM command of the Forever server (Karrz1's TrinityCore,
-- `src/server/scripts/Commands/cs_*.cpp`, and the PlayerbotV2 module's `.bot`, see its
-- BOT_COMMANDS.md). They need an administrator account (Settings › Forever); the bot ones work for
-- any player.

local AA = AzerothAdmin
local COL = { 0, 140, 280 }
local MAX_LEVEL = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
-- The home server's realm, as `forever-start` names it. Anywhere else (Blizzard's realms, with
-- the same AddOns folder) the addon stays hidden and sends nothing.
local HOME_REALM = "Hearthside"
AA.home = false

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
AA:CmdButton(char, "Learn class spells", COL[1], -118, 130, ".learn my trainer")
AA:CmdButton(char, "Quest spells", COL[2], -118, 130, ".learn my quests")
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

-- Names from the world database's `game_tele`, with how each shows here. Forever's own places are
-- on maps of their own (Zephras is map 2991).
local tele = AA:Page("Teleport")
local PLACES = {
  { "Cities", { { "Stormwind", "Stormwind" }, { "Ironforge", "Ironforge" }, { "Darnassus", "Darnassus" },
    { "Orgrimmar", "Orgrimmar" }, { "ThunderBluff", "Thunder Bluff" }, { "Undercity", "Undercity" },
    { "BootyBay", "Booty Bay" }, { "Gadgetzan", "Gadgetzan" }, { "Ratchet", "Ratchet" },
    { "Everlook", "Everlook" }, { "Moonglade", "Moonglade" } } },
  { "Forever", { { "Zephras", "Zephras" }, { "HyjalCrater", "Hyjal Crater" }, { "DarkspearIslands", "Darkspear Isles" },
    { "DeadwindPassForever", "Deadwind Pass" }, { "ScarletEnclave", "Scarlet Enclave" },
    { "ExcavationSiteWetlands", "Wetlands Dig" }, { "RuinsOfLordaeron", "Ruins of Lordaeron" },
    { "KarazhanCryptsInside", "Karazhan Crypts" }, { "NaxxramasForever", "Naxxramas" },
    { "DalaranCityForever", "Dalaran" }, { "KroldokStronghold", "Kroldok" }, { "HallOfThanes", "Hall of Thanes" },
    { "EasternKingdomsPreserved", "Preserved EK" } } },
  { "Dungeons", { { "RFC", "Ragefire Chasm" }, { "Deadmines", "Deadmines" }, { "WC", "Wailing Caverns" },
    { "SFK", "Shadowfang Keep" }, { "Bfd", "Blackfathom" }, { "Gnome", "Gnomeregan" }, { "RFK", "Razorfen Kraul" },
    { "SMGY", "SM Graveyard" }, { "SMLib", "SM Library" }, { "SMArmory", "SM Armory" }, { "SMCath", "SM Cathedral" },
    { "RFD", "Razorfen Downs" }, { "Ulda", "Uldaman" }, { "ZulFarrak", "Zul'Farrak" }, { "Maraorange", "Maraudon" },
    { "ST", "Sunken Temple" }, { "BRD", "Blackrock Depths" }, { "LBRS", "Lower Spire" }, { "UBRS", "Upper Spire" },
    { "Dmeast", "Dire Maul East" }, { "Dmwest", "Dire Maul West" }, { "Dmnorth", "Dire Maul North" },
    { "Strat", "Stratholme" }, { "Scholomance", "Scholomance" } } },
  { "Raids", { { "MC", "Molten Core" }, { "onyxia", "Onyxia" }, { "ZulGurub", "Zul'Gurub" },
    { "BWL", "Blackwing Lair" }, { "AQ20", "Ruins of AQ" }, { "AQ40", "Temple of AQ" }, { "Nax", "Naxxramas" },
    { "Karazhan", "Karazhan" } } },
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
    local place = list[i]
    if place then
      b:SetText(place[2])
      b:SetScript("OnClick", function() AA:Cmd(".tele " .. place[1]) end)
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

-- PlayerbotV2: world bots wake around the players on their own; `.bot add` makes a companion of
-- your level, bound to you, and groups it. Companions take orders in party chat.
local bots = AA:Page("Bots")
AA:Label(bots, "Add a companion of your level", 0, 0)
local CLASSES = { { "Warrior", "warrior" }, { "Paladin", "paladin" }, { "Hunter", "hunter" },
  { "Rogue", "rogue" }, { "Priest", "priest" }, { "Shaman", "shaman" },
  { "Mage", "mage" }, { "Warlock", "warlock" }, { "Druid", "druid" } }
for i, c in ipairs(CLASSES) do
  local index = i - 1
  AA:CmdButton(bots, c[1], COL[index % 3 + 1], -18 - math.floor(index / 3) * 26, 130, ".bot add " .. c[2])
end

AA:Label(bots, "Your companions", 0, -100)
AA:CmdButton(bots, "Fill my group", COL[1], -118, 130, ".bot lfg")
AA:CmdButton(bots, "Call saved", COL[2], -118, 130, ".bot call all")
AA:CmdButton(bots, "Save group", COL[3], -118, 130, ".bot save all")
AA:CmdButton(bots, "Dismiss target", COL[1], -144, 130, function()
  if UnitExists("target") and UnitIsPlayer("target") then return ".bot dismiss " .. UnitName("target") end
end)
AA:CmdButton(bots, "Dismiss all", COL[2], -144, 130, ".bot dismiss all")
AA:CmdButton(bots, "List my bots", COL[3], -144, 130, ".bot list")
AA:CmdButton(bots, "Random dungeon", COL[1], -170, 130, ".bot dungeon any")
AA:CmdButton(bots, "Leave dungeon", COL[2], -170, 130, ".bot dungeon leave")
AA:CmdButton(bots, "World bots", COL[3], -170, 130, ".bot world")

AA:Label(bots, "Orders in party chat", 0, -202)
local ORDERS = { { "Follow", "follow" }, { "Stay", "stay" }, { "Attack", "attack" }, { "Come", "come" },
  { "Resume", "resume" }, { "Flee", "flee" } }
local sendChat = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
for i, order in ipairs(ORDERS) do
  local say = order[2]
  AA:Button(bots, order[1], (i - 1) * 70, -220, 66, function()
    if AA.home and IsInGroup() then
      sendChat(say, IsInRaid() and "RAID" or "PARTY")
      AA.reply:SetText("|cff888888> /p " .. say .. "|r")
    end
  end)
end
local note = bots:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
note:SetPoint("TOPLEFT", bots, "TOPLEFT", 0, -250)
note:SetWidth(AA.WIDTH - 40)
note:SetJustifyH("LEFT")
note:SetText("\"help\" in party chat lists every order. World bots wake near players and sleep when nobody is around.")

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
listener:RegisterEvent("PLAYER_LOGIN")
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
  if event == "PLAYER_LOGIN" then
    local realm = GetRealmName() or ""
    AA.home = string.sub(realm, 1, #HOME_REALM) == HOME_REALM
    if AA.home then AA.minimapButton:Show() end
    return
  end
  if not AA.home then return end
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
-- Shown at login on the home realm only.
button:Hide()
AA.minimapButton = button

-- On the rim at `angle` degrees, counter-clockwise from the right.
local function place(angle)
  local r = math.rad(angle)
  -- Just outside the rim, whatever size this client draws the minimap.
  local rim = (Minimap:GetWidth() or 140) / 2 + 10
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", rim * math.cos(r), rim * math.sin(r))
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
  if not self.home then
    print("|cffff7f00AzerothAdmin|r works on your Hearthside server only.")
    return
  end
  if self.window:IsShown() then self.window:Hide() else self.window:Show() end
end

-- The game's addon menu by the minimap (the .toc's AddonCompartmentFunc).
function AzerothAdmin_OnAddonCompartmentClick()
  AA:ToggleWindow()
end

SLASH_AZEROTHADMIN1 = "/aa"
SLASH_AZEROTHADMIN2 = "/azerothadmin"
SlashCmdList["AZEROTHADMIN"] = function() AA:ToggleWindow() end
