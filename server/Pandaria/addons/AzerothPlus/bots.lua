-- The bot party panel (/ap bots): adds a bot of a class at your level (the playerbots module's
-- `.playerbots bot addclass`, a player command on the Pandaria server), finds characters of about
-- your level in your zone (mostly bots there) to invite, and gives the party the playerbots
-- orders, which bots read from party chat ("follow", "attack"...).

local AP = AzerothPlus

local COMMANDS = {
  { "Follow", "follow", "Follow you" },
  { "Stay", "stay", "Stay where they are" },
  { "Attack", "attack", "Attack your target" },
  { "Flee", "flee", "Run back to you, leaving the fight" },
  { "Grind", "grind", "Fight what is around on their own" },
  { "Summon", "summon", "Come to you" },
  { "Revive", "revive", "Release, run back and revive after dying" },
  { "Leave", "leave", "Leave the party" },
}
-- The class names `addclass` takes (`PlayerbotMgr.cpp`).
local CLASSES = { { "Warrior", "warrior" }, { "Paladin", "paladin" }, { "Hunter", "hunter" },
  { "Rogue", "rogue" }, { "Priest", "priest" }, { "Death Knight", "dk" }, { "Shaman", "shaman" },
  { "Mage", "mage" }, { "Warlock", "warlock" }, { "Monk", "monk" }, { "Druid", "druid" } }
local RESULTS = 6
local WIDTH = 280

local panel = CreateFrame("Frame", "AzerothPlusBots", UIParent)
panel:SetWidth(WIDTH)
panel:SetHeight(504)
panel:SetFrameStrata("MEDIUM")
panel:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
panel:EnableMouse(true)
panel.alwaysDrag = true
AP:Movable(panel, "bots", "Bot party", "LEFT", 220, 40)
panel:Hide()
table.insert(UISpecialFrames, "AzerothPlusBots")

local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -10)
heading:SetText("Bot party")
local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)

local function button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(20)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function tooltip(b, title, line)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title)
    if line then GameTooltip:AddLine(line, 0.8, 0.8, 0.8) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function label(text, y)
  local t = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  t:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, y)
  t:SetText(text)
  return t
end

-- The party's chat, or the raid's; nil when alone.
local function channel()
  if IsInRaid() then return "RAID" end
  if IsInGroup() then return "PARTY" end
  return nil
end

local function send(command)
  local to = channel()
  if not to then
    AP:Print("add or invite some bots first: the orders go to your party.")
    return
  end
  SendChatMessage(command, to)
end

-- The party, one line each.
label("Party", -32)
local members = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
members:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -46)
members:SetWidth(WIDTH - 28)
members:SetJustifyH("LEFT")

local function classColor(class)
  local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
  if not c then return "|cffffffff" end
  return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local function updateParty()
  local lines = {}
  for i = 1, GetNumSubgroupMembers() do
    local unit = "party" .. i
    local className, class = UnitClass(unit)
    table.insert(lines, classColor(class) .. (UnitName(unit) or "?") .. "|r  " .. (UnitLevel(unit) or "") ..
      " " .. (className or ""))
  end
  members:SetText(#lines > 0 and table.concat(lines, "\n") or "|cff888888Nobody yet: add or find bots below.|r")
end

-- Adding a bot of a class, three across.
local addTop = -46 - 4 * 13 - 8
label("Add a bot of your level", addTop)
local third = (WIDTH - 24 - 8) / 3
for i, c in ipairs(CLASSES) do
  local class = c[2]
  local b = button(panel, c[1], third, function()
    if not IsInGroup() or UnitIsGroupLeader("player") then
      SendChatMessage(".playerbots bot addclass " .. class, "SAY")
    else
      AP:Print("only the party leader adds bots.")
    end
  end)
  b:SetPoint("TOPLEFT", panel, "TOPLEFT", 12 + ((i - 1) % 3) * (third + 4), addTop - 14 - math.floor((i - 1) / 3) * 22)
  tooltip(b, "Add a " .. c[1], "A bot of this class, at your level, joins your party.")
end
local remove = button(panel, "Remove target", third, function()
  if UnitExists("target") and UnitIsPlayer("target") and UnitInParty("target") then
    SendChatMessage(".playerbots bot remove " .. UnitName("target"), "SAY")
  else
    AP:Print("target a bot in your party first.")
  end
end)
remove:SetPoint("TOPLEFT", panel, "TOPLEFT", 12 + 2 * (third + 4), addTop - 14 - 3 * 22)
tooltip(remove, "Remove your target", "The bot you target logs out.")

-- The orders, two across.
local commandsTop = addTop - 14 - 4 * 22 - 8
label("Orders", commandsTop)
local half = (WIDTH - 24 - 6) / 2
for i, c in ipairs(COMMANDS) do
  local command = c[2]
  local b = button(panel, c[1], half, function() send(command) end)
  b:SetPoint("TOPLEFT", panel, "TOPLEFT", 12 + ((i - 1) % 2) * (half + 6),
    commandsTop - 14 - math.floor((i - 1) / 2) * 22)
  tooltip(b, c[3], "Says \"" .. command .. "\" to the party.")
end

-- Finding bots: a /who of your zone, three levels either side, kept out of the Who window.
local findTop = commandsTop - 14 - 4 * 22 - 10
label("Nearby, about your level", findTop)
local status = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
status:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, findTop)
local rows = {}
for i = 1, RESULTS do
  local row = CreateFrame("Frame", nil, panel)
  row:SetWidth(WIDTH - 24)
  row:SetHeight(20)
  row:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, findTop - 14 - (i - 1) * 21)
  row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row, "LEFT", 2, 0)
  row.invite = button(row, "Invite", 60, function(self) InviteUnit(self:GetParent().name) end)
  row.invite:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row:Hide()
  rows[i] = row
end

local pending = false
local function showResults()
  local shown = 0
  local me = UnitName("player")
  for i = 1, GetNumWhoResults() do
    local name, _, level, _, class = GetWhoInfo(i)
    if name and name ~= me and shown < RESULTS then
      shown = shown + 1
      local row = rows[shown]
      row.name = name
      row.text:SetText(name .. "  |cffbbbbbb" .. level .. " " .. (class or "") .. "|r")
      row:Show()
    end
  end
  for i = shown + 1, RESULTS do rows[i]:Hide() end
  status:SetText(shown == 0 and "nobody found" or "")
end

local find = button(panel, "Find", 70, function()
  local level = UnitLevel("player")
  local zone = GetRealZoneText() or ""
  pending = true
  status:SetText("looking…")
  -- The Who window would open on the answer; it takes the event back once this one is read.
  FriendsFrame:UnregisterEvent("WHO_LIST_UPDATE")
  SetWhoToUI(1)
  SendWho('z-"' .. zone .. '" ' .. math.max(1, level - 3) .. "-" .. math.min(MAX_PLAYER_LEVEL or 90, level + 3))
end)
find:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, findTop - 14 - RESULTS * 21 - 4)

local events = CreateFrame("Frame")
events:RegisterEvent("WHO_LIST_UPDATE")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("UNIT_LEVEL")
events:SetScript("OnEvent", function(self, event)
  if event == "WHO_LIST_UPDATE" then
    if not pending then return end
    pending = false
    SetWhoToUI(0)
    FriendsFrame:RegisterEvent("WHO_LIST_UPDATE")
    showResults()
  else
    updateParty()
  end
end)

panel:SetScript("OnShow", updateParty)
-- Closed by its button or Escape: it stays closed next time.
panel:SetScript("OnHide", function() if AzerothPlusDB and AzerothPlusDB.locked then AzerothPlusDB.botPanel = false end end)
panel.refresh = function()
  if not AzerothPlusDB.botPanel then panel:Hide() end
end

function AP:ToggleBots()
  AP:Set("botPanel", not panel:IsShown())
end

AP:Register("botPanel", { enable = function(on) if on then panel:Show() else panel:Hide() end end })
