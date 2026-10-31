-- The bot party panel (/ap bots): finds characters of about your level in your zone (on a
-- playerbots realm, mostly bots), invites them, and gives the party the playerbots commands, which
-- bots read from party chat ("follow", "attack"...). Any 1.12 realm takes the invites; only a
-- playerbots one answers the commands.

local AP = AzerothPlus

local COMMANDS = {
  { "Follow", "follow", "Follow you" },
  { "Stay", "stay", "Stay where they are" },
  { "Attack", "attack", "Attack your target" },
  { "Flee", "flee", "Run back to you, leaving the fight" },
  { "Grind", "grind", "Fight what is around on their own" },
  { "Summon", "summon", "Come to you (a bot within reach of a meeting stone or near you)" },
  { "Revive", "revive", "Release, run back and revive after dying" },
  { "Leave", "leave", "Leave the party" },
}
local RESULTS = 8
local WIDTH = 260

local panel = CreateFrame("Frame", "AzerothPlusBots", UIParent)
panel:SetWidth(WIDTH)
panel:SetHeight(392)
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

local count = 0
local function button(parent, text, width, onClick)
  count = count + 1
  local b = CreateFrame("Button", "AzerothPlusBotsButton" .. count, parent, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(20)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function label(text, y)
  local t = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  t:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, y)
  t:SetText(text)
  return t
end

-- The party's chat, or the raid's; nil when alone.
local function channel()
  if GetNumRaidMembers() > 0 then return "RAID" end
  if GetNumPartyMembers() > 0 then return "PARTY" end
  return nil
end

local function send(command)
  local to = channel()
  if not to then
    AP:Print("invite some bots first: the commands go to your party.")
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
  for i = 1, GetNumPartyMembers() do
    local unit = "party" .. i
    local _, class = UnitClass(unit)
    table.insert(lines, classColor(class) .. (UnitName(unit) or "?") .. "|r  " .. (UnitLevel(unit) or "") ..
      " " .. (UnitClass(unit) or ""))
  end
  members:SetText(table.getn(lines) > 0 and table.concat(lines, "\n") or "|cff888888Nobody yet: find bots below.|r")
end

-- The commands, two across.
local commandsTop = -46 - 4 * 13 - 8
label("Commands", commandsTop)
for i, c in ipairs(COMMANDS) do
  local command, tip = c[2], c[3]
  local b = button(panel, c[1], (WIDTH - 30) / 2, function() send(command) end)
  b:SetPoint("TOPLEFT", panel, "TOPLEFT", 12 + math.mod(i - 1, 2) * ((WIDTH - 30) / 2 + 6),
    commandsTop - 14 - math.floor((i - 1) / 2) * 22)
  b:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText(tip)
    GameTooltip:AddLine("Says \"" .. command .. "\" to the party.", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
  row.invite = button(row, "Invite", 60, function() InviteByName(this:GetParent().name) end)
  row.invite:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row:Hide()
  rows[i] = row
end

local pending = false
local function showResults()
  local shown = 0
  local me = UnitName("player")
  for i = 1, GetNumWhoResults() do
    local name, guild, level, race, class = GetWhoInfo(i)
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
  if FriendsFrame then FriendsFrame:UnregisterEvent("WHO_LIST_UPDATE") end
  SetWhoToUI(1)
  SendWho('z-"' .. zone .. '" ' .. math.max(1, level - 3) .. "-" .. math.min(60, level + 3))
end)
find:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, findTop - 14 - RESULTS * 21 - 4)

local events = CreateFrame("Frame")
events:RegisterEvent("WHO_LIST_UPDATE")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("RAID_ROSTER_UPDATE")
events:RegisterEvent("UNIT_LEVEL")
events:SetScript("OnEvent", function()
  if event == "WHO_LIST_UPDATE" then
    if not pending then return end
    pending = false
    SetWhoToUI(0)
    if FriendsFrame then FriendsFrame:RegisterEvent("WHO_LIST_UPDATE") end
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
