local PUBLIC_BUILD = true
local DEV_OVERRIDE_KEY = 'ExperimentalDevolopments'

local function useDevOverride()
	if PUBLIC_BUILD then return false end
	local value = rawget(shared, 'PistonwareDevBypassKey')
	return type(value) == 'string' and value == DEV_OVERRIDE_KEY
end

local function installPistonwareBuffer(developerMode)
