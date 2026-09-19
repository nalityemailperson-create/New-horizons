local pistonwareBuffer
pcall(function()
	local env = type(getgenv) == 'function' and getgenv() or nil
	local namespace = type(env) == 'table' and env.pistonware or nil
	pistonwareBuffer = type(namespace) == 'table' and namespace.buffer or nil
end)

local function bufferCall(method, event, message, details)
	local callback = type(pistonwareBuffer) == 'table' and pistonwareBuffer[method] or nil
	if type(callback) == 'function' then return callback(event, message, details) end
	if shared.PistonwareDeveloper == true then
		if method == 'warn' or method == 'error' then
			warn('[pistonware] '..tostring(message))
		else
			print('[pistonware] '..tostring(message))
		end
	end
end

local function bufferLog(event, message, details)
	return bufferCall('log', event, message, details)
end

local function bufferPrint(event, message, details)
	return bufferCall('print', event, message, details)
end

local function bufferWarn(event, message, details)
	return bufferCall('warn', event, message, details)
end

local function bufferError(event, message, details)
	return bufferCall('error', event, message, details)
end

local release = type(shared.PistonwareRelease) == 'table' and shared.PistonwareRelease or {
	channel = 'main',
	branch = 'main',
	sourceRef = 'main',
	cacheReady = true
}

local function errorTrace(err)
	local traceback
	pcall(function()
		if debug and type(debug.traceback) == 'function' then
			traceback = debug.traceback(tostring(err), 2)
		end
	end)
	return traceback or tostring(err)
end

local function reportRuntimeError(stage, err, trace)
	local traceback = trace or errorTrace(err)
	bufferError('runtime.'..tostring(stage), err, {stage = stage, traceback = traceback})
	local reporter = shared.PistonwareTelemetry
	if type(reporter) == 'table' and type(reporter.report) == 'function' then
		pcall(function()
			reporter:report('runtime_error', tostring(err), {
				stage = stage,
				fatal = false,
					traceback = traceback
			})
		end)
	end
end

local function releaseRef()
	return release.sourceRef or release.branch or 'main'
end

local function rewriteReleaseUrl(url)
	local value = tostring(url or '')
	local ref = releaseRef()
	local adapter = shared.PistonwareRewriteUrl
	if type(adapter) == 'function' and adapter ~= rewriteReleaseUrl then
		local ok, rewritten = pcall(adapter, value)
		if ok and type(rewritten) == 'string' then return rewritten end
	end
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/refs/heads/main/', function()
		return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..ref..'/'
	end)
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/main/', function()
		return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..ref..'/'
	end)
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/main/', function()
		return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..ref..'/'
	end)
	value = value:gsub('https://gitlab%.com/pistonware/pistonware/%-/raw/main/', function()
		return 'https://gitlab.com/pistonware/pistonware/-/raw/'..(release.branch or 'main')..'/'
	end)
	value = value:gsub('([?&]sha=)main', '%1'..ref)
	value = value:gsub('([?&]ref=)main', '%1'..ref)
	return value
end

shared.PistonwareRewriteUrl = rewriteReleaseUrl

local function projectRawUrl(path, ref)
	path = tostring(path or ''):gsub('^/', '')
	return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..(ref or releaseRef())..'/'..path
end

local function protectedRawUrl(ref)
	return 'https://gitlab.com/pistonware/pistonware/-/raw/'..(ref or release.branch or 'main')..'/bedwars.lua'
end

shared.PistonwareRawUrl = projectRawUrl
shared.PistonwareProtectedRawUrl = protectedRawUrl
shared.PistonwareChannel = release.channel or 'main'

local function cacheAllowed()
	return release.cacheReady ~= false
end

--[[ pcall'd: after a teleport shared.vape can still point at the previous server's instance,
whose GUI and connections no longer exist. An error walking that corpse would abort main.lua
on line one and leave the queued re-injection doing nothing at all. ]]
if shared.vape then pcall(function() shared.vape:Uninject() end) end

local vape
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vape then
		vape:CreateNotification('Pistonware', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
--[[ Chunks hasContent already compiled, handed to the next loadstring of the same source under
the same name instead of being compiled a second time. hasContent compiles every cached .lua
to prove it is intact, and the caller then compiled the identical text again to run it -- for
the GUI, universal.lua and the game file that is ~1.4MB of source compiled twice on the game
thread, every inject. Consumed on use, so each entry lives from the check to the run. ]]
local validatedChunks = {}
local function takeValidatedChunk(source, name)
	for path, entry in validatedChunks do
		if entry.body == source and entry.name == name then
			validatedChunks[path] = nil
			return entry.chunk
		end
	end
	return nil
end

local function runChunk(source, name)
	local chunk = takeValidatedChunk(source, name) or loadstring(source, name)
	return chunk and chunk()
end
local queue_on_teleport = queue_on_teleport or queueonteleport
	or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
local hasQueueOnTeleport = queue_on_teleport ~= nil
queue_on_teleport = queue_on_teleport or function() end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(obj)
	return obj
end

local function pistonwareHttpGet(url, nocache, attempt)
	url = rewriteReleaseUrl(url)
	local adapter = shared.PistonwareDevHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
	return game:HttpGet(url, nocache)
end

local function pistonwareProtectedHttpGet(url, nocache, attempt)
	url = rewriteReleaseUrl(url)
	local adapter = shared.PistonwareDevProtectedHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
	return game:HttpGet(url, nocache)
end

local playersService = cloneref(game:GetService('Players'))

--[[ Phones and tablets. Kept for the teleport path and notifications; it no longer paces saves. ]]
local isTouchDevice = false
pcall(function()
	isTouchDevice = cloneref(game:GetService('UserInputService')).TouchEnabled and true or false
end)

--[[ Telemetry the developer build prints and the public build does not.

	Module counts and load timings are buffered for every build and mirrored into the executor
	console only in developer mode. Public failures stay in the same buffer and are available
	through getgenv().pistonware.buffer.dump().

Gated at runtime rather than at build time because main.lua is one file serving both builds.
PUBLIC_BUILD nulls shared.PistonwareDeveloper and locks it behind a metatable, so this is off
for everyone except the developer build by construction -- and the queued teleport script
carries the flag across, so it stays on for a developer through a match join. ]]
local function debugWarn(...)
	local values = {...}
	for index, value in ipairs(values) do values[index] = tostring(value) end
	bufferPrint('runtime.debug', table.concat(values, ' '))
end

--[[
	Breadcrumbs, off unless asked for:

		getgenv().PistonwareTrace = true

	The GUI keeps the same log (vape:Trace writes into this very table) but cannot record
	anything before it is downloaded and run, and "the client died and there is no log" is
	exactly the case where that window matters. Root of the filesystem, because reinstall.lua
	deletes the pistonware folder and would take the evidence with it.
]]
local traceOn = false
pcall(function()
	traceOn = (((getgenv and getgenv().PistonwareTrace) or shared.PistonwareTrace) and true) or false
end)
shared.PistonwareTraceLines = {}
local traceLines = shared.PistonwareTraceLines
local function stage(text)
	bufferLog('runtime.stage', text)
	if not traceOn then return end
	table.insert(traceLines, text)
	if #traceLines > 200 then table.remove(traceLines, 1) end
	pcall(writefile, 'pistonware_trace.txt', table.concat(traceLines, '\n'))
end
local function heapKB()
	local kb = 0
	pcall(function() kb = gcinfo and gcinfo() or collectgarbage('count') end)
	return kb
end

--[[
	A heartbeat, so the log says WHEN it died and not only where.

	Without it, a crash during a long silent stretch is indistinguishable from a crash at the
	last thing that logged. Rewrites one line in place rather than appending, so a long session
	costs one small write every two seconds and the log stays readable.
]]
if traceOn then
	local started = os.clock()
	local index
	local trend = {}
	task.spawn(function()
		while true do
			task.wait(2)
			local mem = heapKB()
			table.insert(trend, ('%d'):format(mem))
			if #trend > 15 then table.remove(trend, 1) end
			local text = ('alive %.1fs mem=%dKB trend=%s'):format(
				os.clock() - started, mem, table.concat(trend, ','))
			if index then
				traceLines[index] = text
				pcall(writefile, 'pistonware_trace.txt', table.concat(traceLines, '\n'))
			else
				stage(text)
				index = #traceLines
			end
		end
	end)
end

stage('main.lua running')

--[[ `isfile` alone is insufficient. A zero-byte file reads back as PRESENT through every executor's
real isfile, and only the fallback above treats empty as absent -- so on executors that ship
one (most of them), an interrupted write leaves a truncated file that nothing ever repairs.

That is not hypothetical: cancelling, crashing or teleporting mid-download leaves a
half-written file, and from then on every cache-first route skips it forever. For a .lua file
that means a chunk that never loads. Every route that could have fixed it asked isfile and was
told the file was fine, which is why the only known remedy was reinstalling the whole script.

Treating empty as missing makes it repair itself on the next run instead. ]]
local function hasContent(path, chunkName)
	if not isfile(path) then return false end
	local ok, body = pcall(readfile, path)
	if not ok or type(body) ~= 'string' or body == '' then return false end
	if path:match('%.lua$') then
		--[[ Compiled under the name the file will run as, so the chunk can be kept for that run
		(see validatedChunks) with its error traces unchanged. ]]
		local name = chunkName or path
		local compileOk, chunk = pcall(loadstring, body, name)
		local valid = compileOk and type(chunk) == 'function'
		if valid and chunkName then
			validatedChunks[path] = {body = body, name = name, chunk = chunk}
		end
		return valid
	end
	return true
end

local function downloadFile(path, func, chunkName)
	local devLoader = shared.PistonwareDevLoadSource
	if type(devLoader) == 'function' then
		local body = devLoader(path)
		return func and func(path) or body
	end
	if not (cacheAllowed() and hasContent(path, chunkName)) then
		--[[ bedwars.lua only exists in the GitLab repo (kept separate/obfuscated there), at that
		repo's ROOT even though it caches locally under games/; everything else lives in the
		GitHub repo. ]]
		local relPath = select(1, path:gsub('pistonware/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		--[[ Retried a few times: raw file hosts intermittently fail, returning an empty body that
		would otherwise get cached as a corrupt/empty file. ]]
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				if isBedwars then
					return pistonwareProtectedHttpGet(protectedRawUrl(), true, attempt)
				end
				return pistonwareHttpGet(projectRawUrl(relPath), true, attempt)
			end)
			--[[ For .lua files, compile-check downloads so an outage page is not cached. ]]
			if suc and res and res ~= '' and res ~= '404: Not Found' and (not path:find('%.lua$') or loadstring(res) ~= nil) then
				content = res
				break
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not content then
			error('failed to download '..path..' after 4 attempts')
		end
		if path:find('%.lua$') then
			content = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..content
		end
		writefile(path, content)
	end
	return (func or readfile)(path)
end

--[[ The repo-folder listing and concurrent prefetch are gone. Icons use uploaded IDs; remaining
assets load lazily when a module needs them. ]]

--[[ False while a game script registers modules. finishLoading uses this because saving and
profile application must wait for the module set. ]]
local gameScriptFinished = true

--[[ Set after the profile is applied; teleport saves are allowed only then. ]]
local profileApplied = false

-- shared survives reinjection on several executors, so every new boot owns a fresh state.
shared.PistonwareBootFailed = nil
shared.PistonwareBootFailure = nil
-- vape is only assigned further down, once the GUI library chunk has run; until then there is
-- nothing to block, and failBoot below re-applies the block once it exists.
if vape and vape.BlockSaving then vape:BlockSaving() elseif vape then vape.SaveBlocked = true end

local function failBoot(stageName, err)
	if not shared.PistonwareBootFailed then
		shared.PistonwareBootFailed = true
		shared.PistonwareBootFailure = {
			stage = tostring(stageName or 'unknown'),
			error = tostring(err or 'unknown failure')
		}
	end
	profileApplied = false
	if vape and vape.BlockSaving then
		vape:BlockSaving()
	elseif vape then
		vape.SaveBlocked = true
		vape.SaveNeeded = nil
	end
	return false
end

local function finishLoading()
	vape.Init = nil
	--[[ shared.VapeCustomProfile is a ONE-SHOT hint for the load that immediately follows
	(set by the loader's first-run config chooser, or by the teleport handler below).
	Capture and clear it up front: getgenv()/shared persists across a reinject, so a
	value left over from an earlier teleport would keep forcing that old profile and
	override the config you actually switched to -- that stale value was the reinject
	'loads the wrong config' bug. Cleared here, a plain reinject always falls through to
	the profile saved in gui.txt (i.e. whatever you last switched to). ]]
	local customProfile = shared.VapeCustomProfile
	shared.VapeCustomProfile = nil
	if customProfile == '' then customProfile = nil end

	--[[
		The profile is applied EXACTLY ONCE, and only after every module exists.

		Loading it early and re-applying afterwards was tried and is wrong in both directions.
		Too early and the payload's modules do not exist yet, so they load on defaults; and the
		second pass needed to fix that would happily overwrite anything you had changed by hand
		in the meantime -- a toggle flipped at 10s silently reverting at 30s is a far worse bug
		than a config that arrives late. One load, once everything is registered, is the only
		version that cannot fight the user.

		Save() has the same constraint from the other side: it serialises the module list as it
		stands, so any save taken before the payload finishes writes a profile missing every
		module yet to appear -- destroying those settings on disk. vape.Loaded stays false for the
		whole of vape:Load, which is what holds saving off until the apply is complete.

		The one exception is a payload that runs past the backstop. Those modules are not lost:
		vape:LoadLate applies their saved settings when they finally register, and it touches only
		the ones that arrived after the load, so it cannot revert anything changed by hand.
	]]
	local function applyProfile(moduleSetComplete)
		--[[ A LuaArmor session that was refused registers no game modules (see the session
		block at the top of bedwars.lua). Loading a profile against that empty set would
		bring everything up on defaults, and the Save below would write those defaults
		back -- deleting the user's real config. Withholding the modules is the intended
		consequence of a refusal; deleting configs is not, so do neither here. ]]
		if shared.PistonwareSessionRejected then
			failBoot('bedwars.session', 'session was not authorised')
			bufferWarn('profile.session', 'session was not authorised -- leaving profiles untouched')
			return
		end
		if shared.PistonwareBootFailed then return end
		if not moduleSetComplete then
			failBoot('modules.timeout', 'the game payload did not signal completion within 120 seconds')
			bufferWarn('profile.timeout', 'payload completion timed out -- profile loading and saving are blocked for this session')
			return
		end
		debugWarn(('[pistonware] applying profile %s (teleported=%s)'):format(
			tostring(customProfile or '<saved>'), tostring(shared.vapereload and true or false)))
		local loadOk, _, canSave = xpcall(function()
			return vape:Load(nil, customProfile)
		end, errorTrace)
		if not loadOk or canSave == false then
			failBoot('profile.apply', loadOk and 'profile data could not be loaded safely' or _)
			bufferWarn('profile.apply', 'profile application failed -- profile saving is blocked for this session')
			return
		end
		debugWarn('[pistonware] profile load returned')

		--[[
			No autosave loop, and nothing timed anywhere in the save path.

			There used to be one because the only way to write safely was to wait until the module set
			had stopped changing, and with a payload that never announces it had finished the only
			available answer was a guess: watch the count, call it settled after thirty seconds of
			quiet, then poll every ten. Every part of that was a workaround for vape:Save walking a hash
			table the payload was still inserting into.

			Save walks vape.ModuleOrder now -- an array, by index -- which nothing about a registration
			can invalidate. That removes the reason to wait, and with it the timer, the poll, and the
			gate they existed to open. A module toggle writes through vape:RequestSave; vape.Loaded is
			the only thing gating it, and vape:Load owns that flag.
		]]
		profileApplied = true
		if vape.AllowSaving then vape:AllowSaving() else vape.SaveBlocked = nil end
	end

	--[[ Waits until the game script has finished registering its modules, because the profile can
	only be applied to modules that exist.

	There are exactly two ways that finish is observable, and no third:
	  * an ordinary game script RETURNS, which sets gameScriptFinished
	  * BedWars pulls in a LuaArmor-protected payload which never returns (the VM keeps the
	    thread it was invoked on), so bedwars.lua sets shared.PistonwareBedwarsLoaded as its
	    final statement

	An earlier version tried to infer completion by watching the module count go quiet. It
	does not work, and cannot be made to: the first seconds of downloadBedwars() are pure
	network, so nothing registers, and "nothing registering" is indistinguishable from
	"finished". It declared victory at 4s -- before the payload had started -- and every
	module that appeared afterwards was left on defaults. Guessing is worse than waiting.

	The timeout is a backstop, not a mechanism. It only matters when the payload on LuaArmor
	predates the completion flag; re-upload bedwars.lua and this returns the moment it lands.
	Returns whether the module list is actually COMPLETE, which is not the same as whether
	the wait finished. Hitting the backstop means the payload is still registering, and the
	caller has to know that before it writes anything to disk. ]]
	local function waitForModules()
		if gameScriptFinished then return true end
		local started = os.clock()
		repeat
			task.wait(0.1)
		until gameScriptFinished
			or shared.PistonwareBedwarsLoaded
			or os.clock() - started > 120
		local complete = (gameScriptFinished or shared.PistonwareBedwarsLoaded) and true or false
		--[[ Same reason as the settle-watcher below: on the timeout path the payload is still
		inserting, so this must not walk vape.Modules to count them. ]]
		local count = vape.ModuleCount or 0
		local how = shared.PistonwareBedwarsLoaded and 'payload signalled'
			or gameScriptFinished and 'game script returned'
			or 'TIMED OUT after 120s -- re-upload bedwars.lua to LuaArmor so it can signal when it is done'
		debugWarn(('[pistonware] %d modules in %.1fs (%s) -- applying profile'):format(count, os.clock() - started, how))
		return complete
	end

	if gameScriptFinished then
		applyProfile(true)
	else
		task.spawn(function()
			applyProfile(waitForModules())
		end)
	end

	local teleportedServers
	vape:Clean(playersService.LocalPlayer.OnTeleport:Connect(function(teleportState)
		--[[ A failed teleport is ignored rather than consumed. OnTeleport fires for EVERY state
		and the one-shot guard below does not look at which -- so an attempt that failed used
		to burn it, and the teleport that actually went somewhere afterwards queued nothing. ]]
		if teleportState == Enum.TeleportState.Failed then return end
		if (not teleportedServers) and (not shared.VapeIndependent) then
			teleportedServers = true
			--[[ Re-enter the appropriate loader on the new server so authentication is derived
			again. The developer path restores loaderdev.lua first so its local hookfunction seam
			is available; the public path loads the published loader and performs the official
			Luarmor check again. ]]
						local teleportScript = [[
							shared.vapereload = true
							local function queuedError(event, message)
								local target
								pcall(function()
									local env = getgenv()
									target = type(env.pistonware) == 'table' and env.pistonware.buffer or nil
								end)
								if type(target) == 'table' and type(target.error) == 'function' then
									target.error(event, message)
								elseif rawget(shared, 'PistonwareDeveloper') == true then
									warn('[pistonware] '..tostring(message))
								end
							end
						-- A developer teleport must restore the developer loader first. loaderdev.lua
						-- installs the local LuaArmor test seam; jumping straight into main.lua loses
						-- that seam in the new Roblox execution context and the local payload reports
						-- an authorization failure even though the original boot was valid.
						if rawget(shared, 'PistonwareDeveloper') == true then
							-- Each step leaves a line in pistonware_teleport.log: nothing else is
							-- up yet on the new server to report where a queued boot stopped.
							local function crumb(text)
								pcall(function()
									local line = os.date('!%Y-%m-%dT%H:%M:%SZ')..' [main.lua] '..text..'\n'
									if type(appendfile) == 'function' and isfile('pistonware_teleport.log') then
										appendfile('pistonware_teleport.log', line)
									else
										writefile('pistonware_teleport.log', line)
									end
								end)
							end
							crumb('queued script started in place '..tostring(game.PlaceId))
							pcall(rawset, shared, 'PistonwareSessionRejected', nil)
							pcall(rawset, shared, 'PistonwareLoaderBoot', nil)
							local developerSource
							pcall(function()
								if type(readfile) == 'function' then
									developerSource = readfile('pistonware/loaderdev.lua')
								end
							end)
							if type(developerSource) == 'string' and developerSource ~= '' then
								local developerChunk, developerError = loadstring(developerSource, 'loaderdev')
								if developerChunk then
									local ran, runError = pcall(developerChunk)
									crumb(ran and 'loaderdev.lua finished' or ('loaderdev.lua errored: '..tostring(runError)))
									-- A boot that died cannot claim AutoQueueDodge's hold, so let the match in
									-- now instead of after the three-minute backstop.
									local hold = shared.PistonwareDodgeHold
									if not ran and type(hold) == 'table' and not hold.claimed and type(hold.release) == 'function' then
										pcall(hold.release)
										crumb('released the AutoQueueDodge hold')
									end
									return
								end
								crumb('loaderdev.lua did not compile: '..tostring(developerError))
								queuedError('teleport.loaderdev.compile', developerError)
								return
							else
								crumb('loaderdev.lua could not be read')
								queuedError('teleport.loaderdev.missing', 'queued developer loader is unavailable; refusing to continue')
								return
							end
						end
						local release = shared.PistonwareRelease
							local ref = type(release) == 'table' and (release.sourceRef or release.branch) or 'main'
							local ok, source = pcall(function()
								return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/'..ref..'/loader.lua', true)
							end)
							if not ok or type(source) ~= 'string' or source == '' or source == '404: Not Found' then
								queuedError('teleport.loader.download', source)
								return
							end
							local chunk, compileError = loadstring(source, 'loader')
							if not chunk then
								queuedError('teleport.loader.compile', compileError)
								return
							end
							return chunk()
					]]
			local currentRelease = shared.PistonwareRelease
			if type(currentRelease) == 'table' then
				local channel = tostring(currentRelease.channel or 'main')
				local branch = tostring(currentRelease.branch or channel)
				local sourceRef = tostring(currentRelease.sourceRef or branch)
				local version = tostring(currentRelease.version or '')
				teleportScript = 'shared.PistonwareChannel = '..string.format('%q', channel)..'\n'
					..'shared.PistonwareRelease = {schema=1, channel='..string.format('%q', channel)
					..', branch='..string.format('%q', branch)
					..', sourceRef='..string.format('%q', sourceRef)
					..', version='..string.format('%q', version)
					..', cacheReady=true, resolved=true}\n'..teleportScript
			end
			--[[ Globals and shared do not survive a teleport. Carry only the key candidate; the
			appropriate loader above must validate it again before main.lua can run. Do not carry
			PistonwareAuthenticated: that boolean is the one-line gate bypass this path used to
			publish. %q keeps keys containing a quote or backslash valid Lua. ]]
			local teleportKey = rawget(shared, 'PistonwareKey')
			if type(teleportKey) == 'string' and teleportKey ~= '' then
				local quoted = string.format('%q', teleportKey)
				teleportScript = 'script_key = '..quoted..'\nrawset(shared, "PistonwareKey", '..quoted..')\n'..teleportScript
			end
			if rawget(shared, 'PistonwareDeveloper') == true then
				teleportScript = 'rawset(shared, "PistonwareDeveloper", true)\n'..teleportScript
			end
			if shared.VapeSmoothBoot then
				teleportScript = 'shared.VapeSmoothBoot = true\n'..teleportScript
			end
			--[[ getgenv() and shared are wiped by a teleport; carry tracing and the optional yield
			budget into the match. ]]
			if traceOn then
				teleportScript = 'shared.PistonwareTrace = true\n'..teleportScript
			end
			do
				local env = (getgenv and getgenv()) or {}
				local budget = tonumber(env.PistonwareYieldBudget or shared.PistonwareYieldBudget)
				if budget and budget > 0 then
					teleportScript = 'shared.PistonwareYieldBudget = '..budget..'\n'..teleportScript
				end
			end
			-- %q, matching the key above: profile names are user-supplied (the Profiles tab lets
			-- you name one anything), and a name containing a quote or backslash used to produce
			-- a chunk that would not compile -- which silently costs the whole re-injection, not
			-- just the profile.
			-- customProfile is the fallback rather than shared.VapeCustomProfile (cleared above):
			-- queueing before the payload has finished means vape.Profile is not set yet, and
			-- without this the next server would be told to load 'default'.
			teleportScript = 'shared.VapeCustomProfile = '..string.format('%q', vape.Profile or customProfile or 'default')..'\n'..teleportScript
			--[[ AutoQueueDodge, FIRST in the script. Loading into a match is the game's
			ConnectController.KnitStart sending PlayerConnect, and it runs as soon as Knit starts, long
			before the loader or anything behind it. So the check lives here: it holds the connect,
			judges the teams against the settings the module saved, and lets you in when they pass.
			pistonware loads alongside it, so its notifications report what is happening and the
			module's Load in now button can let you in early.

			Only acts in a ranked BedWars match, and only while autoqueuedodge.txt says the module is on. ]]
			teleportScript = [==[
local previousHold = shared.PistonwareDodgeHold
if game.PlaceId == 6872274481 and not (type(previousHold) == 'table' and previousHold.jobId == game.JobId) then
	-- Written by the AutoQueueDodge module while it is on, deleted when it is off. No file,
	-- or a module that is off, means this match loads exactly as it always has.
	local settings
	pcall(function()
		if isfile('pistonware/autoqueuedodge.txt') then
			settings = game:GetService('HttpService'):JSONDecode(readfile('pistonware/autoqueuedodge.txt'))
		end
	end)
	if type(settings) == 'table' and settings.enabled == true then
		local hold = {state = 'waiting', jobId = game.JobId}
		shared.PistonwareDodgeHold = hold

		-- Pistonware's own notifications. pistonware keeps loading while the match is held,
		-- but its GUI is not up for the first few seconds, so anything said before then waits
		-- and goes out in order once it is. A vape left in shared by the previous server is
		-- not ours to use.
		local staleVape = shared.vape
		local outbox = {}
		local flushing = false
		local function notify(text, duration, kind)
			-- The module's Notify toggle. Missing from settings written before it existed: on.
			if settings.notify == false then return end
			table.insert(outbox, {text, duration or 6, kind})
			if flushing then return end
			flushing = true
			task.spawn(function()
				local deadline = os.clock() + 180
				while #outbox > 0 and os.clock() < deadline do
					local vape = shared.vape
					if type(vape) == 'table' and vape ~= staleVape and type(vape.CreateNotification) == 'function' then
						local entry = table.remove(outbox, 1)
						pcall(function()
							vape:CreateNotification('AutoQueueDodge', entry[1], entry[2], entry[3])
						end)
					else
						task.wait(0.25)
					end
				end
				flushing = false
			end)
		end

		task.spawn(function()
			local ok, err = pcall(function()
				repeat task.wait() until game:IsLoaded()
				local players = game:GetService('Players')
				local lplr = players.LocalPlayer
				local replicated = game:GetService('ReplicatedStorage')
				local scripts = lplr:WaitForChild('PlayerScripts')

				local controller
				local deadline = os.clock() + 30
				repeat
					pcall(function()
						controller = require(scripts:WaitForChild('TS').controllers.global.connect['connect-controller']).ConnectController
					end)
					if not controller then task.wait() end
				until controller or os.clock() > deadline
				if not controller then
					hold.state = 'failed'
					notify('Could not hold this match, loading in normally.', 6, 'warning')
					return
				end
				if controller.connected then
					hold.state = 'missed'
					notify('You loaded in before this match could be held.', 6, 'warning')
					return
				end

				-- Ranked only. The teleport data names the queue, and every ranked queue's meta
				-- carries a rankCategory. Anything else, or a queue that cannot be read, loads
				-- normally without being held at all.
				local queueMeta = require(replicated.TS.game['queue-meta']).QueueMeta
				local teleportData
				pcall(function()
					teleportData = game:GetService('TeleportService'):GetLocalPlayerTeleportData()
				end)
				local queueType = type(teleportData) == 'table' and type(teleportData.match) == 'table' and teleportData.match.queueType
				local meta = queueType and queueMeta[queueType]
				if not (meta and (meta.rankCategory ~= nil or tostring(queueType):find('ranked', 1, true))) then
					hold.state = 'skipped'
					return
				end
				if type(meta.teams) ~= 'table' then
					hold.state = 'failed'
					return
				end

				local original = controller.KnitStart
				controller.KnitStart = function() end
				hold.controller = controller
				hold.release = function()
					if hold.state ~= 'held' then return false end
					hold.state = 'released'
					controller.KnitStart = original
					task.spawn(function() pcall(original, controller) end)
					return true
				end
				hold.state = 'held'

				local remotes = require(replicated:WaitForChild('TS'):WaitForChild('remotes')).default

				local TIER_NAMES = {'Bronze', 'Silver', 'Gold', 'Platinum', 'Diamond', 'Emerald', 'Nightmare'}
				local rankCache, asked = {}, {}

				local function tierOf(plr)
					local division = rankCache[plr.UserId]
					return type(division) == 'number' and division // 4 or nil
				end

				local function tierName(tier)
					return tier and TIER_NAMES[tier + 1] or 'Unranked'
				end

				local function deviceOf(plr)
					local input = plr:GetAttribute('UserInputType')
					if input == nil then return nil end
					if type(input) == 'number' then
						if input == 7 then return 'mobile' end
						if input >= 9 and input <= 16 then return 'gamepad' end
						return 'pc'
					end
					local name = tostring(input):lower()
					if name:find('gamepad') or name:find('console') or name:find('xbox') or name:find('playstation') then
						return 'gamepad'
					end
					if name:find('touch') or name:find('mobile') or name:find('phone') or name:find('tablet') then
						return 'mobile'
					end
					return 'pc'
				end

				local function fetchRanks(list)
					local ids = {}
					for _, plr in list do
						if not asked[plr.UserId] then
							table.insert(ids, plr.UserId)
						end
					end
					if #ids == 0 then return true end
					local called, success, result = pcall(function()
						return remotes.Client:Get('FetchRanks'):CallServerAsync(ids):await()
					end)
					if not (called and success and type(result) == 'table') then return false end
					for _, id in ids do
						asked[id] = true
					end
					for _, data in result do
						if type(data) == 'table' and data.userId then
							rankCache[data.userId] = data.rankDivision
						end
					end
					return true
				end

				local function snapshot(teams)
					local sides = {}
					for _, team in teams do
						table.insert(sides, {
							id = tostring(team.id),
							name = tostring(team.displayName or ''):lower(),
							size = tonumber(team.maxPlayers) or 5,
							players = {}
						})
					end
					local pending = 0
					for _, plr in players:GetPlayers() do
						if plr ~= lplr then
							local attribute = plr:GetAttribute('Team')
							local teamName = plr.Team and plr.Team.Name:lower()
							local side
							for _, candidate in sides do
								if (attribute ~= nil and tostring(attribute) == candidate.id)
									or (teamName and candidate.name ~= '' and teamName:find(candidate.name, 1, true)) then
									side = candidate
									break
								end
							end
							if side then
								table.insert(side.players, plr)
							else
								pending += 1
							end
						end
					end
					return sides, pending
				end

				local function withMe(list)
					local copy = table.clone(list)
					table.insert(copy, lplr)
					return copy
				end

				local function bestTier(list)
					local best
					for _, plr in list do
						local tier = tierOf(plr)
						if tier and (not best or tier > best) then
							best = tier
						end
					end
					return best
				end

				local function countAbove(list, others)
					local best = bestTier(others)
					local count = 0
					for _, plr in list do
						local tier = tierOf(plr)
						if tier and (not best or tier > best) then
							count += 1
						end
					end
					return count
				end

				local function vetoReason(enemy, mine)
					if not settings.rankVeto then return nil end
					local above = countAbove(enemy, mine)
					if above >= (settings.vetoCount or 2) then
						return ('%d of them outrank your best (%s)'):format(above, tierName(bestTier(mine)))
					end
					return nil
				end

				local function matchReason(enemy, mine)
					if settings.rankAdvantage then
						local above = countAbove(mine, enemy)
						if above >= (settings.advantageCount or 3) then
							return ('%d of your team outrank their best'):format(above)
						end
					end
					if settings.weakDevices then
						local gamepads, mobiles = 0, 0
						for _, plr in enemy do
							local device = deviceOf(plr)
							if device == 'gamepad' then
								gamepads += 1
							elseif device == 'mobile' then
								mobiles += 1
							end
						end
						if gamepads >= (settings.gamepadCount or 2) then
							return ('%d gamepad players against you'):format(gamepads)
						elseif mobiles >= (settings.mobileCount or 3) then
							return ('%d mobile players against you'):format(mobiles)
						elseif settings.mixedDevices and gamepads >= 1 and mobiles >= 1 then
							return 'a mobile and a gamepad player against you'
						end
					end
					if settings.lowRank then
						local limit = (table.find(TIER_NAMES, settings.lowRankTier) or 3) - 1
						for _, plr in enemy do
							local tier = tierOf(plr)
							if tier and tier <= limit then
								return ('a %s player against you'):format(tierName(tier))
							end
						end
					end
					return nil
				end

				-- 'load', 'dodge', or nil to keep waiting, plus the reason. You join the smaller
				-- team, so yours is only known once the teams are uneven; with even teams you are
				-- the extra player on either side, and the veto has to pass against both.
				local function decide(teams, waitedOut)
					local sides, pending = snapshot(teams)
					if #sides ~= 2 then
						return 'load', 'this is not a two-team queue'
					end
					local a, b = sides[1], sides[2]
					local small, large = a, b
					if #a.players > #b.players then
						small, large = b, a
					end
					if #small.players >= small.size then
						return 'dodge', 'both teams are already full'
					end

					local oneFull = #large.players >= large.size
						and (#small.players + 1 >= small.size or pending == 0)
					local bothShort = pending == 0
						and #a.players == a.size - 1 and #b.players == b.size - 1
					if not (oneFull or bothShort or waitedOut) then
						return nil, ('%d v %d, %d still loading in'):format(#a.players, #b.players, pending)
					end

					local everyone = withMe(a.players)
					for _, plr in b.players do
						table.insert(everyone, plr)
					end
					if not fetchRanks(everyone) then
						return nil, 'looking up ranks'
					end

					if #small.players == #large.players then
						local count = #small.players
						local veto = vetoReason(a.players, withMe(b.players)) or vetoReason(b.players, withMe(a.players))
						if veto then
							return 'dodge', veto
						end
						if not settings.advanced or settings.extraPlayer then
							return 'load', ('%dv%d on either team'):format(count + 1, count)
						end
						local first = matchReason(a.players, withMe(b.players))
						local second = matchReason(b.players, withMe(a.players))
						if first and second then
							return 'load', first
						end
						return 'dodge', 'no advanced rule matches against both teams'
					end

					if settings.outnumbered ~= false and #small.players + 1 < #large.players then
						return 'dodge', ('you would be in a %dv%d'):format(#small.players + 1, #large.players)
					end
					local mine = withMe(small.players)
					local veto = vetoReason(large.players, mine)
					if veto then
						return 'dodge', veto
					end
					-- Basic mode only screens out bad matches; Advanced also asks for a reason to load.
					if not settings.advanced then
						return 'load', 'the teams pass your checks'
					end
					local reason = matchReason(large.players, mine)
					if reason then
						return 'load', reason
					end
					return 'dodge', 'no advanced rule matches this lobby'
				end

				local started = os.clock()
				local lastReason, lastWaitNotice = nil, 0
				while hold.state == 'held' do
					if controller.connected then
						hold.state = 'missed'
						notify('You loaded in before this match could be held.', 6, 'warning')
						break
					end
					local verdict, reason = decide(meta.teams, os.clock() - started >= (settings.maxWait or 30))
					if verdict == 'load' then
						if hold.release() then
							notify('Loading in: '..reason..'.', 8)
						end
						break
					elseif verdict == 'dodge' then
						if reason ~= lastReason then
							lastReason = reason
							notify('Not loading: '..reason..'.\nLeave to requeue, or press Load in now in the module.', 15, 'warning')
						end
					elseif os.clock() - lastWaitNotice >= 6 then
						lastReason = nil
						lastWaitNotice = os.clock()
						notify('Waiting: '..reason..'.', 5)
					end
					task.wait(0.5)
				end
			end)
			if not ok then
				-- Never strand anyone on an error in here: let the match in.
				if hold.state == 'held' and hold.release then
					hold.release()
				elseif hold.state == 'waiting' then
					hold.state = 'failed'
				end
				notify('Stopped checking this match ('..tostring(err)..'), loading you in.', 10, 'alert')
			end
		end)
	end
end
]==]..teleportScript
			--[[
				Queue FIRST, and guard everything after it.

				The queue call used to be LAST, sitting behind an unguarded vape:Save(). Two
				things were wrong with that, and together they are the crash people hit when
				queueing from one match straight into another:

				  * Save() serialises every module and writes a file. This callback runs while
				    the client is already tearing down for the teleport, and a blocking disk
				    write in that window is what takes the game down with it -- worst on mobile,
				    where storage is slowest and the window is shortest.
				  * Save() was not pcall'd. If it threw, queue_on_teleport never ran at all, so
				    the script silently failed to come back on the new server. A failure to save
				    became a failure to re-inject.

				Queueing first ensures that later save failures do not prevent re-injection.
			]]
			local queued = pcall(queue_on_teleport, teleportScript)
			--[[ Tells loaderdev.lua's fallback handler this teleport is already taken care of, so
			a developer session never queues two boots. ]]
			if queued and hasQueueOnTeleport then
				pcall(rawset, shared, 'PistonwareTeleportQueued', true)
			end

			if not hasQueueOnTeleport then
				pcall(function()
					vape:CreateNotification('Pistonware', 'queue_on_teleport is not supported by your executor -- Vape will not re-inject automatically after this teleport (e.g. queueing into a match). You will need to re-run your loadstring manually.', 15, 'alert')
				end)
			end

			--[[ Best effort, and last. Same rule as everywhere else: saving before the profile has
			been applied against the full module set would write one missing every module still
			to appear. Queueing straight into a match is exactly when that happens, so skip the
			save rather than corrupt the config -- what is on disk is already correct, there is
			simply nothing new worth recording yet. ]]
			if profileApplied then
				pcall(function() vape:Save() end)
			end
		end
	end))

	if shared.PistonwareSyncResult then
		vape:CreateNotification('Pistonware', shared.PistonwareSyncResult, 15, shared.PistonwareSyncResult:find('failed') and 'alert' or nil)
		shared.PistonwareSyncResult = nil
	end

	if not shared.vapereload then
		--[[ Cosmetic, and entirely inside a pcall, because the rewrite moved every field it reads.
		'GUI bind indicator' left Categories.Main.Options for Settings.GUI.Options, the keybind
		list became GUIBind.Keys instead of a flat vape.Keybind, and vape.VapeButton no longer
		exists at all. A finished-loading toast is not worth risking finishLoading over if any
		of that moves again. ]]
		pcall(function()
			if not vape.Categories then return end
			local indicator = vape.Settings and vape.Settings.GUI and vape.Settings.GUI.Options['GUI bind indicator']
			if not (indicator and indicator.Enabled) then return end
			local keys = vape.GUIBind and vape.GUIBind.Keys
			local how = (keys and #keys > 0)
				and ('Press '..table.concat(keys, ' + '):upper()..' to open GUI')
				or 'Open the GUI with your keybind'
			vape:CreateNotification('Pistonware | Finished Loading', how, 5)
		end)
	end
end

	--[[
		One GUI now.

		guis/old.lua and guis/rise.lua are discontinued and deleted, so the gui.txt theme
		indirection has nothing left to choose between -- every value it could hold except one
		names a file that would 404. Reading it to decide which GUI to load was a way to break the
		install, not a feature, so the choice is made here instead.

		The asset folder keeps its own separate name: 'new' is the path the GUI itself asks for
		(pistonware/assets/new/...), and that is unrelated to what the GUI file is called.
	]]
	local GUI_FILE = 'newgui'
	local ASSET_FOLDER = 'new'

	--[[ Still written, so anything else reading gui.txt sees something current rather than a
	stale 'rise'/'old' left over from before those were removed. ]]
	pcall(function() writefile('pistonware/profiles/gui.txt', GUI_FILE) end)

	--[[
		No asset prefetch, and nothing to prefetch for.

		The GUI now resolves every icon it draws to an uploaded rbxassetid and never opens a file
		under pistonware/assets. This used to download the whole folder -- 105 files, 105 HTTP
		requests and 105 disk writes -- on the critical path of the first run, on every platform,
		and the desktop GUI then read each of those files back twice per icon.

		A few paths that only game modules ask for still have no uploaded id, so the GUI keeps a
		lazy fallback for exactly those: it downloads them the first time a module that draws one is
		built, not here, and not for anyone who never opens it. Prefetching 105 files to serve
		five of them was the expensive way round.

		The folder is still created, because that lazy fallback writes into it.
	]]
	if not isfolder('pistonware/assets/'..ASSET_FOLDER) then
		makefolder('pistonware/assets/'..ASSET_FOLDER)
	end
	stage('downloading gui')
	vape = runChunk(downloadFile('pistonware/guis/'..GUI_FILE..'.lua', nil, 'gui'), 'gui')
	stage('gui chunk returned')
	if not vape then return end
	shared.vape = vape

if not shared.VapeIndependent then
	--[[ downloading doesn't need the game loaded; only wait here, right before touching game/character state ]]
	if not game:IsLoaded() then
		--[[ Deadline, matching every equivalent wait in the loader. Unbounded, a place that never
		reports loaded parks this thread forever AFTER the GUI has already been built above --
		so the menu opens, no game modules ever register, and nothing says why. ]]
		local loadDeadline = os.clock() + 120
		repeat task.wait() until game:IsLoaded() or os.clock() > loadDeadline
		--[[ identifyexecutor is absent on some executors (common on mobile); calling it
		unguarded errors here and aborts everything below, including the game script. ]]
		local executorName = ''
		pcall(function() executorName = identifyexecutor and identifyexecutor() or '' end)
		task.wait(executorName == 'Opiumware' and 30 or 5)
	end
	--[[ pcall'd: an error thrown while universal.lua executes would otherwise propagate out of
	main.lua entirely, skipping the game script below and finishLoading() with it. The error is
	reported rather than swallowed: a silent universal failure used to look like random missing
	modules, because nothing downstream re-raises it. ]]
	stage('universal.lua start')
	do
		local okUniversal, universalError = xpcall(function()
			runChunk(downloadFile('pistonware/games/universal.lua', nil, 'universal'), 'universal')
		end, errorTrace)
		if not okUniversal then
			failBoot('universal.load', universalError)
			reportRuntimeError('universal.load', universalError, universalError)
		end
	end

	--[[ Started, never waited on. There is no deadline here by design: a deadline would only be a
	guess at how long the payload needs, and whatever number it held would become the time
	your profile takes to load. Nothing below depends on this having finished -- finishLoading
	applies your profile to the modules that exist now, and re-applies it the moment the rest
	register (see finishLoading).

	This costs nothing for a normal game script: task.spawn runs the function inline until it
	yields, so anything that registers its modules without yielding -- which is every game
	file except BedWars -- has already set gameScriptFinished before we get past this line,
	and finishLoading takes the single-pass path exactly as it always did.

	BedWars is the exception. bedwars.lua is 425KB interpreted by a LuaArmor VM and takes
	~30s, and none of its modules can exist until it finishes -- that part is not fixable from
	here. What it must not do is hold up the GUI, the universal modules and your config, none
	of which have anything to do with it.

	Varargs are packed because '...' is only valid directly in this chunk, never inside the
	nested function the spawn needs. ]]
	local gameArgs = table.pack(...)
	local function runGameScript(source, chunkname)
		local fn, compileError = takeValidatedChunk(source, chunkname)
		if not fn then
			fn, compileError = loadstring(source, chunkname)
		end
		if not fn then
			local trace = errorTrace(compileError)
			failBoot('game.compile', trace)
			gameScriptFinished = true
			reportRuntimeError('game.compile', compileError, trace)
			return false
		end
		gameScriptFinished = false
		--[[ Cleared per run, not just per session: shared survives a reinject, and a leftover true
		from the previous injection would tell waitForModules the payload had already finished
		before it had even started re-registering. ]]
		shared.PistonwareBedwarsLoaded = nil
		--[[ Same reasoning for the refusal flag: bedwars.lua sets it from a fresh verdict every
		run, but a game script that never sets it at all (the lobby) would otherwise inherit
		a true left behind by a revoked BedWars session and refuse to save profiles there. ]]
		shared.PistonwareSessionRejected = nil

		--[[ Re-publish the key immediately before the game script runs. LuaArmor blanks the global
		script_key once it has authenticated, so it is single-use per session and any later
		load finds nothing -- which is not a soft failure, it kicks the player.

		games/6872274481.lua does this too, closer to the payload, but that file is CACHED:
		anyone still holding a copy from before it gained that call would never get it. This
		file is the one that is reliably current, so the safety net belongs here as well.

		Written to all three tables because executors disagree on what a loadstring'd chunk's
		environment is -- on several mobile executors a bare global, getgenv() and _G are
		genuinely different tables, and the payload only reads one of them. ]]
		if type(shared.PistonwareKey) == 'string' and shared.PistonwareKey ~= '' then
			local key = shared.PistonwareKey
			script_key = key
			pcall(function() getgenv().script_key = key end)
			pcall(function() _G.script_key = key end)
		end

		local started = os.clock()
		task.spawn(function()
			local ok, result = xpcall(function()
				return fn(table.unpack(gameArgs, 1, gameArgs.n))
			end, errorTrace)
			if not ok then
				failBoot('game.execute', result)
			elseif type(result) == 'table' and result.PistonwareBootFailure then
				failBoot(result.stage or 'game.execute', result.error or 'game script reported an incomplete boot')
			end
			gameScriptFinished = true
			--[[ Only for a payload slow enough that the split-load path actually engaged; a normal
			game script never trips it. Keeps the real cost of protecting bedwars.lua visible
			instead of guessed at. ]]
			local elapsed = os.clock() - started
			if elapsed > 5 then
				debugWarn(('[pistonware] %s finished in %.1fs -- its modules now have their saved settings'):format(chunkname, elapsed))
			end
			if not ok then
				reportRuntimeError('game.execute', result, result)
			end
		end)
		return true
	end

	local gamePath = 'pistonware/games/'..game.PlaceId..'.lua'
	--[[ A cached-but-empty file is treated as missing and refetched: a truncated write from an
	earlier failed download reads back as "present", and loadstring('') silently does
	nothing -- indistinguishable from the game script never loading at all. ]]
	local gameScriptStarted = false
		local cached = cacheAllowed() and hasContent(gamePath, tostring(game.PlaceId)) and readfile(gamePath) or nil
	if cached and cached:gsub('%s', '') ~= '' then
		gameScriptStarted = runGameScript(cached, tostring(game.PlaceId))
	end
	if not gameScriptStarted and not shared.PistonwareDeveloper then
		--[[ Single fetch (the old code requested this URL twice: once to probe, then again
		inside downloadFile) and load straight from the response, so a stale/corrupt
		cache file can't shadow what we just downloaded. ]]
		local suc, res = pcall(function()
			return pistonwareHttpGet(projectRawUrl('games/'..game.PlaceId..'.lua'), true)
		end)
		if suc and res and res ~= '' and res ~= '404: Not Found' then
			pcall(writefile, gamePath, '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..res)
			gameScriptStarted = runGameScript(res, tostring(game.PlaceId))
		end
	end
	if not gameScriptStarted then
		failBoot('game.download', 'no usable game adapter could be loaded for '..tostring(game.PlaceId))
		gameScriptFinished = true
	end
	finishLoading()
else
	vape.Init = finishLoading
	return vape
end
