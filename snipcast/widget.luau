--!nonstrict
-- Snipcast — bar widget (thin presentation client).
--
-- All the recording logic lives in the [[service]] (service.luau). This widget
-- only mirrors the published "status" and drives the recorder by writing to the
-- "command" channel, so the capture is unaffected by the bar being rebuilt.
--
-- Click mapping:
--   Left click   — pick a region and start / stop the running recording
--   Right click  — record the whole focused output (no region picker)
--   Middle click — stop and throw the file away

local state = "idle"
local available = false
local elapsed = 0

-- Two identical writes to the state channel can coalesce, which would swallow
-- every second click of a toggle. A per-click nonce keeps each command distinct.
local seq = 0

local function send(action: string)
    seq += 1
    noctalia.state.set("command", {
        action = action,
        focusedOutputName = noctalia.focusedOutputName(),
        seq = `{noctalia.formatTime("%s")}-{seq}`,
    })
end

local function clock(seconds: number): string
    local total = math.floor(seconds)
    if total < 0 then total = 0 end
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function applyStatus(status)
    if type(status) == "table" then
        state = status.state or "idle"
        available = if status.available then true else false
        elapsed = tonumber(status.elapsed) or 0
    end

    local hideInactive = noctalia.getConfig("hide_inactive") == true

    if not available then
        barWidget.setGlyph("video-off")
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr("tooltip.unavailable"))
        barWidget.setVisible(not hideInactive)
        return
    end

    if state == "recording" or state == "stopping" then
        barWidget.setGlyph("player-record-filled")
        barWidget.setGlyphColor("error")
        barWidget.setColor("error")
        -- The timer is the only cue that a region off in the corner is still
        -- being captured. It is dropped on a vertical bar, where it will not fit.
        local showTimer = noctalia.getConfig("show_timer") ~= false
        barWidget.setText(if showTimer and not barWidget.isVertical() then clock(elapsed) else "")
        barWidget.setTooltip(
            if state == "stopping"
            then noctalia.tr("tooltip.saving")
            else `{noctalia.tr("tooltip.recording")} — {clock(elapsed)}`
        )
        barWidget.setVisible(true)
        return
    end

    if state == "selecting" then
        barWidget.setGlyph("crop")
        barWidget.setGlyphColor("primary")
        barWidget.setColor("primary")
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr("tooltip.selecting"))
        barWidget.setVisible(true)
        return
    end

    barWidget.setGlyph("capture")
    barWidget.setGlyphColor("on_surface")
    barWidget.setText("")
    barWidget.setTooltip(noctalia.tr("tooltip.idle"))
    barWidget.setVisible(not hideInactive)
end

function onClick()
    if not available then return end
    if state == "idle" then
        send("start")
    elseif state == "recording" then
        send("stop")
    end
end

function onRightClick()
    if not available then return end
    if state == "idle" then
        send("start-output")
    elseif state == "recording" then
        send("stop")
    end
end

function onMiddleClick()
    if state == "recording" then
        send("abort")
    end
end

-- Reflect whatever the service last published, then track live changes.
applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)
