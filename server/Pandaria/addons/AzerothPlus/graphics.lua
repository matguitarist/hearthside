-- The Graphics tab: Hearthside's ambient occlusion and ground mist, drawn by glhook, the library
-- Hearthside adds to this client. An addon cannot reach it, but glhook watches the files the client
-- opens: showing glhook\<what>-<value>.blp, a clear 1x1 image, is a request. The client opens a
-- file again whenever a texture changes to it, so the texture is cleared first, and loads only the
-- last of two changes in one frame, so each setting has its own texture.
-- glhook.lua holds what the game started with; the keys (Control-Option-O, -M and -F) change the
-- effects behind this tab's back, and it shows what it last set.

local AP = AzerothPlus

local SWITCH = { { 1, "On" }, { 0, "Off" }, { 2, "Alone" } }
local ROWS = {
  { "ao", "Ambient occlusion", SWITCH },
  { "mist", "Ground mist", SWITCH },
  { "fog", "Fog level", { { 1, "Low" }, { 2, "Fair" }, { 3, "Good" }, { 4, "High" }, { 5, "Ultra" } } },
}

local holder = CreateFrame("Frame", nil, UIParent)
holder:SetWidth(1)
holder:SetHeight(1)
holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
local requests = {}

local function send(key, value)
  local request = requests[key]
  if not request then
    request = holder:CreateTexture(nil, "BACKGROUND")
    request:SetAllPoints(holder)
    requests[key] = request
  end
  request:SetTexture(nil)
  request:SetTexture("Interface\\AddOns\\AzerothPlus\\glhook\\" .. key .. "-" .. value)
  AzerothPlusGraphics[key] = value
end

local page = AP.optionPages.Graphics
local menus = {}

local function label(choices, value)
  for _, c in ipairs(choices) do
    if c[1] == value then return c[2] end
  end
  return ""
end

local function refresh()
  for _, menu in ipairs(menus) do
    UIDropDownMenu_SetText(menu, label(menu.choices, AzerothPlusGraphics[menu.key]))
  end
end

for i, row in ipairs(ROWS) do
  local key, choices = row[1], row[3]
  local text = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  text:SetPoint("TOPLEFT", page, "TOPLEFT", 4, -8 - (i - 1) * 34)
  text:SetText(row[2])
  local menu = CreateFrame("Frame", "AzerothPlusGraphics" .. key, page, "UIDropDownMenuTemplate")
  menu:SetPoint("TOPLEFT", page, "TOPLEFT", 150, -(i - 1) * 34)
  menu.key, menu.choices = key, choices
  UIDropDownMenu_SetWidth(menu, 110)
  UIDropDownMenu_Initialize(menu, function(self, level)
    for _, c in ipairs(choices) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = c[2]
      info.checked = AzerothPlusGraphics[key] == c[1]
      info.func = function()
        send(key, c[1])
        -- A fog level is for seeing the mist, as with Control-Option-F.
        if key == "fog" and AzerothPlusGraphics.mist == 0 then send("mist", 1) end
        refresh()
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  table.insert(menus, menu)
end

local note = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
note:SetPoint("TOPLEFT", page, "TOPLEFT", 4, -8 - #ROWS * 34)
note:SetWidth(432)
note:SetJustifyH("LEFT")
note:SetText("Hearthside's effects, added to this client: they work when Hearthside prepared it. Alone shows " ..
  "the effect without the scene. Each level of fog is smoother and reaches further, for some frame rate. " ..
  "Control-Option-O, -M and -F change them too. Settings › Pandaria sets them for the next game.")

page:SetScript("OnShow", refresh)
