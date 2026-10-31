-- The minimap button: a round button on the minimap's rim that opens the options (/ap), dragged
-- around it, drawn as the stock tracking button is (`Minimap.xml`). It starts below Azeroth
-- Admin's, so the two don't overlap.

local AP = AzerothPlus

local ANGLE = 235

local button = CreateFrame("Button", "AzerothPlusMinimapButton", Minimap)
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
icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
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
place(ANGLE)

local function follow()
  local x, y = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  local cx, cy = Minimap:GetCenter()
  local angle = math.deg(math.atan2(y / scale - cy, x / scale - cx))
  AzerothPlusDB.buttonAngle = angle
  place(angle)
end
button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", follow) end)
button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
button:SetScript("OnClick", function() AP:ToggleOptions() end)
button:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText("AzerothPlus")
  GameTooltip:AddLine("Click: options (/ap).", 1, 1, 1)
  GameTooltip:AddLine("Drag: move this button around the minimap.", 1, 1, 1)
  GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
  place(AzerothPlusDB and AzerothPlusDB.buttonAngle or ANGLE)
end)
