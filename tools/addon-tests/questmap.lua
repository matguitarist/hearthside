-- AzerothPlus's quest markers against a stubbed 1.12 client: a human in Northshire with three
-- quests, one finished. Run from the repository root with Lua 5.1 or later:
--   lua tools/addon-tests/questmap.lua addons/AzerothPlus
table.getn = table.getn or function(t) return #t end
string.gfind = string.gfind or string.gmatch
math.atan2 = math.atan2 or math.atan
local A = arg[1]
local function frame()
  local f = { shown = false, w = 10, h = 10, scripts = {}, points = {} }
  function f:SetWidth(w) self.w = w end function f:SetHeight(h) self.h = h end
  function f:GetWidth() return self.w end function f:GetHeight() return self.h end
  function f:Show() self.shown = true end function f:Hide() self.shown = false end
  function f:IsShown() return self.shown end
  function f:SetScript(k, v) self.scripts[k] = v end function f:GetScript(k) return self.scripts[k] end
  function f:RegisterEvent() end function f:UnregisterAllEvents() end function f:EnableMouse() end
  function f:SetFrameLevel() end function f:GetFrameLevel() return 1 end
  function f:ClearAllPoints() self.points = {} end
  function f:SetPoint(...) self.points = { ... } end
  function f:CreateTexture() local t = frame(); function t:SetTexture(p) self.path = p end
    function t:SetVertexColor() end function t:SetAllPoints() end
    function t:SetTexCoord(...) self.tc = { ... } end return t end
  return f
end
made = {}
CreateFrame = function(kind, name, parent) local f = frame(); f.parent = parent; table.insert(made, f); return f end
WorldMapFrame, WorldMapButton, Minimap = frame(), frame(), frame()
WorldMapButton:SetWidth(1002) WorldMapButton:SetHeight(668)
Minimap:SetWidth(140) Minimap:SetHeight(140)
local zoom = 0
function Minimap:GetZoom() return zoom end
function Minimap:SetZoom(z) zoom = z; cv.minimapZoom = tostring(z) end
cv = { minimapZoom = "0", minimapInsideZoom = "3" }
GetCVar = function(k) return cv[k] end
local mapName = "Elwynn"
GetMapInfo = function() return mapName end
SetMapToCurrentZone = function() mapName = "Elwynn" end
-- Northshire Abbey's door: world (-8914, -137) in Elwynn's bounds.
local b = { 1535, -1935, -7940, -10254 }
local px, py = -8914, -137
GetPlayerMapPosition = function()
  if mapName ~= "Elwynn" then return 0, 0 end
  return (b[1] - py) / (b[1] - b[2]), (b[3] - px) / (b[3] - b[4])
end
UnitRace = function() return "Human", "Human" end
local log = {
  { "Elwynn Forest", 0, nil, 1 },
  { "Kobold Camp Cleanup", 2, nil, nil, nil, nil, { { "Kobold Vermin slain: 3/10", "monster", nil } } },
  { "Wolves Across the Border", 2, nil, nil, nil, 1, {} },
  { "A Threat Within", 1, nil, nil, nil, nil, {} },
}
GetNumQuestLogEntries = function() return #log end
GetQuestLogTitle = function(i) local q = log[i]; return q[1], q[2], q[3], q[4], nil, q[6] end
GetNumQuestLeaderBoards = function(i) return #(log[i][7] or {}) end
GetQuestLogLeaderBoard = function(j, i) local l = log[i][7][j]; return l[1], l[2], l[3] end
AzerothPlus = { Register = function(self, k, m) self[k] = m end, IsTracked = function() return true end }
AzerothPlusDB = { questMarkers = true }
dofile(A .. "/questdb.lua")
dofile(A .. "/questmap.lua")
AzerothPlus.questMarkers.enable(true)
local driver
for _, f in ipairs(made) do if f.scripts.OnUpdate and not f.parent then driver = f end end
this = driver; arg1 = 1; driver.scripts.OnUpdate()
local function shown(parent)
  local out = {}
  for _, f in ipairs(made) do
    if f.parent == parent and f.shown then table.insert(out, f) end
  end
  return out
end
local function count(pins, pred)
  local n = 0
  for _, p in ipairs(pins) do if pred(p) then n = n + 1 end end
  return n
end
local function check(ok, what) if not ok then error("FAIL: " .. what, 2) end print("ok - " .. what) end

local mini = shown(Minimap)
check(count(mini, function(p) return p.target.title == "Kobold Camp Cleanup" end) > 0,
  "kobold spots on the minimap at the widest zoom")
check(count(mini, function(p) return p.target.turnIn and p.target.title == "Kobold Camp Cleanup" end) == 0,
  "an unfinished quest shows its objectives, not its turn-in")
check(count(mini, function(p) return p.target.turnIn and p.target.title == "Wolves Across the Border" end) > 0,
  "a finished quest points to its turn-in")
check(count(mini, function(p) return p.target.title == "A Threat Within" and p.tex.path:find("ActiveQuestIcon") end) > 0,
  "a quest with nothing to collect points to its end")
for _, p in ipairs(mini) do
  local x, y = p.points[4], p.points[5]
  check(x * x + y * y <= 70 * 70, "minimap pin inside the disc")
  break
end

WorldMapFrame:Show(); WorldMapFrame.scripts.OnShow()
local map = shown(WorldMapButton)
check(#map > 10, "spots on the Elwynn map")
check(count(map, function(p)
  local x, y = p.points[4], -p.points[5]
  return x < 0 or x > 1002 or y < 0 or y > 668
end) == 0, "every map pin on the map")

zoom = 5; cv.minimapZoom = "5"; arg1 = 1; driver.scripts.OnUpdate()
mini = shown(Minimap)
check(count(mini, function(p) return p.tex.path:find("MinimapArrow") end) > 0,
  "zoomed in, an objective out of sight gets a rim arrow")

AzerothPlus.questMarkers.enable(false)
check(#shown(Minimap) == 0 and #shown(WorldMapButton) == 0, "turned off, every pin goes")
