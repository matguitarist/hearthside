-- A search box over the backpack: items whose name holds the text stay lit, the rest dim, in
-- every open bag. Escape or an empty box lights them all again.

local AP = AzerothPlus

local query = ""

local box = CreateFrame("EditBox", "AzerothPlusBagSearch", UIParent, "InputBoxTemplate")
box:SetWidth(110)
box:SetHeight(18)
box:SetAutoFocus(false)
box:SetFrameStrata("HIGH")
box:Hide()
local hint = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
hint:SetPoint("LEFT", box, "LEFT", 2, 0)
hint:SetText("Search bags")

-- Each open bag's buttons: `ContainerFrame<n>Item<i>`, the bag its frame's id, the slot its own.
local function apply()
  hint:SetText(query == "" and "Search bags" or "")
  for n = 1, NUM_CONTAINER_FRAMES do
    local frame = getglobal("ContainerFrame" .. n)
    if frame and frame:IsShown() then
      local bag = frame:GetID()
      for i = 1, frame.size or 0 do
        local button = getglobal("ContainerFrame" .. n .. "Item" .. i)
        if button then
          local lit = true
          if query ~= "" then
            local link = GetContainerItemLink(bag, button:GetID())
            local _, _, name = string.find(link or "", "%[(.-)%]")
            lit = name ~= nil and string.find(string.lower(name), query, 1, true) ~= nil
          end
          button:SetAlpha(lit and 1 or 0.25)
        end
      end
    end
  end
end

box:SetScript("OnTextChanged", function()
  query = string.lower(this:GetText() or "")
  apply()
end)
box:SetScript("OnEscapePressed", function()
  this:SetText("")
  this:ClearFocus()
end)
box:SetScript("OnEnterPressed", function() this:ClearFocus() end)

-- Shown on the backpack's frame while it is open, under its title.
local function place()
  local shown
  for n = 1, NUM_CONTAINER_FRAMES do
    local frame = getglobal("ContainerFrame" .. n)
    if frame and frame:IsShown() and frame:GetID() == 0 then shown = frame end
  end
  if shown and AP:Setting("bagSearch") then
    box:SetParent(shown)
    box:ClearAllPoints()
    box:SetPoint("TOPRIGHT", shown, "TOPRIGHT", -12, -28)
    box:SetFrameLevel(shown:GetFrameLevel() + 5)
    box:Show()
  else
    box:Hide()
  end
  apply()
end

local events = CreateFrame("Frame")
events:RegisterEvent("BAG_UPDATE")
events:RegisterEvent("BAG_OPEN")
events:RegisterEvent("BAG_CLOSED")
events:RegisterEvent("ITEM_LOCK_CHANGED")
events:SetScript("OnEvent", place)

-- ContainerFrame_OnShow and OnHide run for every bag frame; the box follows the backpack's.
local onShow, onHide = ContainerFrame_OnShow, ContainerFrame_OnHide
if onShow then ContainerFrame_OnShow = function() onShow() place() end end
if onHide then
  ContainerFrame_OnHide = function()
    onHide()
    if this:GetID() == 0 then
      box:SetText("")
      box:ClearFocus()
    end
    place()
  end
end

AP:Register("bagSearch", { enable = function() place() end })
