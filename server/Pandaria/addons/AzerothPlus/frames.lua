-- Centered unit frames: the stock player and target frames, smaller, either side of the screen's
-- center under your character, as newer clients lay them out. Each hangs from an invisible anchor
-- that "Move Frames" drags, so the stock frames keep their own mouse handling (click to target,
-- right-click menus). They are secure frames: in combat they cannot move, so a change made then
-- waits for combat to end.

local AP = AzerothPlus

local SCALE = 0.85

local function anchor(name, label, x)
  local a = CreateFrame("Frame", name, UIParent)
  a:SetWidth(232 * SCALE)
  a:SetHeight(100 * SCALE)
  AP:Movable(a, "frames" .. label, label .. " frame", "CENTER", x, -170)
  -- Off, there is nothing to place; ApplyLock shows every mover while unlocked.
  a.refresh = function()
    if not AzerothPlusDB.centerFrames then a:Hide() end
  end
  return a
end

local playerAnchor = anchor("AzerothPlusPlayerAnchor", "Player", -170)
local targetAnchor = anchor("AzerothPlusTargetAnchor", "Target", 170)

-- The stock spots, read before the first move so turning the option off puts them back.
local stock = {}

local function remember(frame)
  if stock[frame] then return end
  local p, rel, rp, x, y = frame:GetPoint()
  stock[frame] = { p, rel or UIParent, rp, x, y }
end

local function place(frame, a)
  remember(frame)
  frame:SetScale(SCALE)
  frame:ClearAllPoints()
  -- Offsets are in the frame's own scale; center on center needs none.
  frame:SetPoint("CENTER", a, "CENTER", 0, 0)
end

local function unplace(frame)
  local s = stock[frame]
  if not s then return end
  frame:SetScale(1)
  frame:ClearAllPoints()
  frame:SetPoint(s[1], s[2], s[3], s[4], s[5])
end

local waiting = CreateFrame("Frame")

local function apply(on)
  if InCombatLockdown() then
    waiting:RegisterEvent("PLAYER_REGEN_ENABLED")
    return
  end
  if on then
    playerAnchor:Show()
    targetAnchor:Show()
    place(PlayerFrame, playerAnchor)
    place(TargetFrame, targetAnchor)
  else
    unplace(PlayerFrame)
    unplace(TargetFrame)
    if AzerothPlusDB.locked then
      playerAnchor:Hide()
      targetAnchor:Hide()
    end
  end
end

waiting:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_REGEN_ENABLED")
  apply(AzerothPlusDB.centerFrames)
end)

AP:Register("centerFrames", { enable = apply })
