local UEHelpers = require("UEHelpers")
local config = require("config")

local VERSION = "0.1.0"
local MOD_TAG = "[SleepThroughNight]"
print(string.format("%s v%s loaded\n", MOD_TAG, VERSION))

-- Guard against stale poll loops after hot-reload
local MOD_INSTANCE_ID = tostring(os.clock())

-- ── Time of Day ──────────────────────────────────────────────

local function getTimeOfDayComponent()
    local gs = FindFirstOf("SN2GameState")
    if not gs or not gs:IsValid() then return nil end
    local tod = gs.TimeOfDayComponent
    if not tod or not tod:IsValid() then return nil end
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

local function findAllBeds()
    local ok, beds = pcall(FindAllOf, "BP_BedSingle_C")
    if ok and beds then
        return beds
    end
    return {}
end

local function isPlayerInBed(pawn)
    local beds = findAllBeds()
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
    local gs = FindFirstOf("SN2GameState")
    if not gs or not gs:IsValid() then return {}, 0 end
    local ok, playerArray = pcall(function() return gs.PlayerArray end)
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

    for i = 1, total do
        local ps = playerArray[i]
        if ps:IsValid() then
            local ok, pawn = pcall(function() return ps:GetPawn() end)
            if ok and pawn and pawn:IsValid() then
                if isPlayerInBed(pawn) then
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

local function notify(message)
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
        -- Top center of screen
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.1 }, Maximum = { X = 0.5, Y = 0.1 } })
        slot:SetAlignment({ X = 0.5, Y = 0.5 })
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

local function transitionTo(newState)
    print(string.format("%s State: %s -> %s\n", MOD_TAG, currentState, newState))
    currentState = newState
end

local function onPlayerStartedSleeping(playerName, sleepCount, total)
    notify(string.format("%s is sleeping (%d/%d)", playerName, sleepCount, total))
end


local function doTimeSkip()
    transitionTo(STATE_SKIPPING)

    -- NOTE: Every modded instance calls SetTimeOfDay. On non-host clients,
    -- this may silently fail (server-owned component) — the host's call is
    -- the one that actually changes time. Clients see the change via replication.

    local dayNum = getDayNumber()

    -- Wait for the bed entry animation to finish, then fade
    ExecuteWithDelay(2000, function()
        ExecuteInGameThread(function()
            if currentState ~= STATE_SKIPPING then return end

            fadeIn(function()
                if currentState ~= STATE_SKIPPING then return end

                skipToMorning()

                -- Brief hold on black screen, then fade out
                ExecuteWithDelay(300, function()
                    ExecuteInGameThread(function()
                        fadeOut(function()
                            notify(string.format("Good morning! Day %d", dayNum + 1))
                            -- Pre-mark anyone still in bed so they don't get
                            -- a "can't sleep" toast upon waking to morning
                            local stillSleeping, _, _ = countSleepingPlayers()
                            prevSleeping = stillSleeping
                            blockedNotifiedPlayers = {}
                            for name, _ in pairs(stillSleeping) do
                                blockedNotifiedPlayers[name] = true
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
        return  -- don't poll during time skip
    end

    local sleeping, sleepCount, total = countSleepingPlayers()
    prevSleeping = sleeping

    if currentState == STATE_IDLE then
        if sleepCount > 0 then
            if not isAllowedPhase() then
                -- Only notify once per player per wrong-phase bed entry
                for name, _ in pairs(sleeping) do
                    if not blockedNotifiedPlayers[name] then
                        blockedNotifiedPlayers[name] = true
                        notify("You can only sleep during dusk or night")
                    end
                end
                -- Clear tracked players who left bed
                for name, _ in pairs(blockedNotifiedPlayers) do
                    if not sleeping[name] then
                        blockedNotifiedPlayers[name] = nil
                    end
                end
                return
            end

            -- Clear blocked tracking since we're in an allowed phase now
            blockedNotifiedPlayers = {}

            if isSingleplayer() then
                doTimeSkip()
            else
                -- Notify for each newly sleeping player
                for name, _ in pairs(sleeping) do
                    onPlayerStartedSleeping(name, sleepCount, total)
                end
                transitionTo(STATE_WAITING)
                showHudWidget(sleepCount, total)
            end
        end

    elseif currentState == STATE_WAITING then
        if sleepCount == 0 then
            hideHudWidget()
            transitionTo(STATE_IDLE)
        elseif isThresholdMet(sleepCount, total) then
            hideHudWidget()
            doTimeSkip()
        else
            updateHudWidget(sleepCount, total)
        end
    end
end

-- ── Poll Loop ────────────────────────────────────────────────

local POLL_INTERVAL_MS = 1000
local pollTimerActive = false

local function startPollLoop()
    if pollTimerActive then return end
    pollTimerActive = true
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
    ExecuteWithDelay(2000, function()
        ExecuteInGameThread(function()
            startPollLoop()
        end)
    end)
end)

-- Also start immediately if already in-game (hot-reload case)
ExecuteWithDelay(1000, function()
    ExecuteInGameThread(function()
        local pc = UEHelpers:GetPlayerController()
        if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
            startPollLoop()
        end
    end)
end)
