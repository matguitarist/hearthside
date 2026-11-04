-- The options window (/ap): a tab per kind of feature, a checkbox per feature, and the lock that
-- lets frames be dragged. A row's third field is its tooltip.

local AP = AzerothPlus

local PAGES = {
  { "Combat", {
    { "cooldowns", "Cooldown manager: spells, trinkets and potions" },
    { "buffs", "Cooldown manager: your timed buffs" },
    { "meter", "Damage meter", "/ap meter reset clears it." },
    { "swing", "Swing and Auto Shot timer" },
    { "resource", "Personal resource display" },
    { "resourceInCombatOnly", "    Only in combat" },
    { "combo", "    Combo points" },
  } },
  { "Interface", {
    { "centerFrames", "Player and target frames: smaller, centered",
      "They cannot move in combat: a change then waits for it to end." },
    { "tipHealth", "Health in numbers in unit tooltips" },
    { "minimap", "Coordinates under the minimap" },
  } },
  { "Quests", {
    { "questLevels", "Quest levels in the quest log", "[12] for a level 12 quest, [30+] for an elite one." },
    { "autoQuest", "Accept and hand in quests automatically",
      "Hold Shift while talking to a quest giver to do it yourself. Rewards to choose from, grey quests, " ..
      "and quests that cost money or flag you for PvP are left to you." },
  } },
  { "Items", {
    { "sellGreys", "Sell grey items at vendors", "Hold Shift while opening a vendor to keep them." },
    { "autoRepair", "Repair everything at vendors that can" },
    { "guildRepair", "    From the guild bank when allowed" },
  } },
  -- Filled by graphics.lua.
  { "Graphics", {} },
  { "Bots", {
    { "botPanel", "Bot party panel",
      "Add bots of your level, find bots nearby, and command your party. /ap bots opens it too." },
  } },
}

local WIDTH, ROW = 480, 26
local most = 0
for _, page in ipairs(PAGES) do most = math.max(most, #page[2]) end

local panel = CreateFrame("Frame", "AzerothPlusOptions", UIParent)
panel:SetWidth(WIDTH)
panel:SetHeight(120 + most * ROW)
panel:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
panel:SetFrameStrata("DIALOG")
panel:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
panel:EnableMouse(true)
panel:SetMovable(true)
panel:SetClampedToScreen(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:Hide()
table.insert(UISpecialFrames, "AzerothPlusOptions") -- Escape closes it

local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
heading:SetPoint("TOP", panel, "TOP", 0, -18)
heading:SetText("AzerothPlus")

local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

local tabs, pages, boxes = {}, {}, {}
AP.optionPages = {}
local tabWidth = math.floor((WIDTH - 40) / #PAGES)

local function show(n)
  for i = 1, #pages do
    if i == n then
      pages[i]:Show()
      tabs[i]:LockHighlight()
    else
      pages[i]:Hide()
      tabs[i]:UnlockHighlight()
    end
  end
  AzerothPlusDB.optionsTab = n
end

for p, def in ipairs(PAGES) do
  local n = p
  local tab = CreateFrame("Button", "AzerothPlusOptionsTab" .. p, panel, "UIPanelButtonTemplate")
  tab:SetWidth(tabWidth - 2)
  tab:SetHeight(22)
  tab:SetPoint("TOPLEFT", panel, "TOPLEFT", 20 + (p - 1) * tabWidth, -42)
  tab:SetText(def[1])
  tab:SetScript("OnClick", function() show(n) end)
  tabs[p] = tab

  local page = CreateFrame("Frame", nil, panel)
  page:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -72)
  page:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -20, 48)
  page:Hide()
  pages[p] = page
  AP.optionPages[def[1]] = page

  for i, row in ipairs(def[2]) do
    local key, tip = row[1], row[3]
    local box = CreateFrame("CheckButton", "AzerothPlusOption" .. key, page, "OptionsCheckButtonTemplate")
    box:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -(i - 1) * ROW)
    _G[box:GetName() .. "Text"]:SetText(row[2])
    box:SetScript("OnClick", function(self)
      AP:Set(key, self:GetChecked() and true or false)
    end)
    if tip then
      box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(row[2], 1, 1, 1)
        GameTooltip:AddLine(tip, nil, nil, nil, 1)
        GameTooltip:Show()
      end)
      box:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    box.key = key
    table.insert(boxes, box)
  end
end

-- The Bots page's note: what it needs from the realm.
local botsNote = pages[#pages]:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
botsNote:SetPoint("TOPLEFT", pages[#pages], "TOPLEFT", 4, -ROW - 8)
botsNote:SetWidth(WIDTH - 48)
botsNote:SetJustifyH("LEFT")
botsNote:SetText("The commands work on a realm with playerbots, such as the home server's Pandaria one. " ..
  "Bots join when added or invited and take orders from party chat: follow, stay, attack your target, and more.")

local lock = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
lock:SetWidth(130)
lock:SetHeight(22)
lock:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 18)
local function lockText()
  lock:SetText(AzerothPlusDB.locked and "Move Frames" or "Lock Frames")
end
lock:SetScript("OnClick", function()
  AP:Set("locked", not AzerothPlusDB.locked)
  lockText()
end)

local resetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
resetButton:SetWidth(130)
resetButton:SetHeight(22)
resetButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -20, 18)
resetButton:SetText("Reset Positions")
resetButton:SetScript("OnClick", function() AP:ResetPositions() end)

panel:SetScript("OnShow", function()
  for _, box in ipairs(boxes) do box:SetChecked(AzerothPlusDB[box.key]) end
  lockText()
  show(math.min(AzerothPlusDB.optionsTab or 1, #pages))
end)

function AP:ToggleOptions()
  if panel:IsShown() then panel:Hide() else panel:Show() end
end
