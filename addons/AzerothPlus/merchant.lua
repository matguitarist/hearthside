-- At a vendor: grey items sold and everything repaired, said in the chat. Shift held while the
-- vendor opens leaves both alone.

local AP = AzerothPlus

local GREY = "|cff9d9d9d"

-- The item id in a link, `|Hitem:2589:0:0:0|h`.
function AP:ItemId(link)
  if not link then return nil end
  local _, _, id = string.find(link, "item:(%d+)")
  return id and tonumber(id)
end

-- What a vendor pays for one, in copper, or nil when it buys none (`infodb.lua`).
function AP:VendorPrice(id)
  return id and AzerothPlusInfoDB and AzerothPlusInfoDB.prices[id]
end

-- "1g 20s 5c", coloured as the coins are.
function AP:Money(copper)
  local g, s, c = math.floor(copper / 10000), math.floor(math.mod(copper, 10000) / 100), math.mod(copper, 100)
  local text = ""
  if g > 0 then text = text .. g .. "|cffffd700g|r " end
  if s > 0 or g > 0 then text = text .. s .. "|cffc7c7cfs|r " end
  return text .. c .. "|cffeda55fc|r"
end

local function repair()
  if not CanMerchantRepair() then return end
  local cost = GetRepairAllCost()
  if not cost or cost <= 0 then return end
  if GetMoney() < cost then
    AP:Print("not enough money to repair: " .. AP:Money(cost) .. ".")
    return
  end
  RepairAllItems()
  AP:Print("repaired for " .. AP:Money(cost) .. ".")
end

local function sellGreys()
  local sold, total = 0, 0
  for bag = 0, 4 do
    for slot = 1, GetContainerNumSlots(bag) do
      local link = GetContainerItemLink(bag, slot)
      if link and string.find(link, GREY, 1, true) then
        local _, count, locked = GetContainerItemInfo(bag, slot)
        if not locked then
          total = total + (AP:VendorPrice(AP:ItemId(link)) or 0) * (count or 1)
          UseContainerItem(bag, slot)
          sold = sold + 1
        end
      end
    end
  end
  if sold > 0 then
    AP:Print("sold " .. sold .. (sold == 1 and " grey item" or " grey items") ..
      (total > 0 and " for " .. AP:Money(total) or "") .. ".")
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("MERCHANT_SHOW")
events:SetScript("OnEvent", function()
  if IsShiftKeyDown() then return end
  if AP:Setting("autoRepair") then repair() end
  if AP:Setting("sellGreys") then sellGreys() end
end)
