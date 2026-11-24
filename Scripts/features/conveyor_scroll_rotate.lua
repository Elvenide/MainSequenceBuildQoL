-- Eqol Feature: Scroll-to-Rotate Station Machines
-- Allows rotating any machine/conveyor builder on a station with the mouse scroll wheel in addition to R.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "ConveyorScrollRotate",
    DisplayName = "Scroll-to-Rotate Station Machines",
    Description = "Rotate station machines and conveyor belts using the mouse scroll wheel.",
}

local PollActive = false
local CachedStationCheck = { time = -999, inStation = false }
local ConveyorPullingActive = false
local LastConveyorBuilderAddr = nil
local LastBeltSpawnClock = -999.0
local LastLocalConfirmClock = -999.0
local BeltSpawnHookRegistered = false

local function IsLocalPC(pc)
    if not Core.IsValidObj(pc) then return false end
    local ok, isLoc = pcall(function() return pc:IsLocalPlayerController() end)
    if ok and type(isLoc) == "boolean" then
        return isLoc
    end
    local localPC = Core.GetLocalPlayerController()
    return Core.IsValidObj(localPC) and localPC:GetAddress() == pc:GetAddress()
end

local function IsConveyorBuilder(builder)
    if not Core.IsValidObj(builder) then return false end
    local okCls, cn = pcall(function() return builder:GetClass():GetFName():ToString() end)
    return okCls and type(cn) == "string" and cn:find("Conveyor", 1, true) ~= nil
end

local function IsInStationCached(pc)
    local now = os.clock()
    if (now - CachedStationCheck.time) < 0.5 then
        return CachedStationCheck.inStation
    end
    CachedStationCheck.time = now
    local inSt = StationData.IsPlayerInStation(pc)
    CachedStationCheck.inStation = (inSt == true)
    return CachedStationCheck.inStation
end

local function GetActiveStationBuilder(pc)
    if not Core.IsValidObj(pc) then return nil end

    -- Check verified pc.Builder first to avoid probing non-existent properties every frame (learning.md §8)
    local okB, b = pcall(function() return pc.Builder end)
    if okB and Core.IsValidObj(b) then
        local hasAddRot = false
        pcall(function() hasAddRot = (b.AddRotation ~= nil) end)
        if hasAddRot then
            return b
        end
    end

    return nil
end

local function StartScrollRotatePoll()
    if PollActive then return end
    PollActive = true

    local kScrollUp = { KeyName = FName("MouseScrollUp") }
    local kScrollDown = { KeyName = FName("MouseScrollDown") }
    local kWheelAxis = { KeyName = FName("MouseWheelAxis") }
    local kRMB = { KeyName = FName("RightMouseButton") }

    local function Tick()
        if not Core.IsFeatureEnabled("ConveyorScrollRotate") then
            PollActive = false
            ConveyorPullingActive = false
            return
        end
        local pc = Core.GetLocalPlayerController()
        local activeBuilding = false
        if Core.IsValidObj(pc) and not pc.bShowMouseCursor then
            local builder = GetActiveStationBuilder(pc)
            if Core.IsValidObj(builder) and IsInStationCached(pc) then
                activeBuilding = true
                local bAddr = builder:GetAddress()
                if bAddr ~= LastConveyorBuilderAddr then
                    LastConveyorBuilderAddr = bAddr
                    ConveyorPullingActive = false
                end
                if ConveyorPullingActive then
                    local okRmb, rmbPressed = pcall(function() return pc:WasInputKeyJustPressed(kRMB) end)
                    if okRmb and rmbPressed then
                        ConveyorPullingActive = false
                    end
                end

                local delta = 0
                pcall(function()
                    if pc:WasInputKeyJustPressed(kScrollUp) then
                        delta = 1
                    elseif pc:WasInputKeyJustPressed(kScrollDown) then
                        delta = -1
                    else
                        local axis = pc:GetInputAnalogKeyState(kWheelAxis)
                        if type(axis) == "number" then
                            if axis > 0.01 then
                                delta = 1
                            elseif axis < -0.01 then
                                delta = -1
                            end
                        end
                    end
                end)
                if delta ~= 0 then
                    local pullingBelt = ConveyorPullingActive and IsConveyorBuilder(builder)
                    local steps = 1
                    if pullingBelt then
                        -- While pulling out a conveyor belt, routing cycles through 3 modes:
                        -- Scroll Down = +1 mod 3, Scroll Up = +2 mod 3 (-1, opposite direction).
                        steps = (delta == 1) and 2 or 1
                    elseif delta == 1 then
                        -- Scroll Up rotates -90 deg (+3 mod 4)
                        steps = 3
                    else
                        -- Scroll Down rotates +90 deg (+1 mod 4)
                        steps = 1
                    end
                    pcall(function()
                        for _ = 1, steps do
                            builder:AddRotation(1)
                        end
                    end)
                end
            else
                LastConveyorBuilderAddr = nil
                ConveyorPullingActive = false
            end
        else
            LastConveyorBuilderAddr = nil
            ConveyorPullingActive = false
        end
        -- Run every frame while actively building so single-frame scroll events are never missed;
        -- stop completely when not in build mode (restarted on EnterBuildingMode / EnterMachineBuildMode = 0ms idle cost!).
        if activeBuilding then
            ExecuteInGameThreadAfterFrames(1, Tick)
        else
            PollActive = false
        end
    end

    ExecuteInGameThreadAfterFrames(1, Tick)
end

local function ResetState()
    PollActive = false
    ConveyorPullingActive = false
    LastConveyorBuilderAddr = nil
    LastBeltSpawnClock = -999.0
    LastLocalConfirmClock = -999.0
    CachedStationCheck = { time = -999, inStation = false }
end

local function GetStationMachineCount(pc)
    if not Core.IsValidObj(pc) then return -1 end
    local _, _, station = StationData.IsPlayerInStation(pc)
    if not Core.IsValidObj(station) then return -1 end
    local okN, n = pcall(function()
        local arr = station.Machines
        if not arr then return -1 end
        return (arr.GetArrayNum and arr:GetArrayNum()) or #arr
    end)
    return (okN and type(n) == "number") and n or -1
end

function Feature.RegisterHooks()
    local function onEnterBuild(Context)
        if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
        local pc = Context and Context:get() or nil
        if not IsLocalPC(pc) then return end
        ExecuteInGameThreadAfterFrames(1, function()
            if Core.IsFeatureEnabled("ConveyorScrollRotate") then
                StartScrollRotatePoll()
            end
        end)
    end
    Core.TryRegisterHook(
        "ScrollRotate_EnterBuildMode",
        "/Script/MainSequence.DMSPlayerController:EnterBuildingMode",
        onEnterBuild
    )
    Core.TryRegisterHook(
        "ScrollRotate_EnterMachineBuildMode",
        "/Script/MainSequence.DMSPlayerController:EnterMachineBuildMode",
        onEnterBuild
    )
    Core.TryRegisterHook(
        "ScrollRotate_ConfirmBuild",
        "/Script/MainSequence.DMSPlayerController:ConfirmBuild",
        function(Context)
            if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
            local pc = Context and Context:get() or nil
            if not IsLocalPC(pc) then return end
            local prevMachCount = GetStationMachineCount(pc)
            ExecuteInGameThreadWithDelay(80, function()
                if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
                local curPC = Core.GetLocalPlayerController()
                if not Core.IsValidObj(curPC) then return end
                local newMachCount = GetStationMachineCount(curPC)
                -- O(1) machine count delta: if real belt(s) spawned, the pulled run committed -> non-pulling mode;
                -- otherwise (0 new belts spawned while holding ConveyorBuilder), pulling mode just began!
                if prevMachCount >= 0 and newMachCount > prevMachCount then
                    ConveyorPullingActive = false
                    StartScrollRotatePoll()
                    return
                end
                local builder = GetActiveStationBuilder(curPC)
                if IsConveyorBuilder(builder) then
                    LastConveyorBuilderAddr = builder:GetAddress()
                    ConveyorPullingActive = true
                    StartScrollRotatePoll()
                else
                    ConveyorPullingActive = false
                end
            end)
        end
    )
    Core.TryRegisterHook(
        "ScrollRotate_ExitBuildMode",
        "/Script/MainSequence.DMSPlayerController:ExitBuildingMode",
        function(Context)
            if not Core.IsFeatureEnabled("ConveyorScrollRotate") then return end
            local pc = Context and Context:get() or nil
            if not IsLocalPC(pc) then return end
            ConveyorPullingActive = false
            LastConveyorBuilderAddr = nil
        end
    )
end

function Feature.OnToggle(enabled)
    if enabled then
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) and Core.IsValidObj(GetActiveStationBuilder(pc)) then
            StartScrollRotatePoll()
        end
    else
        ConveyorPullingActive = false
        PollActive = false
    end
end

function Feature.Init()
    -- Event-driven via EnterBuildingMode / EnterMachineBuildMode (zero idle polling!)
end

function Feature.OnMapLoad()
    ResetState()
end

function Feature.OnClientRestart()
    ResetState()
end

return Feature
