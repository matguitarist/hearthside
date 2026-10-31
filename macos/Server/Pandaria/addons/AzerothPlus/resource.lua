-- Personal resource display: your health and power just under your character, shown in combat (or
-- always), with combo points for rogues and cat-form druids.

local AP = AzerothPlus

local WIDTH = 160

local frame = CreateFrame("Frame", "AzerothPlusResource", UIParent)
frame:SetWidth(WIDTH)
frame:SetHeight(28)
AP:Movable(frame, "resource", "Personal resource", "CENTER", 0, -110)

local function bar(y, height)
  local b = CreateFrame("StatusBar", nil, frame)
  b:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  b:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, y)
  b:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, y)
  b:SetHeight(height)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  b.bg:SetTexture(0, 0, 0, 0.6)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
  return b
end

local health = bar(0, 12)
health:SetStatusBarColor(0.1, 0.8, 0.1)
local power = bar(-13, 8)

local combo = {}
for i = 1, MAX_COMBO_POINTS or 5 do
  local c = frame:CreateTexture(nil, "OVERLAY")
  c:SetWidth(14)
  c:SetHeight(14)
  c:SetTexture("Interface\\ComboFrame\\ComboPoint")
  c:SetTexCoord(0, 0.375, 0, 1)
  c:SetPoint("TOP", frame, "BOTTOM", (i - 3) * 16, -2)
  c:Hide()
  combo[i] = c
end

local function update()
  local hp, hpMax = UnitHealth("player"), UnitHealthMax("player")
  health:SetMinMaxValues(0, math.max(hpMax, 1))
  health:SetValue(hp)
  health.text:SetText(AP:FormatNumber(hp) .. " / " .. AP:FormatNumber(hpMax))
  local mp, mpMax = UnitPower("player"), UnitPowerMax("player")
  power:SetMinMaxValues(0, math.max(mpMax, 1))
  power:SetValue(mp)
  local _, token = UnitPowerType("player")
  local color = PowerBarColor[token]
  if color then power:SetStatusBarColor(color.r, color.g, color.b) end
  power.text:SetText(mpMax > 0 and AP:FormatNumber(mp) or "")
  local points = AzerothPlusDB.combo and GetComboPoints("player", "target") or 0
  for i = 1, #combo do
    if i <= points then combo[i]:Show() else combo[i]:Hide() end
  end
end

-- In combat, or with the setting off, always; unlocked, always so it can be placed.
local function visible()
  if not AzerothPlusDB.resource then return false end
  if not AzerothPlusDB.locked or not AzerothPlusDB.resourceInCombatOnly then return true end
  return UnitAffectingCombat("player")
end

local function refresh()
  if visible() then
    update()
    frame:Show()
  else
    frame:Hide()
  end
end

local driver = CreateFrame("Frame")
driver:SetScript("OnEvent", function(self, event, unit)
  if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ENTERING_WORLD" then
    refresh()
  elseif frame:IsShown() and (not unit or unit == "player" or event == "UNIT_COMBO_POINTS") then
    update()
  end
end)

local events = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
  "UNIT_COMBO_POINTS", "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
  "PLAYER_ENTERING_WORLD" }

local function enable(on)
  for _, e in ipairs(events) do
    if on then driver:RegisterEvent(e) else driver:UnregisterEvent(e) end
  end
  refresh()
end
frame.refresh = refresh

AP:Register("resource", { enable = enable })
AP:Register("combo", { enable = function() refresh() end })
AP:Register("resourceInCombatOnly", { enable = function() refresh() end })
