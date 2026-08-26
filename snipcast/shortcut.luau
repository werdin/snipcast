--!nonstrict
-- Snipcast — Control Center quick tile.
--
-- Holds no recording logic: it mirrors the service through the plugin's shared
-- state, the same way the bar widget does. Unlike the widget it does not have to
-- be placed on a bar to work — the service runs for the whole session.
--
--   reads  noctalia.state "status"  -> { state, available, elapsed }
--   writes noctalia.state "command" -> { action = "toggle" | "abort" }

local state = "idle"
local available = false

-- Same reason as in widget.luau: identical consecutive writes can coalesce, and
-- a toggle that only works every other click is worse than no toggle.
local seq = 0

local function send(action: string)
    seq += 1
    noctalia.state.set("command", {
        action = action,
        focusedOutputName = noctalia.focusedOutputName(),
        seq = `{noctalia.formatTime("%s")}-{seq}`,
    })
end

local function applyStatus(status)
    if type(status) == "table" then
        state = status.state or "idle"
        available = if status.available then true else false
    end

    local busy = state == "recording" or state == "stopping"

    shortcut.setLabel(
        if busy then noctalia.tr("shortcut.recording")
        elseif state == "selecting" then noctalia.tr("shortcut.selecting")
        else noctalia.tr("shortcut.record-region")
    )
    shortcut.setIcon("capture", "video-off")
    shortcut.setActive(busy or state == "selecting")
    shortcut.setEnabled(available)
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)

function onClick()
    send("toggle")
end

function onRightClick()
    send("abort")
end
