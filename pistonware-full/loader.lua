local PUBLIC_BUILD = true

local function installPistonwareBuffer(developerMode)
	local nativePrint, nativeWarn, nativeError = print, warn, error
	local capacity = 512
	local entries = {}
	local head, count, dropped = 1, 0, 0
	local dumping, dumpScheduled, pendingDump = false, false, false
	local filesystemReady = false
	local buffer = {}

	pcall(function()
		filesystemReady = type(isfolder) == 'function' and isfolder('pistonware') and true or false
	end)

	local function timestamp(pathSafe)
		local value
		pcall(function()
			value = os.date(pathSafe and '!%Y%m%dT%H%M%SZ' or '!%Y-%m-%dT%H:%M:%SZ')
		end)
		return value or tostring(os.time())
	end

	local session = tostring(os.time())..'-'..tostring(math.floor(os.clock() * 1000))
	pcall(function()
		local guid = game:GetService('HttpService'):GenerateGUID(false)
		if type(guid) == 'string' and guid ~= '' then session = guid end
	end)
	local sessionFile = session:gsub('[^%w%-]', ''):sub(1, 16)
	local dumpPath = 'pistonware/errors/'..timestamp(true)..'-'..sessionFile..'.txt'

	local function safeText(value, limit)
		local text = tostring(value or '')
		text = text:gsub('[\r\n]+', ' ')
		text = text:gsub('([Ss]cript[_%s]*[Kk]ey%s*[:=]%s*)[^%s,;]+', '%1<redacted>')
		text = text:gsub('([?&][Kk]ey=)[^&%s]+', '%1<redacted>')
		limit = limit or 1200
		if #text > limit then text = text:sub(1, limit - 3)..'...' end
		return text
	end

	local function copyDetails(details)
		local result = {}
		if type(details) == 'table' then
			for key, value in pairs(details) do
				if type(value) ~= 'table' and type(value) ~= 'function' then
					result[safeText(key, 80)] = safeText(value, 3000)
				end
			end
		end
		return result
	end

	local function formatEntry(entry)
		local parts = {}
		for key, value in pairs(entry.details) do
			table.insert(parts, tostring(key)..'='..tostring(value))
		end
		table.sort(parts)
		local line = ('[%s] [pistonware] [%s] [%s] %s'):format(
			entry.timestamp,
			entry.level:upper(),
			entry.event,
			entry.message
		)
		if #parts > 0 then line = line..' '..table.concat(parts, ' ') end
		return line
	end

	local function orderedEntries()
		local result = {}
		for offset = 0, count - 1 do
			result[#result + 1] = entries[((head + offset - 1) % capacity) + 1]
		end
		return result
	end

	local function requestDump()
		pendingDump = true
		if not filesystemReady or dumping or dumpScheduled then return end
		dumpScheduled = true
		local function flush()
			dumpScheduled = false
			buffer.dump('automatic error')
		end
		if task and type(task.defer) == 'function' then
			task.defer(flush)
		else
			flush()
		end
	end

	local function record(level, event, message, details)
		local entry = {
			timestamp = timestamp(false),
			level = safeText(level, 20):lower(),
			event = safeText(event, 160),
			message = safeText(message, 1600),
			details = copyDetails(details)
		}
		if count < capacity then
			entries[((head + count - 1) % capacity) + 1] = entry
			count += 1
		else
			entries[head] = entry
			head = (head % capacity) + 1
			dropped += 1
		end

		local line = formatEntry(entry)
		if developerMode then
			if entry.level == 'warn' or entry.level == 'error' or entry.level == 'fatal' then
				pcall(nativeWarn, line)
			else
				pcall(nativePrint, line)
			end
		end
		if entry.level == 'error' or entry.level == 'fatal' then requestDump() end
		return line
	end

	function buffer.log(event, message, details)
		return record('info', event, message, details)
	end

	function buffer.print(event, message, details)
		return record('info', event, message, details)
	end

	function buffer.warn(event, message, details)
		return record('warn', event, message, details)
	end

	function buffer.error(event, message, details)
		return record('error', event, message, details)
	end

	function buffer.raise(event, message, details, level)
		record('error', event, message, details)
		buffer.dump('raised error')
		return nativeError(message, (tonumber(level) or 1) + 1)
	end

	function buffer.guard(stage, fatal, callback, ...)
		local args = table.pack(...)
		local result = table.pack(xpcall(function()
			return callback(table.unpack(args, 1, args.n))
		end, function(err)
			local trace
			pcall(function()
				trace = debug and type(debug.traceback) == 'function' and debug.traceback(tostring(err), 2)
			end)
			return trace or tostring(err)
		end))
		if not result[1] then
			record(fatal and 'fatal' or 'error', stage, result[2], {traceback = result[2]})
		end
		return table.unpack(result, 1, result.n)
	end

	function buffer.snapshot()
		local snapshot = {}
		for index, entry in ipairs(orderedEntries()) do
			snapshot[index] = {
				timestamp = entry.timestamp,
				level = entry.level,
				event = entry.event,
				message = entry.message,
				details = copyDetails(entry.details)
			}
		end
		return snapshot, dropped
	end

	function buffer.dump(reason)
		if dumping then return false, 'a buffer dump is already running', count end
		if not filesystemReady then
			pendingDump = true
			return false, 'the pistonware filesystem is not ready', count
		end
		if type(writefile) ~= 'function' then return false, 'writefile is unavailable', count end
		pendingDump = false
		dumping = true
		local ok, result = pcall(function()
			if type(isfolder) == 'function' and type(makefolder) == 'function' then
				if not isfolder('pistonware/errors') then makefolder('pistonware/errors') end
			end
			local release = type(shared.PistonwareRelease) == 'table' and shared.PistonwareRelease or {}
			local lines = {
				'Pistonware error buffer',
				'session='..session,
				'dumped='..timestamp(false),
				'reason='..safeText(reason or 'manual', 240),
				'channel='..safeText(release.channel or 'unknown', 80),
				'version='..safeText(release.version or 'unknown', 160),
				'placeId='..safeText(game and game.PlaceId or 0, 40),
				'entries='..tostring(count),
				'dropped='..tostring(dropped),
				''
			}
			for _, entry in ipairs(orderedEntries()) do
				lines[#lines + 1] = formatEntry(entry)
			end
			writefile(dumpPath, table.concat(lines, '\n')..'\n')
			return dumpPath
		end)
		dumping = false
		if ok then
			if pendingDump then requestDump() end
			return true, result, count
		end
		pendingDump = true
		return false, tostring(result), count
	end

	local function markFilesystemReady()
		filesystemReady = true
		if pendingDump then requestDump() end
	end

	pcall(function()
		local env = type(getgenv) == 'function' and getgenv() or nil
		if type(env) ~= 'table' then return end
		local namespace = env.pistonware
		if type(namespace) ~= 'table' then
			namespace = {}
			env.pistonware = namespace
		end
		namespace.buffer = buffer
	end)

	return buffer, markFilesystemReady
end

local pistonwareBuffer, markPistonwareBufferFilesystemReady = installPistonwareBuffer(false)

local VERSION_SCHEMA = 1
local CHANNELS = {
	main = {branch = 'main', label = 'stable'},
	beta = {branch = 'beta', label = 'beta'},
	nightly = {branch = 'nightly', label = 'nightly'}
}

local function configuredValue(name)
	local value
	pcall(function()
		local env = type(getgenv) == 'function' and getgenv() or nil
		if type(env) == 'table' then
			value = env[name]
		end
	end)
	if value == nil then
		pcall(function()
			value = shared[name]
		end)
	end
	return value
end

local requestedChannel = configuredValue('PistonwareChannel')
if type(requestedChannel) ~= 'string' then
	requestedChannel = 'main'
end
requestedChannel = requestedChannel:lower():gsub('^%s*(.-)%s*$', '%1')
local channelSpec = CHANNELS[requestedChannel]
local invalidChannel = channelSpec == nil
channelSpec = channelSpec or CHANNELS.main

local release = {
	schema = VERSION_SCHEMA,
	channel = channelSpec.branch == requestedChannel and requestedChannel or 'main',
	branch = channelSpec.branch,
	label = channelSpec.label,
	sourceRef = channelSpec.branch,
	requestedChannel = requestedChannel,
	cacheReady = false,
	resolved = false
}

local function safeText(value, limit)
	local text = tostring(value or '')
	text = text:gsub('[\r\n]+', ' ')
	text = text:gsub('([Ss]cript[_%s]*[Kk]ey%s*[:=]%s*)[^%s,;]+', '%1<redacted>')
	text = text:gsub('([?&][Kk]ey=)[^&%s]+', '%1<redacted>')
	limit = limit or 900
	if #text > limit then
		text = text:sub(1, limit - 3)..'...'
	end
	return text
end

local function jsonEncode(value)
	local ok, encoded = pcall(function()
		return game:GetService('HttpService'):JSONEncode(value)
	end)
	if ok and type(encoded) == 'string' then
		return encoded
	end
	local text = safeText(value, 1800)
	text = text:gsub('\\', '\\\\'):gsub('"', '\\"')
	return '"'..text..'"'
end

local function appendText(path, text)
	if type(appendfile) == 'function' then
		local ok = pcall(appendfile, path, text)
		if ok then return true end
	end
	if type(writefile) ~= 'function' then return false end
	local previous = ''
	if type(readfile) == 'function' then
		pcall(function()
			local body = readfile(path)
			if type(body) == 'string' then previous = body end
		end)
	end
	if #previous > 262144 then
		previous = previous:sub(-131072)
	end
	return pcall(writefile, path, previous..text)
end

local function placeId()
	local value
	pcall(function() value = tonumber(game.PlaceId) end)
	return value or 0
end

local function sessionId()
	local guid
	pcall(function()
		guid = game:GetService('HttpService'):GenerateGUID(false)
	end)
	return type(guid) == 'string' and guid or (tostring(os.time())..'-'..tostring(math.floor(os.clock() * 1000)))
end

local function timestamp()
	local value
	pcall(function() value = os.date('!%Y-%m-%dT%H:%M:%SZ') end)
	return value or tostring(os.time())
end

local loaderSession = sessionId()
local logFiles = {'pistonware_loader.log'}
local logFileSet = {['pistonware_loader.log'] = true}
local telemetryFiles = {'pistonware_loader_telemetry.jsonl'}
local telemetryFileSet = {['pistonware_loader_telemetry.jsonl'] = true}

local function addFile(files, seen, path)
	if type(path) ~= 'string' or path == '' or seen[path] then return end
	seen[path] = true
	table.insert(files, path)
end

--[[ Whether the boot log is echoed into the executor output, read HERE -- at the top, before
the public build clears the flag further down -- so that setting

    shared.PistonwareDeveloper = true

in front of the loadstring turns the log on for the whole run. Captured once rather than read
per line precisely because of that clear: read live, only the loader.start line above the
lockout would ever appear.

This switch grants nothing else. The lockout still nils the flag, and isDeveloper is still
computed after it, so developer mode itself stays shut in a public build -- this decides
visibility of the loader's own log lines and nothing more. The lines are safe to show (safeText
redacts anything key-shaped), they are just noise: a wall of INFO during a boot that went fine
reads to an end user like something is broken. ]]
local logToConsole = shared.PistonwareDeveloper and true or false

local Logger = {}
Logger.__index = Logger

function Logger:addFile(path)
	addFile(logFiles, logFileSet, path)
end

function Logger:bindConsole(console)
	self.console = console
	if self.lastLine then
		pcall(function() console:SetLine(self.lastLine) end)
	end
end

function Logger:emit(level, event, message, details)
	local parts = {}
	if type(details) == 'table' then
		for key, value in pairs(details) do
			if type(value) ~= 'table' and type(value) ~= 'function' then
				table.insert(parts, tostring(key)..'='..safeText(value, 240))
			end
		end
		table.sort(parts)
	end
	local line = ('[%s] [pistonware] [%s] [%s] %s'):format(timestamp(), level:upper(), event, safeText(message, 1200))
	if #parts > 0 then line = line..' '..table.concat(parts, ' ') end
	self.lastLine = line
	for _, path in ipairs(logFiles) do
		appendText(path, line..'\n')
	end
	if self.console then
		pcall(function() self.console:SetLine(line) end)
	end
	if level == 'error' then
		pistonwareBuffer.error(event, message, details)
	elseif level == 'warn' then
		pistonwareBuffer.warn(event, message, details)
	else
		pistonwareBuffer.log(event, message, details)
	end
	return line
end

function Logger:info(event, message, details)
	return self:emit('info', event, message, details)
end

function Logger:warn(event, message, details)
	return self:emit('warn', event, message, details)
end

function Logger:error(event, message, details)
	return self:emit('error', event, message, details)
end

local logger = setmetatable({}, Logger)

local Telemetry = {}
Telemetry.__index = Telemetry

local function telemetryValue(value)
	if type(value) == 'string' then return safeText(value, 3000) end
	if type(value) == 'number' or type(value) == 'boolean' then return value end
	return safeText(value, 3000)
end

function Telemetry:addFile(path)
	addFile(telemetryFiles, telemetryFileSet, path)
end

function Telemetry:report(event, message, details)
	local payload = {
		schema = VERSION_SCHEMA,
		event = event,
		message = safeText(message, 1600),
		session = loaderSession,
		channel = release.channel,
		branch = release.branch,
		version = release.version,
		placeId = placeId(),
		at = os.clock()
	}
	if type(details) == 'table' then
		for key, value in pairs(details) do
			if type(value) ~= 'table' and type(value) ~= 'function' then
				payload[key] = telemetryValue(value)
			end
		end
	end
	local encoded = jsonEncode(payload)
	for _, path in ipairs(telemetryFiles) do
		appendText(path, encoded..'\n')
	end

	local endpoint = self.endpoint
	local requestFn = self.requestFn
	if endpoint and requestFn then
		pcall(requestFn, {
			Url = endpoint,
			Method = 'POST',
			Headers = {['Content-Type'] = 'application/json'},
			Body = encoded
		})
	end
	return payload
end

local telemetry = setmetatable({}, Telemetry)
local configuredTelemetryEndpoint = configuredValue('PistonwareTelemetryEndpoint') or configuredValue('PistonwareTelemetryUrl')
if type(configuredTelemetryEndpoint) == 'string' and configuredTelemetryEndpoint:match('^https://') then
	telemetry.endpoint = configuredTelemetryEndpoint
end
pcall(function()
	local candidates = {
		request,
		http_request,
		syn and syn.request,
		http and http.request
	}
	for _, candidate in ipairs(candidates) do
		if type(candidate) == 'function' then
			telemetry.requestFn = candidate
			break
		end
	end
end)

local function reportError(stage, err, trace, fatal)
	local message = safeText(err, 1600)
	logger:error('loader.error', message, {stage = stage, channel = release.channel})
	telemetry:report('loader_error', message, {
		stage = stage,
		fatal = fatal == true,
		traceback = trace and safeText(trace, 3000) or nil
	})
	return message
end

local loaderStopped = false
local function stopExecution(console, stage, err, trace, display)
	if loaderStopped then return false end
	loaderStopped = true
	local message = reportError(stage, err, trace, true)
	shared.PistonwareLoaderBoot = nil
	shared.vapereload = nil
	if console then
		pcall(function() console:Fail(display or ('Loader stopped: '..message)) end)
		pcall(function() console:Halt() end)
	end
	return false
end

local function errorTrace(err)
	local traceback
	pcall(function()
		if debug and type(debug.traceback) == 'function' then
			traceback = debug.traceback(tostring(err), 2)
		end
	end)
	return traceback or tostring(err)
end

logger:info('loader.start', 'loader started', {
	channel = release.channel,
	branch = release.branch,
	session = loaderSession
})
if invalidChannel then
	logger:warn('version.channel', 'unknown channel; using main', {requested = requestedChannel})
end

if PUBLIC_BUILD then
	shared.PistonwareDeveloper = nil
	pcall(function()
		if getmetatable(shared) ~= nil then return end
		setmetatable(shared, {
			__index = function(self, key)
				if key == 'PistonwareDeveloper' then return nil end
				return rawget(self, key)
			end,
			__newindex = function(self, key, value)
				if key == 'PistonwareDeveloper' then return end
				rawset(self, key, value)
			end
		})
	end)
end

local isDeveloper = (not PUBLIC_BUILD) and shared.PistonwareDeveloper and true or false

--[[ Developer-only boot timing. These marks stay out of the public build. ]]
local phaseClock = os.clock()
local function phase(name)
	local now = os.clock()
	local elapsed = now - phaseClock
	logger:info('boot.phase', name..' completed', {seconds = ('%.2f'):format(elapsed)})
	if isDeveloper then pistonwareBuffer.print('boot.phase', name..' completed', {seconds = ('%.2f'):format(elapsed)}) end
	phaseClock = now
end

--[[ A second run is allowed to take over an older boot: createConsole tears the old window down,
and the older boot unwinds without touching the new one's flags. ]]
if shared.PistonwareLoaderBoot and os.clock() - shared.PistonwareLoaderBoot < 180 then
	logger:warn('loader.duplicate', 'loader is already running; ignoring duplicate execution')
	return
end
shared.PistonwareLoaderBoot = os.clock()
--[[ Identifies THIS boot in the session-wide shared table, so a run that has been taken over can
tell that the flags it is about to clear now belong to somebody else. ]]
local bootStamp = shared.PistonwareLoaderBoot

local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(ref)
	return ref
end
local delfile = delfile or function(file)
	writefile(file, '')
end

local setclipboard = setclipboard or toclipboard or (Clipboard and Clipboard.set)

local Watermark = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.'

local RELEASE_FILE = 'pistonware_release.json'
local PROJECT_REPO = 'nalityemailperson-create/New-horizons'
local PROJECT_ROOT = 'pistonware-full/'
--[[ ======================================================================== ]]

local function sourceRef(ref)
	return ref or release.sourceRef or release.branch
end

local function projectRawUrl(path, ref)
	path = tostring(path or ''):gsub('^/', '')
	return 'https://raw.githubusercontent.com/'..PROJECT_REPO..'/'..sourceRef(ref)..'/'..PROJECT_ROOT..path
end

local function projectPath(path)
	path = tostring(path or '')
	return path:sub(1, #PROJECT_ROOT) == PROJECT_ROOT and path:sub(#PROJECT_ROOT + 1) or path
end

local function rewriteProjectUrl(url)
	local value = tostring(url or '')
	local ref = sourceRef()
	value = value:gsub('https://raw%.githubusercontent%.com/nalityemailperson%-create/New%-horizons/[^/]+/pistonware%-full/', function() return projectRawUrl('', ref) end)
	value = value:gsub('(/git/trees/)main', '%1'..release.branch)
	value = value:gsub('([?&]sha=)main', '%1'..ref)
	value = value:gsub('([?&]ref=)main', '%1'..ref)
	return value
end

shared.PistonwareRawUrl = projectRawUrl
shared.PistonwareRewriteUrl = rewriteProjectUrl
shared.PistonwareRelease = release
shared.PistonwareTelemetry = telemetry
shared.PistonwareChannel = release.channel
if not isDeveloper then
	shared.PistonwareDevHttpGet = function(url, nocache)
		return game:HttpGet(rewriteProjectUrl(url), nocache)
	end
end

--[[ Empty counts as missing. The executor's real isfile reports a zero-byte file as present, so a
write interrupted by a cancel, a crash or a teleport leaves a truncated file that this
function would otherwise never fetch again. For a .lua file that means a chunk that silently
does nothing; for an asset it means getcustomasset producing an invalid content id, which
throws 'ContentId formatting failed' and kills the GUI. Both states used to survive every
retry, because everything that could have repaired them asked isfile and was told the file
was fine -- so the only remedy was reinstalling the script. ]]
local function hasContent(path)
	if not isfile(path) then return false end
	local ok, body = pcall(readfile, path)
	if not ok or type(body) ~= 'string' or body == '' then return false end
	if path:match('%.lua$') then
		local compileOk, chunk = pcall(loadstring, body, path)
		return compileOk and type(chunk) == 'function'
	end
	return true
end

local function downloadFile(path, func)
	if not (release.cacheReady and hasContent(path)) then
		local relPath = select(1, path:gsub('pistonware/', ''))
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				return game:HttpGet(projectRawUrl(relPath), true)
			end)
			if suc and res and res ~= '' and res ~= '404: Not Found' and (not path:find('%.lua$') or loadstring(res) ~= nil) then
				content = res
				break
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not content then
			local message = 'failed to download '..path..' after 4 attempts'
			reportError('source.download', message, nil, false)
			error(message, 2)
		end
		if path:find('%.lua$') then
			content = Watermark..'\n'..content
		end
		local wrote, writeError = pcall(writefile, path, content)
		if not wrote then
			reportError('source.cache.write', writeError, nil, false)
			error(writeError, 2)
		end
	end
	return (func or readfile)(path)
end

if not isDeveloper then
	shared.PistonwareDevLoadSource = function(path)
		return downloadFile(path)
	end
end

--[[ Every concurrent batch in this file joins through here.

The old code used `done.Event:Wait()` with no timeout, which parks the boot FOREVER if
a worker dies before firing -- and workers could die, because the progress callback they
called on their way out was not wrapped. That is the 'stuck on Injecting into ROBLOX' report:
not a slow download, a batch that lost a worker and a join that waits for it regardless.

Fixed at both ends, because either alone still leaves a hole: the callbacks are pcall'd at
their call sites now, AND this gives up on the clock no matter what killed the worker. A
batch that loses one costs the files that worker had left, not the session. ]]
local function joinBatch(isDone, seconds)
	local deadline = os.clock() + (seconds or 90)
	while not isDone() and os.clock() < deadline do
		task.wait(0.05)
	end
	return isDone()
end

--[[
	Resolve the branch through the small GitHub branch endpoint first. The recursive tree is an
	optional cache/update index, not the release-verification gate: GitHub can serve valid branch
	metadata while a recursive tree request is rate-limited or temporarily unavailable.

	The loader used to treat that tree failure as proof that the branch had no release. That made
	"branch main has no verified release" a false negative and prevented an otherwise valid boot.
	Once the branch endpoint returns a 40-character commit, every later raw-file request is pinned
	to that commit. A matching local marker remains the offline fallback when both metadata calls
	are unavailable.
]]
local repoTree, repoTreeTried, repoTreeDone
local repoTreeError
local function fetchRepoTree()
	if repoTreeTried then
		--[[ Joined, not returned. repoTreeTried is set on ENTRY, so a second caller arriving
		while the first request is still in flight used to be handed nil and read that as
		'no tree' -- silently skipping whatever it wanted the tree for. Harmless while the
		only concurrent caller was the update task, but the prefetch below makes a
		concurrent second caller the normal case. ]]
		if not repoTreeDone then
			joinBatch(function() return repoTreeDone end, 30)
		end
		return repoTree
	end
	repoTreeTried = true
	local ok, err = pcall(function()
		local httpService = cloneref(game:GetService('HttpService'))
		local body = httpService:JSONDecode(game:HttpGet('https://api.github.com/repos/'..PROJECT_REPO..'/git/trees/'..(release.sourceRef or release.branch)..'?recursive=1', true))
		if type(body) == 'table' and type(body.tree) == 'table' and type(body.sha) == 'string' then
			repoTree = body
			--[[ Handed to main.lua so its asset prefetch reads this instead of spending its own
			contents/ calls. It only needs the paths, and they are all in here already. ]]
			shared.PistonwareRepoTree = body
		end
	end)
	if not ok then
		repoTreeError = safeText(err)
		logger:warn('version.tree', 'could not resolve the selected branch tree', {error = repoTreeError, branch = release.branch})
		telemetry:report('loader_error', repoTreeError, {stage = 'version.tree', fatal = false})
	end
	repoTreeDone = true
	return repoTree
end

local function readReleaseMarker()
	if not isfile(RELEASE_FILE) then return nil end
	local ok, body = pcall(readfile, RELEASE_FILE)
	if not ok or type(body) ~= 'string' or body == '' then return nil end
	local decodedOk, decoded = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(body)
	end)
	return decodedOk and type(decoded) == 'table' and decoded or nil
end

local function validCommit(value)
	return type(value) == 'string' and #value == 40 and value:match('^%x+$') ~= nil
end

local branchCommit, branchCommitTried, branchCommitDone
local branchCommitError
local function fetchBranchCommit()
	if branchCommitTried then
		if not branchCommitDone then
			joinBatch(function() return branchCommitDone end, 30)
		end
		return branchCommit
	end
	branchCommitTried = true
	local ok, err = pcall(function()
		local httpService = cloneref(game:GetService('HttpService'))
		local body = httpService:JSONDecode(game:HttpGet(
			'https://api.github.com/repos/'..PROJECT_REPO..'/branches/'..release.branch, true))
		local commit = type(body) == 'table' and type(body.commit) == 'table' and body.commit.sha
		if validCommit(commit) then
			branchCommit = commit
		else
			branchCommitError = 'branch metadata did not contain a verified commit'
		end
	end)
	if not ok then
		branchCommitError = safeText(err)
		logger:warn('version.branch', 'could not resolve the selected branch', {error = branchCommitError, branch = release.branch})
		telemetry:report('loader_error', branchCommitError, {stage = 'version.branch', fatal = false})
	end
	branchCommitDone = true
	return branchCommit
end

local function markerMatches(marker)
	return type(marker) == 'table'
		and marker.schema == VERSION_SCHEMA
		and marker.channel == release.channel
		and marker.branch == release.branch
		and validCommit(marker.commit)
end

local function resolveRelease()
	local marker = readReleaseMarker()
	local commit = fetchBranchCommit()
	if validCommit(commit) then
		release.commit = commit
		release.sourceRef = commit
		release.version = release.channel..'@'..commit:sub(1, 12)
		release.resolved = true
		release.cacheReady = markerMatches(marker) and marker.commit == commit
			or false
		shared.PistonwareRelease = release
		logger:info('version.resolved', 'release selected', {
			channel = release.channel,
			branch = release.branch,
			version = release.version,
			cache = release.cacheReady and 'ready' or 'refresh'
		})
		return true
	end
	-- Keep the recursive tree as a compatibility fallback for hosts or API proxies that do not
	-- expose /branches/:name but do still expose git/trees/:name.
	local tree = fetchRepoTree()
	if tree and validCommit(tree.sha) then
		release.commit = tree.sha
		release.sourceRef = tree.sha
		release.version = release.channel..'@'..tree.sha:sub(1, 12)
		release.resolved = true
		release.cacheReady = markerMatches(marker) and marker.commit == tree.sha or false
		shared.PistonwareRelease = release
		logger:info('version.resolved', 'release selected from the repository tree', {
			channel = release.channel,
			branch = release.branch,
			version = release.version,
			cache = release.cacheReady and 'ready' or 'refresh'
		})
		return true
	end
	if markerMatches(marker) then
		release.commit = marker.commit
		release.sourceRef = marker.commit
		release.version = release.channel..'@'..marker.commit:sub(1, 12)
		release.resolved = true
		release.cacheReady = true
		shared.PistonwareRelease = release
		logger:warn('version.cached', 'using the last verified release because the branch tree was unavailable', {
			channel = release.channel,
			version = release.version
		})
		return true
	end
	return false, branchCommitError or repoTreeError or ('branch '..release.branch..' has no verified release')
end

local function persistReleaseMarker()
	if not release.resolved or type(release.commit) ~= 'string' then return false end
	local marker = {
		schema = VERSION_SCHEMA,
		channel = release.channel,
		branch = release.branch,
		commit = release.commit,
		version = release.version,
		savedAt = os.time()
	}
	local ok, err = pcall(function()
		writefile(RELEASE_FILE, jsonEncode(marker))
	end)
	if not ok then
		logger:warn('version.marker', 'could not persist the verified release marker', {error = err})
		telemetry:report('loader_error', err, {stage = 'version.marker', fatal = false})
		return false
	end
	release.cacheReady = true
	shared.PistonwareRelease = release
	return true
end

--[[ Shaped like the old contents/ response ({type = 'file', path = ...}) so the downloader below
did not have to change. Pinned by construction: a tree IS a snapshot, so there is no window
where the listing and the file contents disagree. ]]
local function fetchProfilesListing()
	local tree = fetchRepoTree()
	if not tree then return nil end
	local files = {}
	for _, v in tree.tree do
		local path = projectPath(v.path)
		if v.type == 'blob' and path:sub(1, 9) == 'profiles/' then
			table.insert(files, {type = 'file', path = path})
		end
	end
	if #files == 0 then return nil end
	return files
end

local function mergeGuiState(path, incoming)
	if not path:find('%.gui%.txt$') then return incoming end
	local ok, merged = pcall(function()
		local httpService = cloneref(game:GetService('HttpService'))
		local new = httpService:JSONDecode(incoming)
		if type(new) ~= 'table' then return incoming end
		if isfile(path) then
			local old = httpService:JSONDecode(readfile(path))
			if type(old) == 'table' then
				-- Top level: the shape the OLD gui wrote, kept for a repo copy still in it.
				if old.Profiles ~= nil then new.Profiles = old.Profiles end
				if old.Profile ~= nil then new.Profile = old.Profile end

				--[[
					And the shape guis/newgui.lua writes, which is what is on disk now.

					The point of this merge is that a config sync replaces the theme and window
					layout without costing the user the profiles they made themselves. The new
					GUI keeps that list at Categories.Profiles.List (see its vape:Save), not at
					the top level -- so preserving only the two fields above let the repo's copy
					overwrite it, and a sync silently emptied the Profiles tab of everything
					except the shipped configs. The GUI's own sync button carries both across
					for the same reason.
				]]
				local oldprofiles = type(old.Categories) == 'table' and old.Categories.Profiles or nil
				if type(oldprofiles) == 'table' then
					new.Categories = type(new.Categories) == 'table' and new.Categories or {}
					local newprofiles = type(new.Categories.Profiles) == 'table' and new.Categories.Profiles or {}
					new.Categories.Profiles = newprofiles
					if oldprofiles.List ~= nil then newprofiles.List = oldprofiles.List end
					if oldprofiles.ListEnabled ~= nil then newprofiles.ListEnabled = oldprofiles.ListEnabled end
				end
			end
		end
		return httpService:JSONEncode(new)
	end)
	return (ok and type(merged) == 'string') and merged or incoming
end

local function downloadProfilesListing(body, commit, onProgress)
	local files = {}
	for _, v in body do
		if v.type == 'file' then
			table.insert(files, v)
		end
	end
	local completed, failed, total = 0, 0, #files
	for _, v in files do
		local relPath = ({projectPath(v.path):gsub(' ', '%%20')})[1]
		task.spawn(function()
			local succeeded = false
			if commit then
				pcall(function()
					for attempt = 1, 4 do
						local suc, res = pcall(function()
							return game:HttpGet(projectRawUrl(relPath, commit or release.sourceRef), true)
						end)
						if suc and res and res ~= '' and res ~= '404: Not Found' then
							writefile('pistonware/'..relPath, mergeGuiState('pistonware/'..relPath, res))
							succeeded = true
							break
						end
						if attempt < 4 then
							task.wait(attempt)
						end
					end
				end)
			else
				succeeded = pcall(downloadFile, 'pistonware/'..relPath)
			end
			if not succeeded then failed += 1 end
			--[[ Counted first and reported second, both guarded: this worker's only remaining job
			is to be counted, and a throwing progress callback used to stop that happening. ]]
			completed += 1
			if onProgress then
				pcall(onProgress, completed, total)
			end
		end)
	end
	joinBatch(function() return completed >= total end)
	return completed == total and failed == 0
end

--[[ Derived from the tree already in hand, so the sync check costs no request of its own. The
fingerprint changes only when a profile changes and stays identical otherwise; the blob shas
give exactly; djb2 over them keeps the stored value one short line instead of growing with
the profile count. The 'p1-' prefix marks the scheme, so the migration in Step 2b can tell
one of these from the 40-char git sha the old code wrote. ]]
local function profilesFingerprint()
	local tree = fetchRepoTree()
	if not tree then return nil end
	local parts = {}
	for _, v in tree.tree do
		local path = projectPath(v.path)
		if v.type == 'blob' and path:sub(1, 9) == 'profiles/' then
			table.insert(parts, path..':'..tostring(v.sha))
		end
	end
	if #parts == 0 then return nil end
	table.sort(parts)
	local joined = table.concat(parts, '\n')
	local h = 5381
	for i = 1, #joined do
		h = (h * 33 + string.byte(joined, i)) % 4294967296
	end
	return ('p1-%08x'):format(h)
end

local function updateCachedFiles(onProgress)
	local httpService = cloneref(game:GetService('HttpService'))

	--[[ The tree carries its own sha, so this is the whole API budget -- and it is memoised, so
	the profiles listing and fingerprint below ride the same response. ]]
	local tree = fetchRepoTree()
	if not tree then return end
	local headSha = tree.sha

	local manifest = {}
	pcall(function()
		if isfile('pistonware/filecheck.json') then
			local decoded = httpService:JSONDecode(readfile('pistonware/filecheck.json'))
			if type(decoded) == 'table' then
				manifest = decoded
			end
		end
	end)

	local remote = {}
	for _, v in tree.tree do
		local path = projectPath(v.path)
		if v.type == 'blob' and path:sub(-4) == '.lua' then
			remote[path] = v.sha
		end
	end

	local function managed(localPath)
		if not isfile(localPath) then return false end
		if PUBLIC_BUILD then return true end
		return readfile(localPath):sub(1, #Watermark) == Watermark
	end

	--[[ Only files already cached get refreshed here -- everything else keeps downloading on
	demand, and is picked up by this pass on the session after it first appears. ]]
	local toUpdate = {}
	for path, sha in remote do
		local localPath = 'pistonware/'..path
		if manifest[path] ~= sha and managed(localPath) then
			table.insert(toUpdate, path)
		end
	end

	local changed = false

	if not tree.truncated then
		for path in manifest do
			if not remote[path] then
				pcall(function()
					local localPath = 'pistonware/'..path
					if managed(localPath) then
						delfile(localPath)
					end
				end)
				manifest[path] = nil
				changed = true
			end
		end
	end

	local completed, total = 0, #toUpdate
	if total > 0 then
		for _, path in toUpdate do
			task.spawn(function()
				for attempt = 1, 4 do
					local suc, res = pcall(function()
							return game:HttpGet(projectRawUrl(select(1, path:gsub(' ', '%%20')), headSha), true)
					end)
					--[[ compile check: never overwrite a working cached file with an error page ]]
					if suc and res and res ~= '' and res ~= '404: Not Found' and loadstring(res) ~= nil then
						pcall(writefile, 'pistonware/'..path, Watermark..'\n'..res)
						manifest[path] = remote[path]
						changed = true
						break
					end
					if attempt < 4 then
						task.wait(attempt)
					end
				end
				--[[ Counted first, reported second, the report guarded. See joinBatch: a throwing
				progress callback here used to strand the join for the rest of the session. ]]
				completed += 1
				if onProgress then
					pcall(onProgress, completed, total)
				end
			end)
		end
		joinBatch(function() return completed >= total end)
	end

	if changed then
		pcall(writefile, 'pistonware/filecheck.json', httpService:JSONEncode(manifest))
	end
end

--[[
	Loader console
	--------------
	A fake terminal window that stands in for the executor console while pistonware boots.
	The piston face is drawn one row at a time as the boot progresses, so the art is only
	ever complete at the same moment the status flips to '> DONE'.
]]

local PistonFace = {
	'******=============******++++++=============******',
	'******=============******++++++=============******',
	'******=============******++++++=============******',
	'++++++=============++++++===================++++++',
	'++++++=============++++++===================++++++',
	'++++++=============++++++===================++++++',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::######:::::::++++++======******:::::::::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'------++++++                         =======------',
	'------++++++                         =======------',
	'------++++++                         =======------',
	'::::::=============      ++++++++++++=======::::::',
	'::::::=============      ++++++++++++=======::::::',
	'::::::=============      ++++++++++++=======::::::',
	'::::::------:::::::------::::::------:::::::::::::',
	'::::::------:::::::------::::::------:::::::::::::',
	'::::::------:::::::------::::::------:::::::::::::'
}

--[[ Every offset below is authored against the base window and scaled as a whole by the
UIScale, so the layout can't drift apart on other resolutions. ]]
local WindowWidth = 1000
local TitleBarHeight = 44
local ContentPadding = 26
--[[ Rows are packed slightly tighter than the glyph size so the 25-row face stays a sane
height. Text is never clipped by its own frame in Roblox, so the 2px per row overlaps
harmlessly. ]]
local AsciiTextSize = 20
local AsciiLineHeight = 18

--[[ The rows under the art are positioned off the art itself, so a taller or shorter face
pushes them (and the bottom of the window) down instead of colliding with them. ]]
local AsciiTop = TitleBarHeight + 16
local StatusY = AsciiTop + #PistonFace * AsciiLineHeight + 16
local LineY = StatusY + 32
local AnswersY = LineY + 30
local WindowHeight = AnswersY + 34 + 30 + 22 + 16

local Palette = {
	Window = Color3.fromRGB(10, 10, 10),
	TitleBar = Color3.fromRGB(38, 38, 38),
	Border = Color3.fromRGB(52, 52, 52),
	Title = Color3.fromRGB(232, 232, 232),
	Glyph = Color3.fromRGB(190, 190, 190),
	Accent = Color3.fromRGB(240, 122, 31),
	Line = Color3.fromRGB(237, 237, 237),
	Footer = Color3.fromRGB(110, 110, 110),
	ButtonIdle = Color3.fromRGB(200, 200, 200),
	ButtonBorder = Color3.fromRGB(60, 60, 60),
	Error = Color3.fromRGB(225, 80, 70),
}

--[[ Ascii shading: the art is one colour in a real terminal, but the piston only reads as a
face if the solid blocks sit brighter than the dithered background, so each glyph class
gets its own tone. ]]
local AsciiShades = {
	['@'] = '#F2F2F2',
	['#'] = '#E4E4E4',
	['%'] = '#D2D2D2',
	['*'] = '#A6A6A6',
	['+'] = '#8C8C8C',
	['='] = '#6B6B6B',
	['-'] = '#5C5C5C',
	[':'] = '#4A4A4A',
	['.'] = '#4A4A4A'
}

--[[ Cancelling the loader has to leave nothing behind that THIS boot created, so on a fresh
install the whole folder is wiped. On an install that already existed before this run the
wipe is skipped entirely -- the folder holds the user's custom profiles, and cancelling a
reinject must never cost them those; only an explicit reinstall (reinstall.lua) deletes an
existing install. delfolder already recurses on the executors that have it; the manual walk
is for the ones that only ship delfile. ]]
--[[ Frees the session-wide flags this boot is holding, with ownership checks so a newer boot
cannot have its flags cleared by an older one. ]]
local function releaseBoot()
	if shared.PistonwareLoaderBoot ~= bootStamp then return end
	shared.PistonwareLoaderBoot = nil
	shared.vapereload = nil
end

local freshInstall = false
local function deleteInstall()
	--[[ every cancel/abort path comes through here, so a cancelled boot immediately frees the
	duplicate-execution guard for the next manual run ]]
	releaseBoot()
	if not freshInstall then return end
	pcall(function()
		if delfolder then
			delfolder('pistonware')
			return
		end
		local function purge(folder)
			for _, path in listfiles(folder) do
				if isfolder(path) then
					purge(path)
				elseif delfile then
					delfile(path)
				end
			end
		end
		purge('pistonware')
	end)
end

local function asciiRichText(line)
	local out = {}
	local runColor, runStart = nil, 1
	local function flush(stop)
		if stop < runStart then return end
		local chunk = line:sub(runStart, stop)
		table.insert(out, runColor and ('<font color="'..runColor..'">'..chunk..'</font>') or chunk)
	end
	for i = 1, #line do
		local color = AsciiShades[line:sub(i, i)]
		if i > 1 and color ~= runColor then
			flush(i - 1)
			runStart = i
		end
		runColor = color
	end
	flush(#line)
	return table.concat(out)
end

local function createConsole()
	local tweenService = cloneref(game:GetService('TweenService'))
	local inputService = cloneref(game:GetService('UserInputService'))
	local playersService = cloneref(game:GetService('Players'))

		--[[ Whatever a previous run left standing goes first. Several Fail() paths through this
		file return without destroying the console so the message can be read, and each leaves behind
		a GUI tree, three service-level connections and the reveal thread below. Re-executing
		is the natural response to all of them, so without this the leak grows once per attempt
		rather than being replaced. ]]
	pcall(function()
		if type(shared.PistonwareLoaderTeardown) == 'function' then
			shared.PistonwareLoaderTeardown()
		end
	end)

	--[[ Connections on services and the camera, which outlive screen:Destroy() -- unlike the
	button and titlebar ones, which are parented into the GUI and go with it. ]]
	local connections = {}
	local function track(connection)
		table.insert(connections, connection)
		return connection
	end

	local screen = Instance.new('ScreenGui')
	screen.Name = 'PistonwareLoader'
	screen.DisplayOrder = 999999999
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	local parented = pcall(function()
		screen.Parent = (gethui and gethui()) or cloneref(game:GetService('CoreGui'))
	end)
	if not parented then
		pcall(function()
			screen.Parent = playersService.LocalPlayer:FindFirstChildOfClass('PlayerGui')
		end)
	end

	local window = Instance.new('Frame')
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.fromOffset(WindowWidth, WindowHeight)
	window.BackgroundColor3 = Palette.Window
	window.BorderSizePixel = 0
	--[[ so minimising can roll the console up behind its own titlebar ]]
	window.ClipsDescendants = true
	window.Parent = screen
	local windowCorner = Instance.new('UICorner')
	windowCorner.CornerRadius = UDim.new(0, 10)
	windowCorner.Parent = window
	local windowStroke = Instance.new('UIStroke')
	windowStroke.Color = Palette.Border
	windowStroke.Thickness = 1
	windowStroke.Parent = window

	--[[ One UIScale drives the whole window, so the console keeps its proportions from a phone up
	to a 4K monitor: full size at 1080p, shrunk to fit anything smaller. ]]
	local uiscale = Instance.new('UIScale')
	uiscale.Parent = window
	local camera = workspace.CurrentCamera

	--[[ Window state, the way a desktop WM handles it: minimise rolls the window up into its own
	titlebar (there is no taskbar to minimise *to* here, so shading is the recoverable
	equivalent) and maximise fills the viewport, both toggling back on a second click. ]]
	local minimized, maximized = false, false
	local restorePosition = window.Position

	local function applyWindowState(animate)
		local viewport = camera and camera.ViewportSize or Vector2.new(WindowWidth, WindowHeight)
		--[[ Sizes are pre-UIScale, so divide by the scale to land on the viewport once scaled. ]]
		local width = maximized and (viewport.X / uiscale.Scale) or WindowWidth
		local height = maximized and (viewport.Y / uiscale.Scale) or WindowHeight
		local size = UDim2.fromOffset(width, minimized and TitleBarHeight or height)
		local position = maximized and UDim2.fromScale(0.5, 0.5) or restorePosition
		if animate then
			tweenService:Create(window, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {Size = size, Position = position}):Play()
		else
			window.Size, window.Position = size, position
		end
	end

	local function applyScale()
		local viewport = camera and camera.ViewportSize or Vector2.new(WindowWidth, WindowHeight)
		if viewport.X <= 0 or viewport.Y <= 0 then return end
		local fit = math.min(viewport.X * 0.94 / WindowWidth, viewport.Y * 0.92 / WindowHeight)
		uiscale.Scale = math.clamp(math.min(fit, viewport.Y / 1080), 0.25, 1.4)
		--[[ a maximised window has to keep tracking the viewport it is filling ]]
		applyWindowState(false)
	end
	applyScale()
	if camera then
		track(camera:GetPropertyChangedSignal('ViewportSize'):Connect(applyScale))
	end

	local titlebar = Instance.new('Frame')
	titlebar.Size = UDim2.new(1, 0, 0, TitleBarHeight)
	titlebar.BackgroundColor3 = Palette.TitleBar
	titlebar.BorderSizePixel = 0
	titlebar.Parent = window
	local titlebarCorner = Instance.new('UICorner')
	titlebarCorner.CornerRadius = UDim.new(0, 10)
	titlebarCorner.Parent = titlebar
	--[[ Squares off the bottom two corners the UICorner above rounded. ]]
	local titlebarFill = Instance.new('Frame')
	titlebarFill.Position = UDim2.new(0, 0, 1, -10)
	titlebarFill.Size = UDim2.new(1, 0, 0, 10)
	titlebarFill.BackgroundColor3 = Palette.TitleBar
	titlebarFill.BorderSizePixel = 0
	titlebarFill.Parent = titlebar

	local icon = Instance.new('TextLabel')
	icon.Position = UDim2.fromOffset(10, 10)
	icon.Size = UDim2.fromOffset(24, 24)
	icon.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
	icon.BorderSizePixel = 0
	icon.Text = '>_'
	icon.TextColor3 = Palette.Accent
	icon.TextSize = 13
	icon.Font = Enum.Font.Code
	icon.Parent = titlebar
	local iconCorner = Instance.new('UICorner')
	iconCorner.CornerRadius = UDim.new(0, 5)
	iconCorner.Parent = icon

	local title = Instance.new('TextLabel')
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -220, 1, 0)
	title.Position = UDim2.fromOffset(110, 0)
	title.Text = './pistonware-loader'
	title.TextColor3 = Palette.Title
	title.TextSize = 18
	title.Font = Enum.Font.Code
	title.Parent = titlebar

	local closed, aborted = false, false
	local function destroy()
		if closed then return end
		--[[ Set first: the reveal thread and every wait loop below key off it, so they stop
		even if destroying the GUI throws. ]]
		closed = true
		for _, connection in connections do
			pcall(function() connection:Disconnect() end)
		end
		table.clear(connections)
		pcall(function() screen:Destroy() end)
		--[[ Only clear the handle if it is still ours; a newer console may already own it. ]]
		if shared.PistonwareLoaderTeardown == destroy then
			shared.PistonwareLoaderTeardown = nil
		end
	end

	--[[ Closing the window by hand is a cancel, not a dismissal: the boot stops at the next
	checkpoint, and on a first install everything the run wrote is deleted so a half-finished
	install can't be left behind (and no config gets silently picked for you). On an existing
	install deleteInstall refuses to wipe, so cancelling a reinject just stops the boot. ]]
	local function cancel()
		if aborted then return end
		aborted = true
		destroy()
		deleteInstall()
	end

	--[[ Chrome glyphs are drawn from thin rotated bars rather than typed: Roblox's Code font has
	no chevron glyphs, and a literal 'v'/'^' reads as text sitting next to the title instead
	of as window controls. ]]
	local function drawGlyph(parent, kind)
		local bars = {}
		local function bar(length, x, y, rotation)
			local piece = Instance.new('Frame')
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.Position = UDim2.fromOffset(x, y)
			piece.Size = UDim2.fromOffset(length, 2)
			piece.BackgroundColor3 = Palette.Glyph
			piece.BorderSizePixel = 0
			piece.Rotation = rotation
			piece.Parent = parent
			local corner = Instance.new('UICorner')
			corner.CornerRadius = UDim.new(0, 1)
			corner.Parent = piece
			table.insert(bars, piece)
		end
		--[[ Arms meet at the centre of the 34x34 button: a chevron is two 10px bars at +-45
		degrees, the close is the same two bars crossed. ]]
		if kind == 'minimize' then
			bar(10, 13.5, 17, 45)
			bar(10, 20.5, 17, -45)
		elseif kind == 'maximize' then
			bar(10, 13.5, 17, -45)
			bar(10, 20.5, 17, 45)
		else
			bar(15, 17, 17, 45)
			bar(15, 17, 17, -45)
		end
		return bars
	end

	--[[ Assigned once the footer exists; the window buttons below are built before it. ]]
	local applyChromeVisibility = function() end

	for index, kind in {'minimize', 'maximize', 'close'} do
		local button = Instance.new('TextButton')
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.new(1, -14 - (3 - index) * 38, 0.5, 0)
		button.Size = UDim2.fromOffset(34, 34)
		button.BackgroundColor3 = Color3.new(1, 1, 1)
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.Modal = true
		button.Text = ''
		button.Parent = titlebar
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		local bars = drawGlyph(button, kind)
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0.9
			for _, piece in bars do
				piece.BackgroundColor3 = kind == 'close' and Palette.Error or Color3.new(1, 1, 1)
			end
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 1
			for _, piece in bars do
				piece.BackgroundColor3 = Palette.Glyph
			end
		end)

		button.MouseButton1Click:Connect(function()
			if kind == 'close' then
				cancel()
			elseif kind == 'minimize' then
				minimized = not minimized
				applyWindowState(true)
				applyChromeVisibility()
			else
				--[[ maximising an already rolled-up window unrolls it, as a WM would ]]
				maximized = not maximized
				minimized = false
				applyWindowState(true)
				applyChromeVisibility()
			end
		end)
	end

	--[[ Drag by the titlebar. Offsets live in screen space (the UIScale only rescales children),
	so the delta can be applied straight to the window position. ]]
	local dragging, dragStart, dragOrigin
	titlebar.InputBegan:Connect(function(input)
		--[[ a maximised window is pinned to the viewport; unmaximise it to move it ]]
		if maximized then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, dragOrigin = true, input.Position, window.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	track(inputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(dragOrigin.X.Scale, dragOrigin.X.Offset + delta.X, dragOrigin.Y.Scale, dragOrigin.Y.Offset + delta.Y)
			--[[ so unmaximising and unminimising both come back to where it was left ]]
			restorePosition = window.Position
		end
	end))

	local ascii = Instance.new('Frame')
	ascii.BackgroundTransparency = 1
	ascii.Position = UDim2.fromOffset(ContentPadding, AsciiTop)
	ascii.Size = UDim2.fromOffset(WindowWidth - ContentPadding * 2, #PistonFace * AsciiLineHeight)
	ascii.Parent = window

	local rows = {}
	for index, line in PistonFace do
		local label = Instance.new('TextLabel')
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(0, (index - 1) * AsciiLineHeight)
		label.Size = UDim2.new(1, 0, 0, AsciiLineHeight)
		label.RichText = true
		label.Text = asciiRichText(line)
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextSize = AsciiTextSize
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTransparency = 1
		label.Font = Enum.Font.Code
		label.Visible = false
		label.Parent = ascii
		rows[index] = label
	end

	local status = Instance.new('TextLabel')
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(ContentPadding, StatusY)
	status.Size = UDim2.new(1, -ContentPadding * 2, 0, 28)
	status.RichText = true
	status.TextColor3 = Palette.Line
	status.TextSize = 22
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Font = Enum.Font.Code
	status.Parent = window

	local line = Instance.new('TextLabel')
	line.BackgroundTransparency = 1
	line.Position = UDim2.fromOffset(ContentPadding, LineY)
	line.Size = UDim2.new(1, -ContentPadding * 2, 0, 24)
	line.Text = ''
	line.TextColor3 = Palette.Line
	line.TextSize = 17
	line.TextXAlignment = Enum.TextXAlignment.Left
	line.Font = Enum.Font.Code
	line.Parent = window

	--[[ Answer buttons sit on the row directly under the question and are reused for every
	prompt, so answering one question simply rewrites the line above them. ]]
	local answers = Instance.new('Frame')
	answers.BackgroundTransparency = 1
	answers.Position = UDim2.fromOffset(ContentPadding, AnswersY)
	answers.Size = UDim2.new(1, -ContentPadding * 2, 0, 34)
	answers.Visible = false
	answers.Parent = window
	local answersLayout = Instance.new('UIListLayout')
	answersLayout.SortOrder = Enum.SortOrder.LayoutOrder
	answersLayout.FillDirection = Enum.FillDirection.Horizontal
	answersLayout.Padding = UDim.new(0, 12)
	answersLayout.Parent = answers

	--[[ Explains what the hovered answer actually does. It rides in the same list layout as the
	buttons (LayoutOrder puts it last, after however many there are) so it lands on their row
	with the same gap between, and a hidden child takes no space -- the row closes up around
	it while nothing is hovered. Ask() only clears TextButtons, so this survives each question. ]]
	local tooltip = Instance.new('TextLabel')
	tooltip.Name = 'Tooltip'
	tooltip.LayoutOrder = 999
	tooltip.AutomaticSize = Enum.AutomaticSize.X
	tooltip.Size = UDim2.fromOffset(0, 34)
	tooltip.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	tooltip.BorderSizePixel = 0
	tooltip.Visible = false
	tooltip.Text = ''
	tooltip.TextColor3 = Palette.Line
	tooltip.TextSize = 15
	tooltip.Font = Enum.Font.Code
	tooltip.Parent = answers
	local tooltipPadding = Instance.new('UIPadding')
	tooltipPadding.PaddingLeft = UDim.new(0, 12)
	tooltipPadding.PaddingRight = UDim.new(0, 12)
	tooltipPadding.Parent = tooltip
	local tooltipCorner = Instance.new('UICorner')
	tooltipCorner.CornerRadius = UDim.new(0, 4)
	tooltipCorner.Parent = tooltip
	local tooltipStroke = Instance.new('UIStroke')
	tooltipStroke.Color = Palette.ButtonBorder
	tooltipStroke.Thickness = 1
	tooltipStroke.Parent = tooltip

	local footer = Instance.new('TextLabel')
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.BackgroundTransparency = 1
	footer.Position = UDim2.new(0, ContentPadding, 1, -16)
	footer.Size = UDim2.new(1, -ContentPadding * 2, 0, 22)
	--[[ Touch-only devices have no ctrl key, so point them at the titlebar button instead. ]]
	footer.Text = (inputService.TouchEnabled and not inputService.KeyboardEnabled) and 'Tap [x] to exit' or 'Press [CTRL+C] to exit'
	footer.TextColor3 = Palette.Footer
	footer.TextSize = 17
	footer.TextXAlignment = Enum.TextXAlignment.Left
	footer.Font = Enum.Font.Code
	footer.Parent = window

	--[[ An opt-out for the question currently being asked, in the bottom-right corner opposite
	the footer. Greyed out on purpose: it is the answer nobody should click by accident.
	Ask() shows it only when the caller passes one, and hides it again afterwards. ]]
	local optOutButton = Instance.new('TextButton')
	optOutButton.AnchorPoint = Vector2.new(1, 1)
	optOutButton.BackgroundTransparency = 1
	optOutButton.Position = UDim2.new(1, -ContentPadding, 1, -16)
	optOutButton.Size = UDim2.fromOffset(0, 22)
	optOutButton.AutomaticSize = Enum.AutomaticSize.X
	optOutButton.AutoButtonColor = false
	optOutButton.Modal = true
	optOutButton.Visible = false
	optOutButton.Text = ''
	optOutButton.TextColor3 = Palette.Footer
	optOutButton.TextSize = 17
	optOutButton.TextXAlignment = Enum.TextXAlignment.Right
	optOutButton.Font = Enum.Font.Code
	optOutButton.Parent = window
	optOutButton.MouseEnter:Connect(function()
		optOutButton.TextColor3 = Palette.Line
	end)
	optOutButton.MouseLeave:Connect(function()
		optOutButton.TextColor3 = Palette.Footer
	end)

	--[[ The footer and the opt-out are anchored to the bottom edge, so a rolled-up window would
	leave them floating over the titlebar. Hidden while minimised. ]]
	local optOutActive = false
	applyChromeVisibility = function()
		footer.Visible = not minimized
		optOutButton.Visible = optOutActive and not minimized
	end

	track(inputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.C and inputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			cancel()
		end
	end))

	local revealed, revealTarget = 0, 0
	--[[ Set by Halt() on the paths that leave the window up for reading but have no more rows
	to draw. Without it this thread outlives the boot at ~14Hz for the rest of the session. ]]
	local halted = false
	task.spawn(function()
		while not closed and not halted do
			if revealed < revealTarget then
				revealed += 1
				local row = rows[revealed]
				row.Visible = true
				tweenService:Create(row, TweenInfo.new(0.18), {TextTransparency = 0}):Play()
			end
			task.wait(0.07)
		end
	end)

	--[[ One flat terminal button shared by the answer row Ask() builds. ]]
	local function answerButton(text, width, order)
		local button = Instance.new('TextButton')
		--[[ keeps the buttons in the order given, ahead of the tooltip that trails them ]]
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(width, 34)
		button.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		--[[ Frees the touch cursor so the button is tappable on phones (where input would
		otherwise be locked to the game). ]]
		button.Modal = true
		button.Text = text
		button.TextColor3 = Palette.ButtonIdle
		button.TextSize = 17
		button.Font = Enum.Font.Code
		button.Parent = answers
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = button
		local stroke = Instance.new('UIStroke')
		stroke.Color = Palette.ButtonBorder
		stroke.Thickness = 1
		stroke.Parent = button
		button.MouseEnter:Connect(function()
			stroke.Color = Palette.Accent
			button.TextColor3 = Palette.Accent
		end)
		button.MouseLeave:Connect(function()
			stroke.Color = Palette.ButtonBorder
			button.TextColor3 = Palette.ButtonIdle
		end)
		return button
	end

	--[[ The controls that Ask() puts on the answer row are cleared between prompts. The tooltip
	label shares the frame and has to survive, hence the class test rather than a blanket
	ClearAllChildren. ]]
	local function clearAnswers()
		for _, child in answers:GetChildren() do
			if child:IsA('TextButton') then
				child:Destroy()
			end
		end
	end

	local console = {}

	--[[ `chevron` is the glyph in front of the status word. It points forward ('>') for every
	step of the boot itself, and backward ('<') for the one phase that
	is holding the boot up rather than advancing it. Escaped, since the label is RichText. ]]
	function console:SetStatus(text, color, chevron)
		status.Text = '<font color="#9E9E9E">'..(chevron == '<' and '&lt;' or '&gt;')..'</font> <font color="'..(color or '#F07A1F')..'">'..text..'</font>'
	end

	function console:SetLine(text, color)
		line.Text = text
		line.TextColor3 = color or Palette.Line
	end

	--[[ alpha is how far through the boot we are; the face is drawn to match, one row at a time.
	Clamped upwards only: a late progress report from a background step must never pull rows
	back off the face (nothing here ever un-boots). ]]
	function console:SetProgress(alpha)
		local count = math.clamp(math.floor(alpha * #PistonFace + 0.5), 0, #PistonFace)
		revealTarget = math.max(revealTarget, count)
	end

	function console:IsAborted()
		return aborted
	end

	--[[ Asks a question on the output line, waits for one of the buttons underneath it, then
	clears the line again so the next question can take its place. `fallback` is returned if
	the loader is closed or the timeout elapses -- a missed click must never hang injection. ]]
	function console:Ask(question, buttons, timeoutSeconds, fallback, optOut)
		if closed then return fallback end
		self:SetLine(question)
		clearAnswers()

		tooltip.Visible = false

		local choice
		--[[ `optOut` is one more answer, {text, key, tooltip}, drawn in the corner instead of on the
		row. Its connections are dropped when the question ends so the next Ask starts clean. ]]
		local optOutConnections = {}
		if optOut then
			optOutButton.Text = optOut.text
			optOutButton.TextColor3 = Palette.Footer
			table.insert(optOutConnections, optOutButton.MouseButton1Click:Connect(function()
				choice = optOut.key
			end))
			if optOut.tooltip then
				table.insert(optOutConnections, optOutButton.MouseEnter:Connect(function()
					tooltip.Text = optOut.tooltip
					tooltip.Visible = true
				end))
				table.insert(optOutConnections, optOutButton.MouseLeave:Connect(function()
					tooltip.Visible = false
				end))
			end
			optOutActive = true
			applyChromeVisibility()
		end
		for index, def in buttons do
			local button = answerButton(def.text, 132, index)
			if def.tooltip then
				button.MouseEnter:Connect(function()
					tooltip.Text = def.tooltip
					tooltip.Visible = true
				end)
				button.MouseLeave:Connect(function()
					tooltip.Visible = false
				end)
			end
			button.MouseButton1Click:Connect(function()
				choice = def.key
			end)
		end
		answers.Visible = true

		local timeout = os.clock() + (timeoutSeconds or 60)
		repeat task.wait() until choice ~= nil or closed or os.clock() > timeout
		answers.Visible = false
		optOutActive = false
		applyChromeVisibility()
		for _, connection in optOutConnections do
			connection:Disconnect()
		end
		clearAnswers()
		tooltip.Visible = false
		self:SetLine('')
		if choice == nil then
			return fallback
		end
		return choice
	end

	--[[ Draws whatever rows are still missing, and only once the face is whole flips the header
	to '> DONE' and counts the window out. ]]
	function console:Finish(message, seconds)
		if closed then return end
		self:SetProgress(1)
		local drawn = os.clock() + 2
		repeat task.wait() until revealed >= #PistonFace or closed or os.clock() > drawn
		--[[ the last row is still fading in when the counter hits the end ]]
		task.wait(0.2)
		if closed then return end
		self:SetStatus('DONE')
		seconds = seconds or 5
		local deadline = os.clock() + seconds
		task.spawn(function()
			while not closed do
				local left = math.max(0, math.ceil(deadline - os.clock()))
				self:SetLine(message..' Loader will close in '..left..'s.')
				if left <= 0 then break end
				task.wait(0.2)
			end
			destroy()
		end)
	end

	--[[ Stops the reveal thread without taking the window down, for the paths that end the boot
	but still want the message on screen. Everything already drawn stays drawn. ]]
	function console:Halt()
		halted = true
	end

	function console:Fail(err)
		if closed then return end
		self:SetStatus('FAILED', '#E15046')
		--[[ Executor errors carry absolute file paths that run off the right edge on a single
		line. Nothing is going to be asked at this point, so the output line is allowed to
		wrap down through the space the answer row was holding. ]]
		line.TextWrapped = true
		line.TextYAlignment = Enum.TextYAlignment.Top
		line.Size = UDim2.new(1, -ContentPadding * 2, 0, AnswersY + 34 - LineY)
		self:SetLine(err, Palette.Error)
		--[[ Nothing further is drawn after a failure, so the thread has no work left. ]]
		self:Halt()
	end

	--[[ Published so the next execution can tear this console down before building its own. ]]
	shared.PistonwareLoaderTeardown = destroy

	return console
end

--[[ Same surface as the console, wired to nothing. Reloads are not user-initiated -- the queued
teleport script, the GUI's reinject buttons -- so they run the same boot with no window over
the game, and every call site below stays identical instead of guarding each one. ]]
local function createHeadlessConsole()
	local console = {}
	function console:SetStatus() end
	function console:SetLine() end
	function console:SetProgress() end
	function console:Finish() end
	function console:Fail() end
	function console:Halt() end
	function console:IsAborted() return false end
	--[[ unattended, so a question can only answer with whatever the timeout would have picked ]]
	function console:Ask(question, buttons, timeoutSeconds, fallback)
		return fallback
	end
	return console
end

--[[ shared.vapereload marks a run that something else started rather than a manual execution.
Read once here: it is cleared after main.lua has had its look at it (see the bottom of this
file), because nothing else clears it and a stale true would hide the console from every
later manual execution in the session. ]]
local isReload = shared.vapereload and true or false

local console
local consoleOk, consoleResult = xpcall(function()
	return isReload and createHeadlessConsole() or createConsole()
end, errorTrace)
if consoleOk then
	console = consoleResult
else
	console = createHeadlessConsole()
	stopExecution(console, 'console.create', consoleResult, consoleResult)
	return
end
do
	local unsupported = {'xeno', 'solara'}
	local executorName = ''
	pcall(function()
		executorName = identifyexecutor and identifyexecutor() or ''
	end)
	local lowered = tostring(executorName):lower()
	for _, name in unsupported do
		if lowered:find(name, 1, true) then
			local message = 'Unsupported executor ('..tostring(executorName)..'), please look in the #supported-executors channel for more info.'
			console:SetStatus('ERROR', '#E15046')
			console:SetLine(message, Palette.Error)
			stopExecution(console, 'executor.unsupported', message, nil, message)
			return
		end
	end
end
logger:bindConsole(console)
logger:info('console.ready', isReload and 'headless console ready' or 'console ready', {reload = isReload})
console:SetStatus('INJECTING')
console:SetLine('Injecting into ROBLOX...')
console:SetProgress(0.12)

--[[ Decided before the folders are created, while 'did this run create the install' is still
observable. ]]
local foldersOk, foldersError = xpcall(function()
	freshInstall = not isfolder('pistonware')
	for _, folder in {'pistonware', 'pistonware/games', 'pistonware/profiles', 'pistonware/assets', 'pistonware/libraries', 'pistonware/guis'} do
		if not isfolder(folder) then
			makefolder(folder)
		end
	end
end, errorTrace)
	if not foldersOk then
	stopExecution(console, 'filesystem.setup', foldersError, foldersError)
	return
	end
	markPistonwareBufferFilesystemReady()
	logger:addFile('pistonware/loader.log')
telemetry:addFile('pistonware/loader_telemetry.jsonl')

local releaseOk, releaseError = resolveRelease()
if not releaseOk then
	stopExecution(console, 'version.resolve', releaseError, errorTrace(releaseError))
	return
end
console:SetLine(('Loading %s (%s)...'):format(release.channel, release.version))

--[[ Step 1: hold here until ROBLOX itself is ready. Everything after this touches game state
(or hands off to main.lua, which does), so the shared.Vape* flags the injecting loadstring
sets have to be in place and the place has to be loaded before we move on.
Step 1b runs CONCURRENTLY with Step 1, not after it.

These two phases have nothing to do with each other: waiting on Roblox is pure dead time
(seconds of it when someone injects at the loading screen) and the update check is pure
network. Run in sequence, the boot paid for both. Started here, the update check happens
inside the wait it used to follow, and on a warm cache it is finished before Roblox is.

Nothing in updateCachedFiles touches game state, which is what made the old ordering
necessary in the first place -- it reads a GitHub tree and writes files into pistonware/.
Both folders and release metadata are already behind us, so the startup ordering is intact. ]]
local updateDone = isReload or isDeveloper
if not updateDone then
	task.spawn(function()
		local updateOk, updateError = xpcall(function()
			return updateCachedFiles(function(completed, total)
				console:SetLine('Updating files ('..completed..'/'..total..')...')
				console:SetProgress(0.4 + 0.06 * (completed / math.max(total, 1)))
			end)
		end, errorTrace)
		if not updateOk then
			stopExecution(console, 'cache.update', updateError, updateError)
		end
		updateDone = true
	end)
else
	--[[ Skipping the update check is not the same as needing no tree. The profile-sync check in
	Step 2b calls profilesFingerprint() -> fetchRepoTree() either way, and with the update
	task never started that call is COLD -- a synchronous, unbounded api.github.com request
	made on the boot thread, while the console still reads 'Injecting into ROBLOX...' and
	nothing on screen changes for the duration. That is a stall the public build does not
	have, because there the update task has already warmed the memo by the time Step 2b runs.

	Warmed here instead, inside the game:IsLoaded wait below, so Step 2b reads a finished
	memo. Nothing joins this: fetchRepoTree parks a late caller on its own bounded join now,
	and every consumer already treats a missing tree as 'skip the check'.

	Not started on a reload -- Step 2b is skipped outright there (`not isReload`), so the
	request would be pure cost. ]]
	if not isReload then
		task.spawn(fetchRepoTree)
	end
end

--[[ Wait for the game and LocalPlayer below. ]]
do
	local playersService = cloneref(game:GetService('Players'))
	local deadline = os.clock() + 120
	repeat task.wait() until game:IsLoaded() or console:IsAborted() or os.clock() > deadline
	console:SetProgress(0.24)
	repeat task.wait() until playersService.LocalPlayer or console:IsAborted() or os.clock() > deadline
	--[[ A previous injection still holding shared.vape means the old GUI is mid-teardown;
	main.lua uninjects it, so just let the flag settle before reading the rest of them. ]]
	if shared.vape then
		task.wait(0.25)
	end
	console:SetProgress(0.4)
end
phase('waiting for ROBLOX')
if console:IsAborted() or loaderStopped then deleteInstall() return end

--[[ Join the update check before anything reads a cached .lua file. Bounded for the same reason
every other join in this file is: a stalled update must cost the update, not the boot. ]]
if not updateDone then
	console:SetLine('Checking for updates...')
	joinBatch(function() return updateDone end, 60)
	console:SetLine('')
	if console:IsAborted() or loaderStopped then deleteInstall() return end
end
phase('update check')
console:SetProgress(0.46)

--[[ Detect the very first run (empty/near-empty profiles folder) BEFORE downloading, so we
know afterwards whether to show the prompts below. ]]
local firstRunProfiles = false
pcall(function()
	firstRunProfiles = #listfiles('pistonware/profiles') < 3
end)

--[[ profilecheck.txt persists a prior 'No' answer, so the download prompt only asks once --
without it, a user who declines would get nagged again on every reinject (the profiles
folder stays under 3 files forever if nothing gets downloaded). ]]
local declinedDownload = false
pcall(function()
	if isfile('pistonware/profiles/profilecheck.txt') then
		declinedDownload = readfile('pistonware/profiles/profilecheck.txt') == 'false'
	end
end)

--[[ Step 2: offer the shipped configs. ]]
local wantsDownload = true
if firstRunProfiles and not declinedDownload then
	console:SetProgress(0.47)
	local ok, res = pcall(function()
		return console:Ask('Would you like to download the latest config?', {
			{text = 'Yes', key = true, tooltip = 'Downloads the Blatant and Legit configs from GitHub'},
			{text = 'No', key = false, tooltip = 'Starts on default settings and stops asking on future runs'}
		}, 60, true)
	end)
	--[[ checked before the answer is acted on, so cancelling mid-question never counts as a 'No' ]]
	if console:IsAborted() then deleteInstall() return end
	wantsDownload = ok and res == true
	if not wantsDownload then
		pcall(function() writefile('pistonware/profiles/profilecheck.txt', 'false') end)
	end
end
console:SetProgress(0.53)

local downloadedConfigs = false
if firstRunProfiles and not declinedDownload and wantsDownload then
	console:SetLine('Downloading configs...')
		local synced = false
		pcall(function()
			local body = fetchProfilesListing()
			if body then
				synced = downloadProfilesListing(body, nil, function(completed, total)
					console:SetLine('Downloading configs ('..completed..'/'..total..')...')
					console:SetProgress(0.53 + 0.2 * (completed / math.max(total, 1)))
			end)
		end
	end)
		if synced then
			pcall(function()
				downloadedConfigs = #listfiles('pistonware/profiles') >= 3
			end)
		end
	--[[ Record which commit this download reflects, so later sessions can tell whether profiles/
	has changed on GitHub since (see the sync prompt below). ]]
	if downloadedConfigs then
		pcall(function()
			local commit = profilesFingerprint()
			if commit then
				writefile('pistonware/profiles/profilecommit.txt', commit)
			end
		end)
	end
end
--[[ Repeat the cleanup here: downloads already in flight when cancel fired can land after its wipe. ]]
if console:IsAborted() then deleteInstall() return end

--[[ Step 2b: existing installs (3+ profiles). If profiles/ has changed on GitHub since the last
download/sync, offer to overwrite the shipped configs with the latest ones. Only the files
that exist in the GitHub profiles folder get redownloaded -- profiles the user made
themselves are left alone. Skipped on reinjects/teleports so it only ever asks once per
session, on the first manual execution. ]]
--[[ optout.txt is written by 'Do not ask me again' on the sync prompt below. Its presence is
the whole signal -- delete the file to be asked again. Checked before the fingerprint
fetch so an opted-out boot does not spend a request on a question it will never ask. ]]
local syncOptedOut = false
pcall(function()
	syncOptedOut = isfile('pistonware/optout.txt')
end)

if not firstRunProfiles and not declinedDownload and not isReload and not syncOptedOut then
	local latestCommit, cachedCommit
	pcall(function()
		latestCommit = profilesFingerprint()
		cachedCommit = isfile('pistonware/profiles/profilecommit.txt') and readfile('pistonware/profiles/profilecommit.txt'):gsub('%s', '') or nil
	end)

	--[[ Existing installs hold a 40-char git sha from the old scheme, which can never equal a
	'p1-' fingerprint. Adopt the new value silently rather than reading that mismatch as
	"profiles changed": upgrading the loader is not a reason to ask every user in the world
	to re-sync, and the prompt is the kind that gets clicked through once and distrusted
	thereafter. ]]
	if latestCommit and cachedCommit and #cachedCommit == 40 and cachedCommit:match('^%x+$') then
		pcall(writefile, 'pistonware/profiles/profilecommit.txt', latestCommit)
		cachedCommit = latestCommit
	end

	if latestCommit and latestCommit ~= cachedCommit then
		console:SetProgress(0.6)
		local ok, wantsSync = pcall(function()
			return console:Ask('Would you like to sync to the latest config?', {
				{text = 'Yes', key = true, tooltip = 'Replaces the shipped configs with the newer ones on GitHub'},
				{text = 'No', key = false, tooltip = 'Keeps the configs you have, asks again next session'}
			}, 60, false, {text = 'Do not ask me again', key = 'optout', tooltip = 'Keeps the configs you have and never asks again'})
		end)
		if console:IsAborted() then deleteInstall() return end
		if ok and wantsSync == 'optout' then
			pcall(writefile, 'pistonware/optout.txt', 'true')
		end
		if ok and wantsSync == true then
			console:SetLine('Syncing configs...')

			--[[ Read BEFORE anything is overwritten. <GameId>.gui.txt holds `Profile` -- the
			config currently equipped -- and the sync rewrites that file from the repo's
			copy, whose Profile is whatever happened to be equipped when it was committed
			('blatant', in the version shipping today). mergeGuiState carries the local
			value across, but on any decode failure it falls back to writing the incoming
			file verbatim, and that fallback is exactly how someone on 'legit' or on a
			config they made themselves comes back up on 'blatant'. Re-applying the name
			below makes the equipped config survive the sync whether the merge held or not. ]]
			local lastProfile
			pcall(function()
				--[[ The live object first. vape.Profile updates the moment a profile is switched, so it
				cannot be stale under any ordering, and this is read before the Uninject below
				flushes in-memory state to disk. On a fresh execution there is no object and the
				file is the only source, which is the common case here.

				(The rewritten GUI dropped SetProfile, which the old one used to stamp the switch
				straight into gui.txt. Nothing ever called it -- only this comment named it -- so
				the behaviour here is unchanged.) ]]
				local live = shared.vape and shared.vape.Profile
				if type(live) == 'string' and live ~= '' then
					lastProfile = live
					return
				end

				local guipath = 'pistonware/profiles/'..game.GameId..'.gui.txt'
				if not isfile(guipath) then return end
				local guidata = cloneref(game:GetService('HttpService')):JSONDecode(readfile(guipath))
				if type(guidata) == 'table' and type(guidata.Profile) == 'string' and guidata.Profile ~= '' then
					lastProfile = guidata.Profile
				end
			end)

			pcall(function()
				--[[ If a previous instance is still injected, uninject it BEFORE overwriting:
				Uninject() saves the old in-memory config to disk as its first step, and
				main.lua would otherwise trigger it right after us -- clobbering the freshly
				synced profiles with the old settings. Same for its autosave loop. ]]
				if shared.vape then
					pcall(function() shared.vape:Uninject() end)
					shared.vape = nil
				end
				--[[ Listing and file contents both pinned to latestCommit so a sync run right
				after a push can't grab a stale CDN copy of the branch head.
				The tree this listing came from is itself a pinned snapshot, so its sha is what
				the file contents are fetched at -- no separate ref needed, and no window in
				which the listing and the bodies can disagree. ]]
				local body = fetchProfilesListing()
				local treeSha = repoTree and repoTree.sha
			if body and treeSha then
				local synced = downloadProfilesListing(body, treeSha, function(completed, total)
					console:SetLine('Syncing configs ('..completed..'/'..total..')...')
					console:SetProgress(0.6 + 0.13 * (completed / math.max(total, 1)))
				end)
				if synced then
					writefile('pistonware/profiles/profilecommit.txt', latestCommit)
				else
					--[[ Through the logger rather than a bare warn, so it obeys the same
					developer gate as every other line and still reaches the log file. ]]
					logger:warn('profiles.sync', 'profile sync did not complete; retrying on the next run')
				end
			end
			end)
			if console:IsAborted() then deleteInstall() return end

			--[[ Hand the equipped config back to the load that is about to happen. This covers
			a config the user made themselves and 'legit' alike -- and 'blatant' and
			'default' too, since the shipped gui.txt names one of them and a user sitting
			on either would otherwise be indistinguishable from one who got reset onto it.
			finishLoading in main.lua treats this as a one-shot and clears it, so it steers
			only the load that follows this sync and does not leak into later reinjects.
			Left nil when gui.txt was unreadable, which keeps the old behaviour of letting
			whatever ends up in gui.txt decide rather than inventing a profile here. ]]
			if lastProfile then
				shared.VapeCustomProfile = lastProfile
			end
		end
		--[[ On "No"/timeout the stored commit stays stale, so the prompt returns next session
		until the user agrees to sync once. ]]
	end
end
phase('config download/sync')
console:SetProgress(0.73)

--[[ Step 3: after the shipped configs finish downloading, ask which one should load by default
and hand it to the GUI via shared.VapeCustomProfile. main.lua's finishLoading passes this
straight into vape:Load as the profile to load, replacing the 'default' profile. The keys
match the profile file name prefixes (e.g. blatant<PlaceId>.txt) so Load can find the file. ]]
if downloadedConfigs then
	--[[ No fallback: only an explicit button click may force a config. This used to
	default to 'blatant' -- on a timeout (user tabbed away for 120s) or on the
	headless console (which answers every Ask with the fallback instantly) that
	silently stamped 'blatant' into shared.VapeCustomProfile, overriding the
	profile saved in gui.txt without the user ever choosing it. With nil the
	type(choice) guard below skips the override and the saved profile decides. ]]
	local ok, choice = pcall(function()
		return console:Ask('Which config would you like to load by default?', {
			{text = 'Blatant', key = 'blatant', tooltip = 'Makes Blatant your default config: everything on, obvious'},
			{text = 'Legit', key = 'legit', tooltip = 'Makes Legit your default config: toned down to look normal'}
		}, 120, nil)
	end)
	if console:IsAborted() then deleteInstall() return end
	if ok and type(choice) == 'string' then
		shared.VapeCustomProfile = choice
	end
end

phase('config prompt')
console:SetProgress(0.8)
console:SetLine('Loading pistonware...')
--[[ Reveals the last couple of rows while main.lua downloads and builds the GUI, so the face
is still one row short of finished when injection actually completes. ]]
local injecting = true
task.spawn(function()
	local alpha = 0.8
	while injecting and alpha < 0.93 do
		task.wait(0.6)
		--[[ injection can finish while this thread is asleep; reporting the stale alpha here
		would land after Finish() has already asked for the full face. ]]
		if not injecting then break end
		alpha += 0.02
		console:SetProgress(alpha)
	end
end)

--[[ Protected so a failure surfaces on the console line instead of leaving the window stuck on
'Loading pistonware...'; the buffer retains the diagnostic without public executor output. ]]
local ok, result = xpcall(function()
	local chunk, compileError = loadstring(downloadFile('pistonware/main.lua'), 'main')
	if not chunk then
		error(compileError or 'main.lua did not compile', 0)
	end
	return chunk()
end, errorTrace)
injecting = false
phase('main.lua')
--[[ Consumed only now: main.lua reads the flag itself while loading (it suppresses the 'Finished
Loading' notification on a reload). Left set it would leak into the rest of the session,
since main.lua never clears it and the next teleport/reinject sets it again anyway. ]]
shared.vapereload = nil
--[[ Boot is over (successfully or not) -- reinjects and later manual runs may proceed. ]]
shared.PistonwareLoaderBoot = nil

--[[ Cancelled while the GUI was already building: tear that back down too, then wipe whatever
the run wrote after cancel's first pass. ]]
if console:IsAborted() then
	if shared.vape then
		pcall(function() shared.vape:Uninject() end)
	end
	shared.VapeCustomProfile = nil
	deleteInstall()
	return
end

if ok then
	persistReleaseMarker()
	logger:info('loader.complete', 'injection succeeded', {
		channel = release.channel,
		version = release.version
	})
	console:Finish('Injected successfully.', 5)
	return result
end
--[[ Copied as well as printed: the message is long, full of executor paths, and the person
hitting it is usually being asked to report it. Done here rather than inside console:Fail so
a headless reload (which has no window to read) still leaves it on the clipboard. ]]
local failure = 'Injection failed: '..safeText(result, 3000)
local copied = pcall(function() setclipboard(failure) end)
stopExecution(console, 'main.load', result, result, failure..(copied and '\n\n(copied to clipboard)' or ''))
