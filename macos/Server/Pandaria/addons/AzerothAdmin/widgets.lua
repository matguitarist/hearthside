-- AzerothAdmin for the 5.4.8 client: the window, its tabs, and small builders for buttons,
-- checkboxes and input boxes. The 1.12 addon (`addons/AzerothAdmin`) in this client's Lua 5.1,
-- sending the Pandaria server's TrinityCore commands.

AzerothAdmin = { tabs = {}, pages = {} }
local AA = AzerothAdmin

local WIDTH, HEIGHT = 460, 420
AA.WIDTH = WIDTH

local window = CreateFrame("Frame", "AzerothAdminFrame", UIParent)
window:SetWidth(WIDTH)
window:SetHeight(HEIGHT)
window:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
window:SetFrameStrata("DIALOG")
window:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
window:EnableMouse(true)
window:SetMovable(true)
window:SetClampedToScreen(true)
window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", window.StartMoving)
window:SetScript("OnDragStop", window.StopMovingOrSizing)
window:Hide()
table.insert(UISpecialFrames, "AzerothAdminFrame")
AA.window = window

local heading = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
heading:SetPoint("TOP", window, "TOP", 0, -18)
heading:SetText("Azeroth Admin")

local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", window, "TOPRIGHT", -6, -6)

-- The server's last answer, under the pages.
local reply = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
reply:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 20, 18)
reply:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -20, 18)
reply:SetJustifyH("LEFT")
reply:SetHeight(28)
AA.reply = reply

-- Send a GM command: the server reads a chat line that starts with a dot, and answers in the
-- system channel.
function AA:Cmd(text)
  SendChatMessage(text, "SAY")
  reply:SetText("|cff888888> " .. text .. "|r")
end

-- A page is a frame filling the window between the tab row and the reply line.
function AA:Page(name)
  local page = CreateFrame("Frame", nil, window)
  page:SetPoint("TOPLEFT", window, "TOPLEFT", 18, -70)
  page:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -18, 50)
  page:Hide()
  local i = #self.tabs + 1
  local tab = CreateFrame("Button", "AzerothAdminTab" .. i, window, "UIPanelButtonTemplate")
  tab:SetWidth(70)
  tab:SetHeight(20)
  tab:SetPoint("TOPLEFT", window, "TOPLEFT", 18 + (i - 1) * 71, -42)
  tab:SetText(name)
  tab:SetScript("OnClick", function() AA:Show(i) end)
  self.tabs[i], self.pages[i] = tab, page
  return page
end

function AA:Show(i)
  for j = 1, #self.pages do
    if j == i then
      self.pages[j]:Show()
      self.tabs[j]:LockHighlight()
    else
      self.pages[j]:Hide()
      self.tabs[j]:UnlockHighlight()
    end
  end
  AzerothAdminDB.tab = i
end

local count = 0
local function name()
  count = count + 1
  return "AzerothAdminWidget" .. count
end

-- A button at (x, y) from the page's top left, running `onClick`.
function AA:Button(parent, text, x, y, width, onClick)
  local b = CreateFrame("Button", name(), parent, "UIPanelButtonTemplate")
  b:SetWidth(width or 130)
  b:SetHeight(22)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

-- A button that sends `command` (a string, or a function returning one).
function AA:CmdButton(parent, text, x, y, width, command)
  return self:Button(parent, text, x, y, width, function()
    local c = command
    if type(c) == "function" then c = c() end
    if c then AA:Cmd(c) end
  end)
end

-- A checkbox sending `on` or `off`; it shows what was last sent this session.
function AA:Toggle(parent, text, x, y, key, on, off)
  local box = CreateFrame("CheckButton", name(), parent, "OptionsCheckButtonTemplate")
  box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  _G[box:GetName() .. "Text"]:SetText(text)
  box:SetScript("OnClick", function(self)
    local checked = self:GetChecked() and true or false
    AzerothAdminDB.toggles[key] = checked
    AA:Cmd(checked and on or off)
  end)
  box:SetScript("OnShow", function(self)
    local toggles = AzerothAdminDB and AzerothAdminDB.toggles
    self:SetChecked(toggles and toggles[key])
  end)
  return box
end

-- An input box with a label above it.
function AA:Input(parent, label, x, y, width, onEnter)
  local text = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  text:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  text:SetText(label)
  local box = CreateFrame("EditBox", name(), parent, "InputBoxTemplate")
  box:SetWidth(width)
  box:SetHeight(20)
  box:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 6, y - 14)
  box:SetAutoFocus(false)
  box:SetScript("OnEnterPressed", function(self)
    if onEnter then onEnter(self:GetText()) end
    self:ClearFocus()
  end)
  box:SetScript("OnEscapePressed", box.ClearFocus)
  return box
end

function AA:Label(parent, text, x, y)
  local t = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  t:SetText(text)
  return t
end

-- "TheJadeForest" as "The Jade Forest", "ShrineofSevenStars" as "Shrine of Seven Stars".
function AA:Pretty(id)
  local s = string.gsub(id, "(%l)ofthe(%u)", "%1 of the %2")
  s = string.gsub(s, "(%l)of(%u)", "%1 of %2")
  s = string.gsub(s, "(%l)(%u)", "%1 %2")
  s = string.gsub(s, "^%l", string.upper)
  return s
end
