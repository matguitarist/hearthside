-- AzerothPlus: shared state, saved settings and the movable-frame helper.
--
-- Written for the 1.12 client's Lua 5.0 (table.getn, string.find, no `#` or `...`), so it runs on
-- the original client as well as on benilla.

AzerothPlus = { modules = {}, movers = {} }
local AP = AzerothPlus

local DEFAULTS = {
  locked = true,
  cooldowns = true,
  buffs = true,
  meter = true,
  swing = true,
  resource = true,
  combo = true,
  resourceInCombatOnly = true,
  centerFrames = false,
  minimap = false,
  objectives = false,
  objectivesFolded = false,
  map = false,
  questMarkers = true,
  questLevels = true,
  autoQuest = false,
  tipQuest = true,
  tipHealth = true,
  tipPrice = true,
  sellGreys = true,
  autoRepair = true,
  bagSearch = true,
  botPanel = false,
  untracked = {},
  mapFolded = {},
  positions = {},
}

-- Modules register here; each gets `enable(on)` once settings are loaded and on every toggle.
function AP:Register(key, module)
  self.modules[key] = module
end

function AP:Print(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100AzerothPlus|r: " .. text)
end

function AP:Setting(key)
  return AzerothPlusDB[key]
end

function AP:Set(key, value)
  AzerothPlusDB[key] = value
  local module = self.modules[key]
  if module and module.enable then
    module.enable(value)
  end
  if key == "locked" then
    self:ApplyLock()
  end
end

-- Movable frames: dragged while unlocked, their spot saved per character under `key`.
function AP:Movable(frame, key, label, point, x, y)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function()
    if not AzerothPlusDB.locked or this.alwaysDrag then
      this:StartMoving()
    end
  end)
  frame:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    local p, _, rp, px, py = this:GetPoint()
    AzerothPlusDB.positions[key] = { p, rp, px, py }
  end)

  -- The unlocked look: a tinted box with the frame's name, so an empty frame can be found.
  local box = frame:CreateTexture(nil, "OVERLAY")
  box:SetAllPoints(frame)
  box:SetTexture(0.1, 0.5, 1, 0.25)
  box:Hide()
  local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  text:SetPoint("CENTER", frame, "CENTER", 0, 0)
  text:SetText(label)
  text:Hide()
  frame.moverBox, frame.moverText = box, text

  frame.restore = function()
    frame:ClearAllPoints()
    local saved = AzerothPlusDB.positions[key]
    if saved then
      frame:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
      frame:SetPoint(point, UIParent, point, x, y)
    end
  end
  table.insert(self.movers, frame)
  return frame
end

-- Unlocked: every movable frame shows and takes the mouse; locked: they go back to their modules.
function AP:ApplyLock()
  local unlocked = not AzerothPlusDB.locked
  for i = 1, table.getn(self.movers) do
    local f = self.movers[i]
    if unlocked then
      f.moverBox:Show()
      f.moverText:Show()
      f:EnableMouse(true)
      f:Show()
    else
      f.moverBox:Hide()
      f.moverText:Hide()
      f:EnableMouse(f.alwaysDrag or false)
      if f.refresh then
        f.refresh()
      end
    end
  end
end

function AP:ResetPositions()
  AzerothPlusDB.positions = {}
  for i = 1, table.getn(self.movers) do
    self.movers[i].restore()
  end
end

function AP:FormatTime(seconds)
  if seconds >= 3600 then
    return string.format("%dh", math.ceil(seconds / 3600))
  elseif seconds >= 60 then
    return string.format("%dm", math.ceil(seconds / 60))
  elseif seconds >= 10 then
    return string.format("%d", math.floor(seconds + 0.5))
  end
  return string.format("%.1f", seconds)
end

function AP:FormatNumber(n)
  if n >= 1000000 then
    return string.format("%.1fM", n / 1000000)
  elseif n >= 10000 then
    return string.format("%.1fk", n / 1000)
  end
  return tostring(math.floor(n + 0.5))
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("VARIABLES_LOADED")
loader:SetScript("OnEvent", function()
  if not AzerothPlusDB then
    AzerothPlusDB = {}
  end
  for k, v in pairs(DEFAULTS) do
    if AzerothPlusDB[k] == nil then
      AzerothPlusDB[k] = v
    end
  end
  for i = 1, table.getn(AP.movers) do
    AP.movers[i].restore()
  end
  for key, module in pairs(AP.modules) do
    if module.enable then
      module.enable(AzerothPlusDB[key])
    end
  end
  AP:ApplyLock()
end)

SLASH_AZEROTHPLUS1 = "/ap"
SLASH_AZEROTHPLUS2 = "/azerothplus"
SlashCmdList["AZEROTHPLUS"] = function(msg)
  msg = string.lower(msg or "")
  if msg == "unlock" or msg == "lock" then
    AP:Set("locked", msg == "lock")
    AP:Print(msg == "lock" and "frames locked." or "frames unlocked: drag them, then /ap lock.")
  elseif msg == "reset" then
    AP:ResetPositions()
    AP:Print("frame positions reset.")
  elseif msg == "bots" then
    AP:ToggleBots()
  elseif msg == "meter reset" then
    if AP.modules.meter and AP.modules.meter.reset then
      AP.modules.meter.reset()
    end
  else
    AP:ToggleOptions()
  end
end
