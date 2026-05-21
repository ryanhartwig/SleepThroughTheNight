local UEHelpers = require("UEHelpers")
local config = require("config")

local VERSION = "1.0.1"
local MOD_TAG = "[SleepThroughNight]"
print(string.format("%s v%s loaded\n", MOD_TAG, VERSION))

-- Guard against stale poll loops after hot-reload
local MOD_INSTANCE_ID = tostring(os.clock())

-- ── Host Detection ───────────────────────────────────────────

local function isHost()
    local ok, result = pcall(function()
        local pawn = UEHelpers:GetPlayerController().Pawn
        if pawn and pawn:IsValid() then
            return pawn:HasAuthority()
        end
        return false
    end)
    return ok and result
end

-- ── Time of Day ──────────────────────────────────────────────

local cachedGameState = nil
local cachedTimeOfDay = nil

local function getTimeOfDayComponent()
    -- Use cached references if still valid
    if cachedTimeOfDay and cachedTimeOfDay:IsValid() then
        return cachedTimeOfDay
    end
    if cachedGameState and not cachedGameState:IsValid() then
        cachedGameState = nil
    end
    if not cachedGameState then
        cachedGameState = FindFirstOf("SN2GameState")
    end
    if not cachedGameState or not cachedGameState:IsValid() then return nil end
    local tod = cachedGameState.TimeOfDayComponent
    if not tod or not tod:IsValid() then return nil end
    cachedTimeOfDay = tod
    return tod
end

local function isAllowedPhase()
    local tod = getTimeOfDayComponent()
    if not tod then return false end
    local phase = tod:GetDayPhase()
    return config.AllowedPhaseEnums[phase] == true
end

local function skipToMorning()
    local tod = getTimeOfDayComponent()
    if not tod then
        print(string.format("%s ERROR: Cannot access TimeOfDayComponent\n", MOD_TAG))
        return false
    end
    -- SetTimeOfDay takes a FRACTION (0.0-1.0), not hours
    local fraction = config.WakeUpHour / 24.0
    local ok, err = pcall(function()
        tod:SetTimeOfDay(fraction)
    end)
    if not ok then
        print(string.format("%s SetTimeOfDay ERROR: %s\n", MOD_TAG, tostring(err)))
        return false
    end
    return true
end

local function getDayNumber()
    local tod = getTimeOfDayComponent()
    if not tod then return 0 end
    return tod:GetDayNumber()
end

-- ── Bed Detection ────────────────────────────────────────────

local cachedBeds = {}

local function refreshBedCache()
    local ok, beds = pcall(FindAllOf, "BP_BedSingle_C")
    if ok and beds then
        cachedBeds = beds
    else
        cachedBeds = {}
    end
    print(string.format("%s Bed cache: %d beds\n", MOD_TAG, #cachedBeds))
end

-- Watch for newly built beds (scoped to exact Blueprint class — safe on client join)
NotifyOnNewObject("/Game/Blueprints/BaseBuilding/BP_BedSingle.BP_BedSingle_C", function(newBed)
    table.insert(cachedBeds, newBed)
end)

local function getValidBeds()
    local valid = {}
    for _, bed in ipairs(cachedBeds) do
        if bed:IsValid() then
            table.insert(valid, bed)
        end
    end
    if #valid ~= #cachedBeds then
        cachedBeds = valid
    end
    return valid
end

local function isPlayerInBed(pawn, beds)
    for _, bed in ipairs(beds) do
        if bed:IsValid() then
            local ok, result = pcall(function()
                local attachOwner = bed.UWEPawnAttachmentOwner
                if attachOwner and attachOwner:IsValid() then
                    return attachOwner:IsAttached_BP(pawn)
                end
                return false
            end)
            if ok and result then
                return true
            end
        end
    end
    return false
end

-- ── Player Enumeration ───────────────────────────────────────

local function getPlayerStates()
    -- Reuse cached GameState to avoid FindFirstOf per tick
    if not cachedGameState or not cachedGameState:IsValid() then
        cachedGameState = FindFirstOf("SN2GameState")
    end
    if not cachedGameState or not cachedGameState:IsValid() then return {}, 0 end
    local ok, playerArray = pcall(function() return cachedGameState.PlayerArray end)
    if not ok or not playerArray then return {}, 0 end
    return playerArray, #playerArray
end

local function getPlayerName(playerState)
    local ok, name = pcall(function()
        local raw = playerState:GetPlayerName()
        local str = tostring(raw)
        -- Filter out FString pointer strings
        if str:match("^FString:") then
            return raw:ToString()
        end
        return str
    end)
    if ok and name and not name:match("^FString:") then return name end
    return "Player"
end

local function countSleepingPlayers()
    local playerArray, total = getPlayerStates()
    local sleeping = {}
    local sleepCount = 0

    local beds = getValidBeds()
    if #beds == 0 then return sleeping, 0, total end

    for i = 1, total do
        local ps = playerArray[i]
        if ps:IsValid() then
            local ok, pawn = pcall(function() return ps:GetPawn() end)
            if ok and pawn and pawn:IsValid() then
                if isPlayerInBed(pawn, beds) then
                    local name = getPlayerName(ps)
                    sleeping[name] = true
                    sleepCount = sleepCount + 1
                end
            end
        end
    end

    return sleeping, sleepCount, total
end

local function isSingleplayer()
    local _, total = getPlayerStates()
    return total <= 1
end

local function isThresholdMet(sleepCount, total)
    if total == 0 then return false end
    local percent = (sleepCount / total) * 100
    return percent >= config.RequiredPlayerPercent
end

-- ── Notifications ────────────────────────────────────────────

-- Local-only toast (for messages only this player should see)
local function notifyLocal(message)
    print(string.format("%s %s\n", MOD_TAG, message))
    local ok, err = pcall(function()
        local msgLib = StaticFindObject("/Script/UWEGameplayMessageRuntime.Default__UWEGameplayMessageBPLibrary")
        if msgLib then
            local pawn = UEHelpers:GetPlayerController().Pawn
            if pawn and pawn:IsValid() then
                msgLib:NotifyLocalPlayerSimple(pawn, { TagName = FName("Notification.Info") }, FText(message))
            end
        end
    end)
    if not ok then
        print(string.format("%s Toast error: %s\n", MOD_TAG, tostring(err)))
    end
end

-- Broadcast toast to all connected players (host only — clients skip, they receive the broadcast)
local function notifyAll(message)
    if not isHost() then return end
    print(string.format("%s [ALL] %s\n", MOD_TAG, message))
    local ok, err = pcall(function()
        local msgLib = StaticFindObject("/Script/UWEGameplayMessageRuntime.Default__UWEGameplayMessageBPLibrary")
        if msgLib then
            local pawn = UEHelpers:GetPlayerController().Pawn
            if pawn and pawn:IsValid() then
                msgLib:NotifyAllPlayersString(pawn, message, 0)
            end
        end
    end)
    if not ok then
        print(string.format("%s Broadcast failed: %s\n", MOD_TAG, tostring(err)))
    end
end

-- ── Screen Fade ──────────────────────────────────────────────

local fadeWidget = nil
local fadeImage = nil
local FADE_STEPS = 10
local FADE_STEP_MS = 50  -- 10 steps * 50ms = 500ms total fade duration

local function setFadeOpacity(alpha)
    if not fadeImage then return end
    pcall(function()
        fadeImage:SetColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = alpha })
    end)
end

local function createFadeOverlay()
    if fadeWidget then return end

    local ok, err = pcall(function()
        local pc = UEHelpers:GetPlayerController()
        local wbLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local uwClass = StaticFindObject("/Script/UMG.UserWidget")
        local canvasCls = StaticFindObject("/Script/UMG.CanvasPanel")
        local imgCls = StaticFindObject("/Script/UMG.Image")

        local root = wbLib:Create(pc, uwClass, pc)
        local canvas = StaticConstructObject(canvasCls, root, FName("FadeCanvas"))
        root.WidgetTree.RootWidget = canvas

        local blackImg = StaticConstructObject(imgCls, root, FName("BlackOverlay"))
        -- Start fully transparent
        blackImg:SetColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.0 })

        local slot = canvas:AddChildToCanvas(blackImg)
        slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
        slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })

        root:AddToViewport(9999)
        fadeWidget = root
        fadeImage = blackImg
    end)
    if not ok then
        print(string.format("%s Fade overlay error: %s\n", MOD_TAG, tostring(err)))
    end
end

-- Animate opacity from 0 to 1, then call onComplete
local function fadeIn(onComplete)
    createFadeOverlay()
    for i = 1, FADE_STEPS do
        ExecuteWithDelay(FADE_STEP_MS * i, function()
            ExecuteInGameThread(function()
                local alpha = i / FADE_STEPS
                setFadeOpacity(alpha)
                if i == FADE_STEPS and onComplete then
                    onComplete()
                end
            end)
        end)
    end
end

-- Animate opacity from 1 to 0, then remove widget
local function fadeOut(onComplete)
    if not fadeWidget then
        if onComplete then onComplete() end
        return
    end
    for i = 1, FADE_STEPS do
        ExecuteWithDelay(FADE_STEP_MS * i, function()
            ExecuteInGameThread(function()
                local alpha = 1.0 - (i / FADE_STEPS)
                setFadeOpacity(alpha)
                if i == FADE_STEPS then
                    pcall(function()
                        fadeWidget:RemoveFromViewport()
                    end)
                    fadeWidget = nil
                    fadeImage = nil
                    if onComplete then onComplete() end
                end
            end)
        end)
    end
end

-- ── HUD Widget ───────────────────────────────────────────────

local hudWidget = nil
local hudTextBlock = nil

local function showHudWidget(sleepCount, total)
    if hudWidget then
        -- Already showing, just update
        if hudTextBlock then
            pcall(function()
                hudTextBlock:SetText(FText(string.format("%d/%d players sleeping...", sleepCount, total)))
            end)
        end
        return
    end

    local ok, err = pcall(function()
        local pc = UEHelpers:GetPlayerController()
        local wbLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local uwClass = StaticFindObject("/Script/UMG.UserWidget")
        local canvasCls = StaticFindObject("/Script/UMG.CanvasPanel")
        local textCls = StaticFindObject("/Script/UMG.TextBlock")

        local root = wbLib:Create(pc, uwClass, pc)
        local canvas = StaticConstructObject(canvasCls, root, FName("HudCanvas"))
        root.WidgetTree.RootWidget = canvas

        local text = StaticConstructObject(textCls, root, FName("SleepCount"))
        text:SetText(FText(string.format("%d/%d players sleeping...", sleepCount, total)))

        local slot = canvas:AddChildToCanvas(text)
        slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.1 }, Maximum = { X = 1.0, Y = 0.1 } })
        slot:SetAlignment({ X = 1.0, Y = 0.5 })
        slot:SetAutoSize(true)

        root:AddToViewport(100)
        hudWidget = root
        hudTextBlock = text
    end)
    if not ok then
        print(string.format("%s HUD widget error: %s\n", MOD_TAG, tostring(err)))
    end
end

local function updateHudWidget(sleepCount, total)
    if not hudTextBlock then return end
    pcall(function()
        hudTextBlock:SetText(FText(string.format("%d/%d players sleeping...", sleepCount, total)))
    end)
end

local function hideHudWidget()
    if not hudWidget then return end
    pcall(function()
        hudWidget:RemoveFromViewport()
    end)
    hudWidget = nil
    hudTextBlock = nil
end

-- ── State Machine ────────────────────────────────────────────

local STATE_IDLE = "IDLE"
local STATE_WAITING = "WAITING"
local STATE_SKIPPING = "SKIPPING"
local currentState = STATE_IDLE

-- Track previous sleeping set to detect enter/leave events
local prevSleeping = {}
-- Track players notified about wrong-phase sleep to avoid spam
local blockedNotifiedPlayers = {}
-- Players who must leave bed before they can trigger another sleep
local postSkipImmunity = {}
-- Unique ID for each skip attempt — stale timers check this to self-cancel
local skipAttemptId = 0

local function transitionTo(newState)
    print(string.format("%s State: %s -> %s\n", MOD_TAG, currentState, newState))
    currentState = newState
end

local function onPlayerStartedSleeping(playerName, sleepCount, total)
    notifyAll(string.format("%s is sleeping (%d/%d)", playerName, sleepCount, total))
end


local function doTimeSkip()
    transitionTo(STATE_SKIPPING)
    skipAttemptId = skipAttemptId + 1
    local myAttemptId = skipAttemptId

    -- NOTE: Every modded instance calls SetTimeOfDay. On non-host clients,
    -- this may silently fail (server-owned component) — the host's call is
    -- the one that actually changes time. Clients see the change via replication.

    local dayNum = getDayNumber()

    -- Wait for the bed entry animation to finish, then revalidate before fading
    ExecuteWithDelay(2000, function()
        ExecuteInGameThread(function()
            if myAttemptId ~= skipAttemptId then return end  -- stale timer
            if currentState ~= STATE_SKIPPING then return end

            -- Recheck: are enough players still in bed?
            local _, sleepCount, total = countSleepingPlayers()
            if not isThresholdMet(sleepCount, total) and not isSingleplayer() then
                print(string.format("%s Sleep cancelled — not enough players in bed\n", MOD_TAG))
                transitionTo(STATE_IDLE)
                return
            end
            -- Singleplayer: check player is still in bed
            if isSingleplayer() and sleepCount == 0 then
                print(string.format("%s Sleep cancelled — player left bed\n", MOD_TAG))
                transitionTo(STATE_IDLE)
                return
            end

            fadeIn(function()
                if currentState ~= STATE_SKIPPING then return end

                skipToMorning()

                -- Brief hold on black screen, then fade out
                ExecuteWithDelay(300, function()
                    ExecuteInGameThread(function()
                        fadeOut(function()
                            notifyAll(string.format("Good morning! Day %d", dayNum + 1))
                            -- Mark anyone still in bed as immune — they must
                            -- leave and re-enter to trigger another sleep
                            local stillSleeping, _, _ = countSleepingPlayers()
                            prevSleeping = stillSleeping
                            blockedNotifiedPlayers = {}
                            postSkipImmunity = {}
                            for name, _ in pairs(stillSleeping) do
                                blockedNotifiedPlayers[name] = true
                                postSkipImmunity[name] = true
                            end
                            transitionTo(STATE_IDLE)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

local function tick()
    if currentState == STATE_SKIPPING then
        -- Check if someone left bed during the animation delay — cancel if threshold no longer met
        local _, sleepCount, total = countSleepingPlayers()
        local shouldCancel = false
        if isSingleplayer() then
            shouldCancel = (sleepCount == 0)
        else
            shouldCancel = not isThresholdMet(sleepCount, total)
        end
        if shouldCancel then
            print(string.format("%s Sleep cancelled — player left bed during countdown\n", MOD_TAG))
            hideFadeOverlay()
            transitionTo(STATE_IDLE)
        end
        return
    end

    local sleeping, sleepCount, total = countSleepingPlayers()

    -- Clear post-skip immunity for players who left bed
    for name, _ in pairs(postSkipImmunity) do
        if not sleeping[name] then
            postSkipImmunity[name] = nil
        end
    end

    -- Subtract immune players from the effective sleep count
    local effectiveSleepCount = 0
    for name, _ in pairs(sleeping) do
        if not postSkipImmunity[name] then
            effectiveSleepCount = effectiveSleepCount + 1
        end
    end

    -- Clear blocked tracking for players who left bed
    for name, _ in pairs(blockedNotifiedPlayers) do
        if not sleeping[name] then
            blockedNotifiedPlayers[name] = nil
        end
    end

    if currentState == STATE_IDLE then
        if effectiveSleepCount > 0 then
            if not isAllowedPhase() then
                -- Only notify once per player per wrong-phase bed entry
                for name, _ in pairs(sleeping) do
                    if not blockedNotifiedPlayers[name] then
                        blockedNotifiedPlayers[name] = true
                        notifyLocal("You can only sleep during dusk or night")
                    end
                end
                return
            end

            -- Clear blocked tracking since we're in an allowed phase now
            blockedNotifiedPlayers = {}

            if isSingleplayer() then
                doTimeSkip()
            else
                for name, _ in pairs(sleeping) do
                    if not postSkipImmunity[name] then
                        onPlayerStartedSleeping(name, effectiveSleepCount, total)
                    end
                end
                transitionTo(STATE_WAITING)
                showHudWidget(effectiveSleepCount, total)
            end
        end

    elseif currentState == STATE_WAITING then
        -- Notify for newly sleeping players
        for name, _ in pairs(sleeping) do
            if not prevSleeping[name] and not postSkipImmunity[name] then
                onPlayerStartedSleeping(name, effectiveSleepCount, total)
            end
        end

        if sleepCount == 0 then
            hideHudWidget()
            transitionTo(STATE_IDLE)
        elseif isThresholdMet(sleepCount, total) then
            hideHudWidget()
            doTimeSkip()
        else
            updateHudWidget(effectiveSleepCount, total)
        end
    end

    prevSleeping = sleeping
end

-- ── Poll Loop ────────────────────────────────────────────────

local POLL_INTERVAL_MS = 1000
local pollTimerActive = false

local function startPollLoop()
    if pollTimerActive then return end
    pollTimerActive = true
    refreshBedCache()
    print(string.format("%s Poll loop started\n", MOD_TAG))

    local function pollOnce()
        -- Guard against stale instance after hot-reload
        if MOD_INSTANCE_ID ~= tostring(os.clock()) and not pollTimerActive then return end
        if not pollTimerActive then return end

        ExecuteInGameThread(function()
            local ok, err = pcall(tick)
            if not ok then
                print(string.format("%s Tick error: %s\n", MOD_TAG, tostring(err)))
            end
        end)
        ExecuteWithDelay(POLL_INTERVAL_MS, pollOnce)
    end

    pollOnce()
end

-- Start polling when player spawns into world
RegisterHook("/Script/Subnautica2.SN2PlayerController:OnPossessedPawnChangedFunction", function()
    ExecuteWithDelay(5000, function()
        ExecuteInGameThread(function()
            startPollLoop()
        end)
    end)
end)

-- Hot-reload fallback: check if we're in a world (not main menu) using GameState
-- Avoids accessing PlayerController.Pawn which can crash at the main menu
ExecuteWithDelay(3000, function()
    ExecuteInGameThread(function()
        local gs = FindFirstOf("SN2GameState")
        if gs and gs:IsValid() then
            startPollLoop()
        end
    end)
end)
