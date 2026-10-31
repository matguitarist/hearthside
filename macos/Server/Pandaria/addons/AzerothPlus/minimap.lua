-- Minimap: your coordinates under it.

local AP = AzerothPlus

local coords = CreateFrame("Frame", "AzerothPlusCoords", MinimapCluster)
coords:SetWidth(70)
coords:SetHeight(16)
coords:SetPoint("TOP", Minimap, "BOTTOM", 0, -4)
coords:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
coords:SetBackdropColor(0, 0, 0, 0.5)
coords:Hide()
local text = coords:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
text:SetPoint("CENTER", coords, "CENTER", 0, 0)

-- GetPlayerMapPosition reads the map's current zone, so point it back at where you are whenever
-- you move between zones or close the map on another one.
local function here()
  if not WorldMapFrame:IsShown() then SetMapToCurrentZone() end
end

local elapsedSince = 0
coords:SetScript("OnUpdate", function(self, elapsed)
  elapsedSince = elapsedSince + elapsed
  if elapsedSince < 0.2 then return end
  elapsedSince = 0
  local x, y = GetPlayerMapPosition("player")
  if not x or (x == 0 and y == 0) then
    text:SetText("")
    self:SetAlpha(0)
  else
    text:SetText(string.format("%.1f, %.1f", x * 100, y * 100))
    self:SetAlpha(1)
  end
end)
coords:SetScript("OnEvent", here)

WorldMapFrame:HookScript("OnHide", function()
  if AP:Setting("minimap") then SetMapToCurrentZone() end
end)

AP:Register("minimap", {
  enable = function(on)
    if on then
      for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED",
        "ZONE_CHANGED_INDOORS" }) do
        coords:RegisterEvent(e)
      end
      here()
      coords:Show()
    else
      coords:UnregisterAllEvents()
      coords:Hide()
    end
  end,
})
