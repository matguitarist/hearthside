-- A unit's health in numbers in its tooltip, which this client shows only as a bar. (It does
-- the rest the 1.12 addon adds itself: sell prices, real creature health, quest progress.)

local AP = AzerothPlus

GameTooltip:HookScript("OnTooltipSetUnit", function(tip)
  if not AP:Setting("tipHealth") then return end
  local _, unit = tip:GetUnit()
  if not unit then return end
  local cur, max = UnitHealth(unit), UnitHealthMax(unit)
  if not max or max <= 0 then return end
  tip:AddLine(AP:FormatNumber(cur) .. " / " .. AP:FormatNumber(max) .. " health", 0.5, 1, 0.5)
end)
