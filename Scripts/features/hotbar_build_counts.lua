-- Eqol Feature: Hotbar Craftable Count Labels
-- Displays a numeric label on each bottom-hotbar buildable slot showing how many of
-- that machine can be built with the resources currently in the player's inventory.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "HotbarBuildCounts",
    DisplayName = "Hotbar Buildable Counts",
    Description = "Shows how many of each buildable on your bottom hotbar you can craft from inventory.",
}

local PATHS = {
    WBPTextClass     = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    OverlayClass     = "/Script/UMG.Overlay",
    CanvasPanelClass = "/Script/UMG.CanvasPanel",
    BorderClass      = "/Script/UMG.Border",
    PanelWidgetClass = "/Script/UMG.PanelWidget",
    ContentWidgetCls = "/Script/UMG.ContentWidget",
    ItemClass        = "/Script/MainSequence.Item",
}

local COLOR_OK = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local COLOR_ZERO = { R = 0.96, G = 0.36, B = 0.32, A = 1.0 }
local BG_BADGE = { R = 0.02, G = 0.03, B = 0.05, A = 0.78 }

local TrackedHuds = {}          -- hudAddr -> { Hud, HotbarWidget, Slots = { ... } }
local AttachedSlots = {}        -- slotAddr -> { SlotWidget, Badge, Label }
local CostStacksByBuildable = {} -- buildableAddr -> { Buildable = UBuildable, Stacks = table|false }
local CachedItemCls = nil
local PollActive = false

local function GetItemKey(item)
    if not Core.IsValidObj(item) then return nil end
    local ok, n = pcall(function() return item:GetFName():ToString() end)
    if ok and type(n) == "string" and n ~= "" then
        return n
    end
    return tostring(item:GetAddress())
end

local function KeyToString(k)
    if k == nil then return nil end
    if type(k) == "string" then return k end
    if type(k) == "number" then return tostring(k) end
    local unwrapped = k
    local okG, g = pcall(function() return k.get and k:get() or k end)
    if okG and g ~= nil then unwrapped = g end
    if type(unwrapped) == "string" then return unwrapped end
    if type(unwrapped) == "number" then return tostring(unwrapped) end
    local okS, s = pcall(function()
        if unwrapped.ToString then return unwrapped:ToString() end
        return tostring(unwrapped)
    end)
    if okS and type(s) == "string" and s ~= "" then return s end
    return nil
end

local function FormatCount(n)
    if n >= 10000 then
        return string.format("%.0fk", n / 1000.0)
    elseif n >= 1000 then
        return string.format("%.1fk", n / 1000.0)
    end
    return tostring(math.floor(n))
end

local function GetPlayerInventory(pc)
    if not Core.IsValidObj(pc) then return nil end
    local playerObj = pc.PlayerObject
    if Core.IsValidObj(playerObj) then
        if playerObj.GetInventory then
            local ok, inv = pcall(function() return playerObj:GetInventory() end)
            if ok and Core.IsValidObj(inv) then return inv end
        end
        for _, prop in ipairs({ "Inventory", "PlayerInventory", "CharacterInventory" }) do
            local ok, inv = pcall(function() return playerObj[prop] end)
            if ok and Core.IsValidObj(inv) then return inv end
        end
    end
    if pc.GetInventory then
        local ok, inv = pcall(function() return pc:GetInventory() end)
        if ok and Core.IsValidObj(inv) then return inv end
    end
    return nil
end

local function BuildPlayerInventoryCounts(inv)
    local counts = {}
    if not Core.IsValidObj(inv) then return counts, false end
    local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
    if not okSlots or not slots then
        return counts, false
    end
    StationData.ForEachArray(slots, function(_, elem)
        local st = Core.UnwrapStruct(elem)
        if st then
            local okI, item = pcall(function() return st.Item end)
            local okA, amt = pcall(function() return st.Amount end)
            if okI and Core.IsValidObj(item) and okA then
                local n = tonumber(amt) or 0
                if n > 0 then
                    local k = GetItemKey(item)
                    if k then
                        counts[k] = (counts[k] or 0) + n
                    end
                end
            end
        end
    end)
    return counts, true
end

local function TryExtractSingleStack(val, stacks)
    if not val then return false end
    local st = Core.UnwrapStruct(val)
    if not st then return false end
    local okI, item = pcall(function() return st.Item end)
    local okA, amt = pcall(function() return st.Amount end)
    if okI and Core.IsValidObj(item) and okA then
        local n = tonumber(amt) or 0
        if n > 0 then
            stacks[#stacks + 1] = { Item = item, Amount = n }
            return true
        end
    end
    return false
end

local function GetBuildableCostStacks(buildable)
    if not Core.IsValidObj(buildable) then return nil end

    local bAddr = buildable:GetAddress()
    local cached = CostStacksByBuildable[bAddr]
    if cached and Core.IsValidObj(cached.Buildable) then
        return cached.Stacks or nil
    end

    local stacks = {}
    if not Core.IsValidObj(CachedItemCls) then
        CachedItemCls = Core.FindOrLoadClass(PATHS.ItemClass)
    end
    local itemCls = CachedItemCls

    local function cacheAndReturn(res)
        CostStacksByBuildable[bAddr] = { Buildable = buildable, Stacks = res or false }
        return res
    end

    local function collectFromArr(arr)
        if not arr then return end
        StationData.ForEachArray(arr, function(rawKey, elem)
            if TryExtractSingleStack(elem, stacks) then
                return
            end
            -- TMap<UItem*, int32>
            local kObj = Core.UnwrapArrayElem(rawKey)
            if Core.IsValidObj(kObj) and (not Core.IsValidObj(itemCls) or kObj:IsA(itemCls)) then
                local vVal = elem
                local okG, g = pcall(function() return elem and elem.get and elem:get() or elem end)
                if okG and g ~= nil then vVal = g end
                local amt = tonumber(vVal) or 0
                if amt > 0 then
                    stacks[#stacks + 1] = { Item = kObj, Amount = amt }
                end
            end
        end)
    end

    local function collectFromCostObj(val)
        if not val then return end
        if TryExtractSingleStack(val, stacks) then return end
        collectFromArr(val)
        if #stacks > 0 then return end
        local st = Core.UnwrapStruct(val)
        if st then
            for _, subProp in ipairs({ "Items", "ItemStacks", "RequiredItems", "ItemsRequired", "Costs", "Ingredients" }) do
                local okS, subArr = pcall(function() return st[subProp] end)
                if okS and subArr then
                    collectFromArr(subArr)
                    if #stacks > 0 then return end
                end
            end
        end
    end

    -- 1. Verified UBuildable properties: ItemCost, then bUseItemCost (pre-crafted item), then ItemDetails.Recipe.Inputs
    local okIC, itemCost = pcall(function() return buildable.ItemCost end)
    if okIC and itemCost then
        collectFromCostObj(itemCost)
        if #stacks > 0 then return cacheAndReturn(stacks) end
    end

    local okID, itemDetails = pcall(function() return buildable.ItemDetails end)
    if okID and Core.IsValidObj(itemDetails) then
        -- Check bUseItemCost BEFORE Recipe.Inputs so pre-crafted buildables count the item itself, not raw recipe ingredients
        local okUse, useItem = pcall(function() return buildable.bUseItemCost end)
        if okUse and useItem == true then
            stacks[#stacks + 1] = { Item = itemDetails, Amount = 1 }
            return cacheAndReturn(stacks)
        end
        local okRec, rec = pcall(function() return itemDetails.Recipe end)
        if okRec and Core.IsValidObj(rec) then
            local okIn, inArr = pcall(function() return rec.Inputs end)
            if okIn and inArr then
                collectFromArr(inArr)
                if #stacks > 0 then return cacheAndReturn(stacks) end
            end
        end
    end

    -- 2. Fallback UFunctions / properties
    for _, fnName in ipairs({ "GetBuildCost", "CostAsBuildingCost" }) do
        local okFn, fn = pcall(function() return buildable[fnName] end)
        if okFn and fn then
            local ok, res = pcall(function() return fn(buildable) end)
            if ok and res then
                collectFromCostObj(res)
                if #stacks > 0 then return cacheAndReturn(stacks) end
            end
        end
    end

    for _, prop in ipairs({ "BuildCost", "ItemsRequired", "Cost", "BuildingCost" }) do
        local ok, val = pcall(function() return buildable[prop] end)
        if ok and val then
            collectFromCostObj(val)
            if #stacks > 0 then return cacheAndReturn(stacks) end
        end
    end

    return cacheAndReturn((#stacks > 0) and stacks or nil)
end

local function ComputeCraftableCount(buildable, inv, invCounts, hasCountsMap)
    local stacks = GetBuildableCostStacks(buildable)
    if not stacks or #stacks == 0 then return nil end

    local neededByKey = {}
    local itemByKey = {}
    for _, st in ipairs(stacks) do
        local k = GetItemKey(st.Item)
        if k then
            neededByKey[k] = (neededByKey[k] or 0) + st.Amount
            itemByKey[k] = st.Item
        end
    end

    local minCount = math.huge
    for k, reqAmt in pairs(neededByKey) do
        if reqAmt > 0 then
            local have = 0
            if hasCountsMap then
                have = invCounts[k] or 0
            elseif Core.IsValidObj(inv) and inv.GetItemAmount then
                local okA, a = pcall(function() return inv:GetItemAmount(itemByKey[k]) end)
                if okA and type(a) == "number" then have = a end
            end
            local c = math.floor(have / reqAmt)
            if c < minCount then minCount = c end
            if minCount == 0 then break end
        end
    end

    if minCount == math.huge then return nil end
    return minCount
end

local function GetHotbarBuildablesData(pc, hud, hotbarWidget)
    local result = { byName = {}, byIndex = {}, count = 0 }
    local sources = {}
    if Core.IsValidObj(hotbarWidget) then sources[#sources + 1] = hotbarWidget end
    if Core.IsValidObj(hud) then sources[#sources + 1] = hud end
    if Core.IsValidObj(pc) then
        if Core.IsValidObj(pc.PlayerObject) then sources[#sources + 1] = pc.PlayerObject end
        sources[#sources + 1] = pc
    end

    for _, src in ipairs(sources) do
        for _, prop in ipairs({ "HotbarBuildables", "Hotbar", "HotbarItems", "Buildables" }) do
            local ok, arr = pcall(function() return src[prop] end)
            if ok and arr then
                local foundCount = 0
                StationData.ForEachArray(arr, function(rawKey, elem)
                    local u = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(u) then
                        foundCount = foundCount + 1
                        local kUnwrapped = rawKey
                        local okG, g = pcall(function() return rawKey and rawKey.get and rawKey:get() or rawKey end)
                        if okG and g ~= nil then kUnwrapped = g end

                        if type(kUnwrapped) == "number" then
                            result.byIndex[kUnwrapped] = u
                            result.byName[tostring(kUnwrapped)] = u
                        else
                            local ks = KeyToString(kUnwrapped)
                            if ks and ks ~= "" then
                                result.byName[ks] = u
                                result.byName[ks:lower()] = u
                                local num = tonumber(ks:match("(%d+)$"))
                                if num then
                                    local idx1 = (num % 10) + 1
                                    result.byIndex[idx1] = u
                                end
                            end
                        end
                    end
                end)
                if foundCount > 0 then
                    result.count = foundCount
                    return result
                end
            end
        end
    end
    return result
end

local function ExtractSlotBuildable(slotWidget, hotbarData)
    if not Core.IsValidObj(slotWidget) or not hotbarData then return nil end
    local okM, mapVal = pcall(function() return slotWidget["Mapping Name"] end)
    if okM and mapVal ~= nil then
        local ms = KeyToString(mapVal)
        if ms and ms ~= "" then
            local hit = hotbarData.byName[ms] or hotbarData.byName[ms:lower()]
            if Core.IsValidObj(hit) then return hit end
            local num = tonumber(ms:match("(%d+)$"))
            if num then
                -- HotbarBuildables is indexed by key digit 0..9 in C++ -> 1..10 in Lua:
                -- key 0 (ability0 / ability10) = Lua index 1, key 1 (ability1) = Lua index 2, ..., key 9 (ability9) = Lua index 10.
                local luaIdx = (num % 10) + 1
                if Core.IsValidObj(hotbarData.byIndex[luaIdx]) then
                    return hotbarData.byIndex[luaIdx]
                end
            end
        end
    end
    return nil
end

local function IsPlayerInCreativeMode(pc)
    if not Core.IsValidObj(pc) then return false end
    local creativeProps = { "bCreative", "bCreativeMode", "bInCreative", "bBuildCreative" }

    local function checkObj(obj)
        if not Core.IsValidObj(obj) then return false end
        for _, p in ipairs(creativeProps) do
            local ok, v = pcall(function() return obj[p] end)
            if ok and v == true then return true end
        end
        return false
    end

    if checkObj(pc.PlayerObject) or checkObj(pc) or checkObj(pc.Builder) then
        return true
    end

    local worldSub = Core.GetWorldSubsystem(pc, Core.PATHS.WorldSubsystemClass)
    if Core.IsValidObj(worldSub) then
        local okW, dmsWorld = pcall(function() return worldSub:GetDMSWorld() end)
        if okW and checkObj(dmsWorld) then
            return true
        end
    end

    return false
end

local function CollectReflectedObjectProps(uobj)
    local out = {}
    if not Core.IsValidObj(uobj) then return out end
    local seen = {}
    pcall(function()
        local cls = uobj:GetClass()
        while Core.IsValidObj(cls) do
            local cName = cls:GetFName():ToString()
            if cName == "UserWidget" or cName == "Widget" or cName == "Object" then break end
            cls:ForEachProperty(function(prop)
                local pName = prop:GetFName():ToString()
                if not seen[pName] then
                    seen[pName] = true
                    local okV, val = pcall(function() return uobj[pName] end)
                    if okV and val ~= nil then
                        out[#out + 1] = { name = pName, val = val }
                    end
                end
            end)
            cls = cls:GetSuperStruct()
        end
    end)
    return out
end

local function AttachBadgeToSlot(slotWidget, pc)
    if not Core.IsValidObj(slotWidget) then return nil, nil end

    -- Guard against duplicate badge attachment when OnMapLoad / OnClientRestart fires twice
    local slotAddr = slotWidget:GetAddress()
    local existing = AttachedSlots[slotAddr]
    if existing and Core.IsValidObj(existing.SlotWidget) and Core.IsValidObj(existing.Badge) and Core.IsValidObj(existing.Label) then
        return existing.Badge, existing.Label
    end

    local overlayCls = Core.FindOrLoadClass(PATHS.OverlayClass)
    local canvasCls = Core.FindOrLoadClass(PATHS.CanvasPanelClass)
    local contentCls = Core.FindOrLoadClass(PATHS.ContentWidgetCls)

    local outerParent = nil
    pcall(function() outerParent = slotWidget:GetParent() end)
    local outerParentAddr = Core.IsValidObj(outerParent) and outerParent:GetAddress() or nil

    local img = nil
    pcall(function() img = slotWidget.Image_60 end)

    local targetOverlay = nil
    local targetCanvas = nil
    local imgDirectParent = nil

    if Core.IsValidObj(img) and img.GetParent then
        local cur = img
        for step = 1, 5 do
            local okP, p = pcall(function() return cur:GetParent() end)
            if not okP or not Core.IsValidObj(p) then break end
            if outerParentAddr and p:GetAddress() == outerParentAddr then break end
            if step == 1 then imgDirectParent = p end
            if not targetOverlay and Core.IsValidObj(overlayCls) and p:IsA(overlayCls) then
                targetOverlay = p
            elseif not targetCanvas and Core.IsValidObj(canvasCls) and p:IsA(canvasCls) then
                targetCanvas = p
            end
            cur = p
        end
    end

    local outer = Core.GetWidgetOuter(slotWidget)
    local badge = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local label = Core.CreateUserWidget(PATHS.WBPTextClass, slotWidget, pc)
    if not (Core.IsValidObj(badge) and Core.IsValidObj(label)) then
        return nil, nil
    end

    pcall(function()
        badge:SetBrushColor(BG_BADGE)
        badge:SetPadding({ Left = 4.0, Top = 1.0, Right = 4.0, Bottom = 1.0 })
        badge:SetVisibility(1) -- Collapsed until a bound buildable count is computed
        label:SetSize(11)
        label:SetText(Core.MakeText(""))
        label:SetVisibility(3)
        if Core.IsValidObj(label.TextBlock) then
            label.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLOR_OK, ColorUseRule = 0 })
            label.TextBlock:SetVisibility(3)
        end
        badge:AddChild(label)
    end)

    if Core.IsValidObj(targetOverlay) then
        local oSlot = targetOverlay:AddChildToOverlay(badge)
        if Core.IsValidObj(oSlot) then
            pcall(function()
                oSlot:SetHorizontalAlignment(3) -- Right
                oSlot:SetVerticalAlignment(3)   -- Bottom
                oSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 3.0, Bottom = 2.0 })
            end)
        end
        AttachedSlots[slotAddr] = { SlotWidget = slotWidget, Badge = badge, Label = label }
        return badge, label
    end

    if Core.IsValidObj(targetCanvas) then
        local cSlot = targetCanvas:AddChildToCanvas(badge)
        if Core.IsValidObj(cSlot) then
            pcall(function()
                cSlot:SetAnchors({ Minimum = { X = 1.0, Y = 1.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                cSlot:SetAlignment({ X = 1.0, Y = 1.0 })
                cSlot:SetAutoSize(true)
                cSlot:SetPosition({ X = -3.0, Y = -2.0 })
            end)
        end
        AttachedSlots[slotAddr] = { SlotWidget = slotWidget, Badge = badge, Label = label }
        return badge, label
    end

    if Core.IsValidObj(img) and Core.IsValidObj(imgDirectParent)
        and Core.IsValidObj(contentCls) and imgDirectParent:IsA(contentCls)
    then
        local wrapOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
        if Core.IsValidObj(wrapOverlay) then
            pcall(function()
                img:RemoveFromParent()
                local iSlot = wrapOverlay:AddChildToOverlay(img)
                if Core.IsValidObj(iSlot) then
                    iSlot:SetHorizontalAlignment(0) -- Fill
                    iSlot:SetVerticalAlignment(0)   -- Fill
                end
                local bSlot = wrapOverlay:AddChildToOverlay(badge)
                if Core.IsValidObj(bSlot) then
                    bSlot:SetHorizontalAlignment(3) -- Right
                    bSlot:SetVerticalAlignment(3)   -- Bottom
                    bSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 3.0, Bottom = 2.0 })
                end
                imgDirectParent:SetContent(wrapOverlay)
            end)
            AttachedSlots[slotAddr] = { SlotWidget = slotWidget, Badge = badge, Label = label }
            return badge, label
        end
    end

    return nil, nil
end

local function DiscoverHotbarSlots(hud)
    if not Core.IsValidObj(hud) then return nil, {} end

    local hotbarWidget = nil
    for _, prop in ipairs({
        "WBP_Hotbar", "Hotbar", "BuildHotbar", "WBP_BuildHotbar",
        "HotbarWidget", "QuickBar", "WBP_QuickBar",
    }) do
        local ok, w = pcall(function() return hud[prop] end)
        if ok and Core.IsValidObj(w) then
            hotbarWidget = w
            break
        end
    end

    if not Core.IsValidObj(hotbarWidget) then
        for _, entry in ipairs(CollectReflectedObjectProps(hud)) do
            local w = entry.val
            if Core.IsValidObj(w) then
                local okN, cn = pcall(function() return w:GetClass():GetFName():ToString():lower() end)
                if okN and cn and cn:find("hotbar", 1, true) then
                    hotbarWidget = w
                    break
                end
            end
        end
    end

    local slots = {}
    local seen = {}
    local function addSlot(w)
        if not Core.IsValidObj(w) then return end
        local a = w:GetAddress()
        if seen[a] then return end
        seen[a] = true
        slots[#slots + 1] = w
    end

    local userWidgetCls = Core.FindOrLoadClass("/Script/UMG.UserWidget")
    local panelCls = Core.FindOrLoadClass(PATHS.PanelWidgetClass)

    if Core.IsValidObj(hotbarWidget) then
        local props = CollectReflectedObjectProps(hotbarWidget)
        local bestPanelChildren = nil
        local directUserWidgets = {}

        for _, entry in ipairs(props) do
            local val = entry.val
            if Core.IsValidObj(val) then
                if Core.IsValidObj(panelCls) and val:IsA(panelCls) and val.GetAllChildren then
                    local okCh, ch = pcall(function() return val:GetAllChildren() end)
                    if okCh and ch then
                        local uwList = {}
                        StationData.ForEachArray(ch, function(_, ce)
                            local cw = Core.UnwrapArrayElem(ce)
                            if Core.IsValidObj(cw) and Core.IsValidObj(userWidgetCls) and cw:IsA(userWidgetCls) then
                                uwList[#uwList + 1] = cw
                            end
                        end)
                        if #uwList >= 4 and #uwList <= 16 and (not bestPanelChildren or #uwList > #bestPanelChildren) then
                            bestPanelChildren = uwList
                        end
                    end
                elseif Core.IsValidObj(userWidgetCls) and val:IsA(userWidgetCls) then
                    directUserWidgets[#directUserWidgets + 1] = val
                end
            end
        end

        if bestPanelChildren then
            for _, cw in ipairs(bestPanelChildren) do addSlot(cw) end
        elseif #directUserWidgets >= 4 then
            for _, cw in ipairs(directUserWidgets) do addSlot(cw) end
        end
    end

    return hotbarWidget, slots
end

local function RefreshHotbarCounts()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false end

    local isCreative = IsPlayerInCreativeMode(pc)
    local inv, invCounts, hasCountsMap = nil, nil, false
    if not isCreative then
        inv = GetPlayerInventory(pc)
        invCounts, hasCountsMap = BuildPlayerInventoryCounts(inv)
    end
    local anyValid = false

    for addr, entry in pairs(TrackedHuds) do
        if not Core.IsValidObj(entry.Hud) then
            TrackedHuds[addr] = nil
        else
            anyValid = true
            local hotbarData = GetHotbarBuildablesData(pc, entry.Hud, entry.HotbarWidget)
            for _, s in ipairs(entry.Slots) do
                if Core.IsValidObj(s.SlotWidget) and Core.IsValidObj(s.Badge) and Core.IsValidObj(s.Label) then
                    local bld = ExtractSlotBuildable(s.SlotWidget, hotbarData)
                    local txt = nil
                    local isZero = false
                    if Core.IsValidObj(bld) then
                        if isCreative then
                            txt = "∞"
                            isZero = false
                        else
                            local count = ComputeCraftableCount(bld, inv, invCounts, hasCountsMap)
                            if count ~= nil then
                                txt = FormatCount(count)
                                isZero = (count == 0)
                            end
                        end
                    end
                    if txt ~= nil then
                        if s.LastVis ~= 3 then
                            s.LastVis = 3
                            pcall(function()
                                s.Badge:SetVisibility(3)
                                s.Label:SetVisibility(3)
                                s.Label:SetSize(11)
                            end)
                        end
                        if s.LastText ~= txt then
                            s.LastText = txt
                            pcall(function() s.Label:SetText(Core.MakeText(txt)) end)
                        end
                        if s.LastZero ~= isZero then
                            s.LastZero = isZero
                            local col = isZero and COLOR_ZERO or COLOR_OK
                            pcall(function()
                                if Core.IsValidObj(s.Label.TextBlock) then
                                    s.Label.TextBlock:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
                                    s.Label.TextBlock:SetVisibility(3)
                                end
                            end)
                        end
                    else
                        if s.LastVis ~= 1 then
                            s.LastVis = 1
                            s.LastText = nil
                            pcall(function() s.Badge:SetVisibility(1) end)
                        end
                    end
                end
            end
        end
    end

    return anyValid
end

local function HideAllHotbarBadges()
    for _, entry in pairs(TrackedHuds) do
        if entry and entry.Slots then
            for _, s in ipairs(entry.Slots) do
                if Core.IsValidObj(s.Badge) then
                    s.LastVis = 1
                    s.LastText = nil
                    pcall(function() s.Badge:SetVisibility(1) end)
                end
            end
        end
    end
end

local function StartPoll()
    if PollActive or not Core.IsFeatureEnabled("HotbarBuildCounts") then return end
    PollActive = true
    local function Tick()
        if not Core.IsFeatureEnabled("HotbarBuildCounts") then
            HideAllHotbarBadges()
            PollActive = false
            return
        end
        local ok, anyValid = pcall(RefreshHotbarCounts)
        if not ok then
            Core.Log("[HotbarCounts] RefreshHotbarCounts error (retrying): " .. tostring(anyValid))
            ExecuteInGameThreadWithDelay(2000, Tick)
            return
        end
        if anyValid then
            ExecuteInGameThreadWithDelay(500, Tick)
        else
            PollActive = false
        end
    end
    ExecuteInGameThreadWithDelay(250, Tick)
end

local function EnsureHudHotbarTracked(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    if TrackedHuds[addr] and Core.IsValidObj(TrackedHuds[addr].Hud) then
        return
    end

    local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local hotbarWidget, rawSlots = DiscoverHotbarSlots(hud)
    if #rawSlots == 0 then return end

    local trackedSlots = {}
    for _, slotW in ipairs(rawSlots) do
        local badge, label = AttachBadgeToSlot(slotW, pc)
        if Core.IsValidObj(badge) and Core.IsValidObj(label) then
            trackedSlots[#trackedSlots + 1] = {
                SlotWidget = slotW,
                Badge = badge,
                Label = label,
                LastText = nil,
                LastZero = nil,
                LastVis = 1,
            }
        end
    end

    if #trackedSlots > 0 then
        TrackedHuds[addr] = {
            Hud = hud,
            HotbarWidget = hotbarWidget,
            Slots = trackedSlots,
        }
        Core.Log(string.format("[HotbarCounts] Attached %d/%d hotbar count labels", #trackedSlots, #rawSlots))
        StartPoll()
    end
end

local function TryAttachExistingHuds()
    if not Core.IsFeatureEnabled("HotbarBuildCounts") then return end
    local okHud, hud = pcall(FindFirstOf, "WBP_CharacterHUD_C")
    if okHud and Core.IsValidObj(hud) then
        EnsureHudHotbarTracked(hud)
    end
end

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(hud)
        if not Core.IsFeatureEnabled("HotbarBuildCounts") then return end
        ExecuteInGameThreadWithDelay(250, function()
            if Core.IsFeatureEnabled("HotbarBuildCounts") and Core.IsValidObj(hud) then
                EnsureHudHotbarTracked(hud)
            end
        end)
    end,
}

function Feature.OnClientRestart()
    if not Core.IsFeatureEnabled("HotbarBuildCounts") then return end
    ExecuteInGameThreadWithDelay(600, TryAttachExistingHuds)
end

function Feature.PruneCaches()
    for addr, entry in pairs(TrackedHuds) do
        if not entry or not Core.IsValidObj(entry.Hud) then
            TrackedHuds[addr] = nil
        end
    end
    for slotAddr, entry in pairs(AttachedSlots) do
        if not entry or not Core.IsValidObj(entry.SlotWidget) or not Core.IsValidObj(entry.Badge) or not Core.IsValidObj(entry.Label) then
            AttachedSlots[slotAddr] = nil
        end
    end
    for bAddr, entry in pairs(CostStacksByBuildable) do
        if not entry or not Core.IsValidObj(entry.Buildable) then
            CostStacksByBuildable[bAddr] = nil
        end
    end
end

function Feature.OnToggle(enabled)
    if enabled then
        TryAttachExistingHuds()
        StartPoll()
    else
        HideAllHotbarBadges()
    end
end

function Feature.OnMapLoad()
    -- Prune only invalid HUDs instead of wiping TrackedHuds unconditionally,
    -- because InitGameState + LoadMap can both fire OnMapLoad for the same live HUD.
    Feature.PruneCaches()
    CachedItemCls = nil
end

return Feature
