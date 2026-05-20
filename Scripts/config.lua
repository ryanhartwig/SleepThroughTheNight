local config = {}

-- Default values
config.AllowedPhases = { "Dusk", "Night" }
config.RequiredPlayerPercent = 100
config.WakeUpHour = 6

-- Phase name to EDayPhase enum mapping
-- EDayPhase: None=0, Night=1, Dawn=2, Day=3, Dusk=4
config.PhaseNameToEnum = {
    Night = 1,
    Dawn = 2,
    Day = 3,
    Dusk = 4,
}

-- Parse a comma-separated string into a table
local function parseList(str)
    local result = {}
    if not str or str == "" then return result end
    for item in str:gmatch("[^,]+") do
        local trimmed = item:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(result, trimmed)
        end
    end
    return result
end

-- Parse config.txt from the mod's root folder
local function loadConfig()
    local modDir = debug.getinfo(1, "S").source:match("@(.*/)")
    local configPath = modDir .. "../config.txt"

    local file = io.open(configPath, "r")
    if not file then
        print("[SleepThroughNight] config.txt not found, using defaults\n")
        return
    end

    for line in file:lines() do
        if line ~= "" and not line:match("^#") then
            local key, value = line:match("^([%w_]+)%s*=%s*(.*)$")
            if key and value then
                value = value:match("^%s*(.-)%s*$")
                if key == "allowed_phases" then
                    config.AllowedPhases = parseList(value)
                elseif key == "required_player_percent" then
                    config.RequiredPlayerPercent = math.max(1, math.min(100, tonumber(value) or 100))
                elseif key == "wake_up_hour" then
                    config.WakeUpHour = math.max(0, math.min(23, tonumber(value) or 6))
                end
            end
        end
    end

    file:close()

    -- Build allowed phase enum set for fast lookup
    config.AllowedPhaseEnums = {}
    for _, phaseName in ipairs(config.AllowedPhases) do
        local enumVal = config.PhaseNameToEnum[phaseName]
        if enumVal then
            config.AllowedPhaseEnums[enumVal] = true
        else
            print(string.format("[SleepThroughNight] WARNING: Unknown phase '%s' in config\n", phaseName))
        end
    end

    print(string.format("[SleepThroughNight] Config: phases=%s, threshold=%d%%, wakeHour=%d\n",
        table.concat(config.AllowedPhases, ","),
        config.RequiredPlayerPercent,
        config.WakeUpHour))
end

loadConfig()

return config
