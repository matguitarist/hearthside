-- At a vendor: grey items sold and everything repaired (from the guild bank when allowed and
-- chosen), said in the chat. Shift held while the vendor opens leaves both alone.

local AP = AzerothPlus

local function repair()
  if not CanMerchantRepair() then return end
  local cost = GetRepairAllCost()
  if not cost or cost <= 0 then return end
  if AP:Setting("guildRepair") and CanGuildBankRepair and CanGuildBankRepair()
      and GetGuildBankWithdrawMoney() ~= 0 then
    -- -1 is no limit; otherwise what is left of today's.
    local left = GetGuildBankWithdrawMoney()
    if left == -1 or left >= cost then
      RepairAllItems(true)
      AP:Print("repaired for " .. AP:Money(cost) .. " from the guild bank.")
      return
    end
  end
  if GetMoney() < cost then
    AP:Print("not enough money to repair: " .. AP:Money(cost) .. ".")
    return
  end
  RepairAllItems()
  AP:Print("repaired for " .. AP:Money(cost) .. ".")
end

local function sellGreys()
  local sold, total = 0, 0
  for bag = 0, NUM_BAG_SLOTS do
    for slot = 1, GetContainerNumSlots(bag) do
      local _, count, locked, quality, _, _, link = GetContainerItemInfo(bag, slot)
      if link and quality == 0 and not locked then
        local price = select(11, GetItemInfo(link)) or 0
        if price > 0 then
          total = total + price * (count or 1)
          UseContainerItem(bag, slot)
          sold = sold + 1
        end
      end
    end
  end
  if sold > 0 then
    AP:Print("sold " .. sold .. (sold == 1 and " grey item" or " grey items") .. " for " .. AP:Money(total) .. ".")
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("MERCHANT_SHOW")
events:SetScript("OnEvent", function()
  if IsShiftKeyDown() then return end
  if AP:Setting("autoRepair") then repair() end
  if AP:Setting("sellGreys") then sellGreys() end
end)
