-- Invoked by tools/test-replay.ps1 in an isolated Windows installation/profile.
local started, completed = false, false
local began
local errors = {}
local function finish(reason)
    if completed then return end
    completed = true
    if reason then errors[#errors + 1] = reason end
    g_resources.writeFileContentsToWorkDir('replay-smoke-result.json', json.encode({
        status = started and #errors == 0 and 'PASS' or 'FAIL',
        started = started, elapsedMs = began and g_clock.millis() - began or 0, errors = errors,
    }))
    scheduleEvent(function() g_app.exit() end, 100)
end

scheduleEvent(function()
    g_logger.setOnLog(function(level, message)
        if level >= LogError then
            errors[#errors + 1] = message
            scheduleEvent(function() finish('Client error during replay') end, 1)
        end
    end)
    connect(g_game, {
        onGameStart = function() started = true end,
        onGameEnd = function()
            if not started or g_clock.millis() - began < 300000 then
                finish('Replay ended before the Hive timeout')
            else
                finish()
            end
        end,
    })
    began = g_clock.millis()
    local ok, err = modules.client_replay.play('run.rec')
    if not ok then finish(err) end
    scheduleEvent(function() finish('Replay exceeded its bounded smoke-test duration') end, 330000)
end, 1000)
