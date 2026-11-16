-- Swing timer: a bar that fills until your next main-hand swing, and one for Auto Shot. A swing is
-- your melee hit or miss in the combat log; on this client no ability replaces the next swing, so
-- those are all there is. Dual wielding, the off hand's swings restart the bar too.

local AP = AzerothPlus

local AUTO_SHOT = 75

local function newBar(name, label, y, r, g, b)
  local bar = CreateFrame("StatusBar", name, UIParent)
  bar:SetWidth(200)
  bar:SetHeight(10)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(r, g, b)
  bar:SetMinMaxValues(0, 1)
  bar.bg = bar:CreateTexture(nil, "BACKGROUND")
  bar.bg:SetAllPoints(bar)
  bar.bg:SetTexture(0, 0, 0, 0.6)
  bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
  AP:Movable(bar, name, label, "CENTER", 0, y)
  bar:Hide()
  return bar
end

local melee = newBar("AzerothPlusSwing", "Swing timer", -150, 0.9, 0.75, 0.3)
local ranged = newBar("AzerothPlusAutoShot", "Auto Shot timer", -164, 0.4, 0.8, 0.3)

local function start(bar, speed)
  if not speed or speed <= 0 then return end
  bar.started, bar.speed = GetTime(), speed
  bar:Show()
end

local function update()
  local now = GetTime()
  for _, bar in ipairs({ melee, ranged }) do
    if bar.started then
      local done = (now - bar.started) / bar.speed
      if done >= 1 then
        bar:SetValue(1)
        bar.text:SetText("")
        -- Still attacking keeps the full bar up for the next swing; otherwise it goes.
        if not bar.attacking then bar.started = nil; if AzerothPlusDB.locked then bar:Hide() end end
      else
        bar:SetValue(done)
        bar.text:SetText(string.format("%.1f", bar.speed * (1 - done)))
      end
    end
  end
end

-- Events and timing run on their own frame: a hidden bar gets no OnUpdate.
local driver = CreateFrame("Frame")

driver:SetScript("OnEvent", function(self, event, ...)
  if event == "COMBAT_LOG_EVENT_UNFILTERED" then
    local _, kind, _, source = ...
    if source == UnitGUID("player") and (kind == "SWING_DAMAGE" or kind == "SWING_MISSED") then
      start(melee, (UnitAttackSpeed("player")))
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, _, _, spell = ...
    if unit == "player" and spell == AUTO_SHOT then start(ranged, (UnitRangedDamage("player"))) end
  elseif event == "PLAYER_ENTER_COMBAT" then
    melee.attacking = true
  elseif event == "PLAYER_LEAVE_COMBAT" then
    melee.attacking = false
  elseif event == "START_AUTOREPEAT_SPELL" then
    ranged.attacking = true
  elseif event == "STOP_AUTOREPEAT_SPELL" then
    ranged.attacking = false
  end
end)

local events = { "COMBAT_LOG_EVENT_UNFILTERED", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_ENTER_COMBAT",
  "PLAYER_LEAVE_COMBAT", "START_AUTOREPEAT_SPELL", "STOP_AUTOREPEAT_SPELL" }

local function enable(on)
  for _, e in ipairs(events) do
    if on then driver:RegisterEvent(e) else driver:UnregisterEvent(e) end
  end
  driver:SetScript("OnUpdate", on and update or nil)
  if not on then
    melee.started, ranged.started = nil, nil
    melee:Hide()
    ranged:Hide()
  end
end
-- The bars are seen only while they run; locking puts them back to that.
melee.refresh = function() if not melee.started then melee:Hide() end end
ranged.refresh = function() if not ranged.started then ranged:Hide() end end

AP:Register("swing", { enable = enable })
