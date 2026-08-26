--!nonstrict
-- Snipcast — headless recording service.
--
-- Owns the whole capture round trip so that neither a bar rebuild nor a missing
-- widget can interrupt a recording:
--
--   slurp  →  wf-recorder  →  clipboard (text/uri-list)  →  notification
--
-- Audio is never recorded. `wf-recorder` only opens an audio device when it is
-- given `-a`, so leaving the flag off produces a file with no audio stream at
-- all — which is exactly what makes Telegram play it as a looping GIF instead of
-- offering a video player.
--
-- The widget and the shortcut hold no logic: they read the published "status"
-- and write to "command". Every command also arrives over IPC:
--
--   noctalia msg plugin werdin/snipcast:service all <start|start-output|stop|toggle|abort>

-- ── Settings ─────────────────────────────────────────────────────────────────
local function cfgString(key: string, fallback: string): string
    local value = noctalia.getConfig(key)
    if type(value) ~= "string" then return fallback end
    local trimmed = noctalia.string.trim(value)
    return if trimmed == "" then fallback else trimmed
end

local function cfgInt(key: string, fallback: number, min: number, max: number): number
    local value = tonumber(noctalia.getConfig(key))
    if value == nil then return fallback end
    value = math.floor(value)
    if value < min then return min end
    if value > max then return max end
    return value
end

local function cfgBool(key: string, fallback: boolean): boolean
    local value = noctalia.getConfig(key)
    if type(value) ~= "boolean" then return fallback end
    return value
end

-- ── Shell helpers ────────────────────────────────────────────────────────────
-- Commands are handed to a shell, so every path we interpolate must be quoted.
local function shellQuote(value: string): string
    return "'" .. value:gsub("'", [["'"']]) .. "'"
end

local function log(msg: string)
    noctalia.log(`snipcast: {msg}`)
end

local function now(): number
    return tonumber(noctalia.formatTime("%s")) or 0
end

-- ── Paths ────────────────────────────────────────────────────────────────────
local function stateDir(): string
    local base = noctalia.getenv("XDG_STATE_HOME")
    if type(base) ~= "string" or base == "" then
        base = "~/.local/state"
    end
    return noctalia.expandPath(`{base}/noctalia/snipcast`)
end

local runtimeDir = stateDir()
local logFile = `{runtimeDir}/wf-recorder.log`
local pidFile = `{runtimeDir}/wf-recorder.pid`

noctalia.mkdirAll(runtimeDir)

-- Tail of wf-recorder's own output, so a failed start says *why* instead of just
-- "failed". Truncated per run, so whatever is in there belongs to this attempt.
local function logTail(): string
    local contents = noctalia.readFile(logFile)
    if type(contents) ~= "string" or contents == "" then return "" end

    local lines = {}
    for line in contents:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    if #lines == 0 then return "" end

    local from = math.max(1, #lines - 4)
    return table.concat(lines, "\n", from, #lines)
end

-- ── Published state ──────────────────────────────────────────────────────────
-- idle       — nothing running
-- selecting  — slurp is on screen waiting for a drag
-- recording  — wf-recorder is capturing
-- stopping   — SIGINT sent, waiting for the muxer to finalize the file
local state = "idle"
local available = false
local startedAt = 0
local stopRequestedAt = 0
local outputPath = ""
local discardOnExit = false

local IDLE_INTERVAL = 1000
local ACTIVE_INTERVAL = 500
local MIN_SIDE = 16 -- px; guards against a stray click selecting a 1×1 region
local STOP_GRACE = 5 -- seconds to wait for a clean finalize before SIGKILL

local function elapsed(): number
    if startedAt == 0 then return 0 end
    local seconds = now() - startedAt
    return if seconds > 0 then seconds else 0
end

local function publish()
    noctalia.state.set("status", { state = state, available = available, elapsed = elapsed() })
end

local function goIdle()
    state = "idle"
    startedAt = 0
    stopRequestedAt = 0
    noctalia.setUpdateInterval(IDLE_INTERVAL)
    publish()
end

-- ── Availability ─────────────────────────────────────────────────────────────
local function checkAvailable(notifyMissing: boolean): boolean
    local missing = {}
    if not noctalia.commandExists("wf-recorder") then table.insert(missing, "wf-recorder") end
    if not noctalia.commandExists("slurp") then table.insert(missing, "slurp") end

    available = #missing == 0
    if not available and notifyMissing then
        noctalia.notifyError(noctalia.tr("notify.failed"), `{noctalia.tr("notify.missing-tools")}: {table.concat(missing, ", ")}`)
    end
    return available
end

-- ── Clipboard ────────────────────────────────────────────────────────────────
-- text/uri-list is what a file manager puts on the clipboard for a copied file,
-- so a Qt or GTK chat client pastes it as an attachment rather than as text.
local function copyPathToClipboard(path: string)
    local escaped = path:gsub(" ", "%%20"):gsub("'", "%%27"):gsub('"', "%%22")
    noctalia.copyToClipboard(`file://{escaped}`, "text/uri-list")
end

-- ── Recording ────────────────────────────────────────────────────────────────
local function encoderFlags(): string
    local quality = cfgInt("quality", 23, 0, 51)
    if cfgString("encoder", "cpu") == "vaapi" then
        local device = cfgString("vaapi_device", "/dev/dri/renderD128")
        return `-c h264_vaapi -d {shellQuote(device)} -F 'scale_vaapi=format=nv12' -p qp={quality}`
    end
    -- yuv420p keeps the file playable everywhere, including chat clients that
    -- re-encode nothing and just hand the stream to a system decoder.
    return `-c libx264 -x yuv420p -p crf={quality}`
end

local function outputDirectory(): string
    return noctalia.expandPath(cfgString("directory", "~/Videos/Snipcast"))
end

local function onRecorderExit()
    local path = outputPath
    outputPath = ""
    goIdle()

    if path == "" then return end

    if discardOnExit then
        discardOnExit = false
        noctalia.runAsync(`rm -f {shellQuote(path)}`)
        log(`discarded {path}`)
        noctalia.notify(noctalia.tr("notify.discarded"))
        return
    end

    -- wf-recorder has exited, so the file is finalized; an empty or absent file
    -- means it died before writing anything worth keeping.
    noctalia.runAsync(`test -s {shellQuote(path)}`, function(result)
        if result.exitCode ~= 0 then
            local tail = logTail()
            log(`recording produced no file; wf-recorder said: {tail}`)
            noctalia.notifyError(noctalia.tr("notify.failed"), if tail ~= "" then tail else noctalia.tr("notify.no-output"))
            return
        end

        log(`saved {path}`)
        if cfgBool("copy_to_clipboard", true) then
            copyPathToClipboard(path)
            noctalia.notify(noctalia.tr("notify.saved-copied"), path)
        else
            noctalia.notify(noctalia.tr("notify.saved"), path)
        end
    end)
end

-- sourceFlags is the wf-recorder capture selector: `-g "x,y WxH"` for a region,
-- `-o <name>` for a whole output.
local function startRecording(sourceFlags: string)
    local directory = outputDirectory()
    noctalia.mkdirAll(directory)

    local pattern = cfgString("filename_pattern", "snip_%Y%m%d_%H%M%S")
    outputPath = `{directory}/{noctalia.formatTime(pattern)}.mp4`
    discardOnExit = false

    -- `echo $$` then `exec` makes the pid file name wf-recorder itself, so a stop
    -- signals exactly this recording instead of pkill-ing every wf-recorder on
    -- the machine. The log is truncated per run so its tail belongs to this one.
    local cmd = `: > {shellQuote(logFile)}; echo $$ > {shellQuote(pidFile)}; `
        .. `exec wf-recorder {sourceFlags} -f {shellQuote(outputPath)} `
        .. `-r {cfgInt("frame_rate", 30, 1, 120)} {encoderFlags()} `
        .. `>> {shellQuote(logFile)} 2>&1`

    log(`starting: {cmd}`)

    state = "recording"
    startedAt = now()
    noctalia.setUpdateInterval(ACTIVE_INTERVAL)
    publish()

    -- The callback fires when wf-recorder exits — that *is* the "recording
    -- finished" signal, so no polling for a finished file is needed.
    if not noctalia.runAsync(cmd, onRecorderExit) then
        log("runAsync refused to launch wf-recorder")
        outputPath = ""
        goIdle()
        noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.launch-failed"))
    end
end

local function stopRecording()
    if state ~= "recording" then return end

    state = "stopping"
    stopRequestedAt = now()
    publish()

    -- SIGINT is wf-recorder's documented stop: it flushes and closes the muxer,
    -- which is what makes the mp4 seekable rather than truncated.
    noctalia.runAsync(`kill -INT "$(cat {shellQuote(pidFile)} 2>/dev/null)" 2>/dev/null || true`)
end

-- ── Region selection ─────────────────────────────────────────────────────────
local function startRegion()
    state = "selecting"
    publish()

    noctalia.runAsync("slurp -d -f '%x,%y %wx%h'", function(result)
        -- A stop or abort may have landed while slurp was up.
        if state ~= "selecting" then return end

        local selection = noctalia.string.trim(result.stdout or "")
        if result.exitCode ~= 0 or selection == "" then
            -- Escape or right-click cancels the selection. Cancelling is a
            -- normal outcome, not a failure — go quiet rather than notify.
            log("selection cancelled")
            goIdle()
            return
        end

        -- slurp reports logical coordinates, which is also what wf-recorder's -g
        -- expects; it multiplies by the output scale itself. Negative origins are
        -- possible on multi-output layouts.
        local x, y, w, h = selection:match("^(-?%d+),(-?%d+) (%d+)x(%d+)$")
        if x == nil then
            log(`unparseable slurp output: {selection}`)
            goIdle()
            noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.bad-selection"))
            return
        end

        -- Round down to even: h264 with yuv420p rejects odd dimensions. On a
        -- scaled output the doubling hides this, on an unscaled one it does not.
        local width = tonumber(w) - tonumber(w) % 2
        local height = tonumber(h) - tonumber(h) % 2

        if width < MIN_SIDE or height < MIN_SIDE then
            log(`selection too small: {width}x{height}`)
            goIdle()
            noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.selection-too-small"))
            return
        end

        startRecording(`-g {shellQuote(`{x},{y} {width}x{height}`)}`)
    end)
end

local function startOutput(outputName: string?)
    local name = if type(outputName) == "string" then noctalia.string.trim(outputName) else ""
    if name == "" then
        local focused = noctalia.focusedOutputName()
        name = if type(focused) == "string" then focused else ""
    end

    if name == "" then
        log("no focused output to record")
        noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.no-output-name"))
        return
    end

    startRecording(`-o {shellQuote(name)}`)
end

-- ── Command dispatch ─────────────────────────────────────────────────────────
local function handle(action: string?, payload)
    if action == nil or action == "" then return end

    if not checkAvailable(true) then
        publish()
        return
    end

    local outputName = if type(payload) == "table" then payload.focusedOutputName else nil

    if action == "start" then
        if state == "idle" then startRegion() end
    elseif action == "start-output" then
        if state == "idle" then startOutput(outputName) end
    elseif action == "stop" then
        stopRecording()
    elseif action == "toggle" then
        if state == "idle" then
            startRegion()
        elseif state == "recording" then
            stopRecording()
        end
        -- "selecting" and "stopping" are transient: a toggle mid-flight is a
        -- double click, and dropping it is friendlier than cancelling.
    elseif action == "abort" then
        if state == "recording" then
            discardOnExit = true
            stopRecording()
        end
    else
        log(`unknown command '{action}'`)
    end
end

-- ── Entry points ─────────────────────────────────────────────────────────────
function update()
    if state == "recording" then
        publish() -- keeps the widget's timer ticking

        local limit = cfgInt("max_duration", 0, 0, 3600)
        if limit > 0 and elapsed() >= limit then
            log(`max_duration {limit}s reached, stopping`)
            stopRecording()
        end
    elseif state == "stopping" then
        publish()

        -- wf-recorder normally exits within a frame or two of SIGINT. If it does
        -- not, something is wedged and a truncated file beats a stuck widget.
        if now() - stopRequestedAt >= STOP_GRACE then
            log("stop timed out, sending SIGKILL")
            stopRequestedAt = now()
            noctalia.runAsync(`kill -9 "$(cat {shellQuote(pidFile)} 2>/dev/null)" 2>/dev/null || true`)
        end
    end
end

function onIpc(event: string, payload)
    handle(event, payload)
end

noctalia.state.watch("command", function(command)
    if type(command) == "table" then
        handle(command.action, command)
    elseif type(command) == "string" then
        handle(command, nil)
    end
end)

noctalia.setUpdateInterval(IDLE_INTERVAL)
checkAvailable(false)
goIdle()
