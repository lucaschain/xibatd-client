local function onGameStart()
    g_window.setCloseWarning(true)
end

local function onGameEnd()
    g_window.setCloseWarning(false)
end

function startup()
    if g_sounds then
        connect(g_game, {
            onGameEnd = function()
                g_sounds.stopAll()
            end
        })
    end

    -- Check for startup errors
    local errtitle = nil
    local errmsg = nil

    if g_graphics.getRenderer():lower():match('gdi generic') then
        errtitle = tr('Graphics card driver not detected')
        errmsg = tr(
            'No graphics card detected, everything will be drawn using the CPU,\nthus the performance will be really bad.\nPlease update your graphics driver to have a better performance.')
    end

    -- Show entergame
    if errmsg or errtitle then
        local msgbox = displayErrorBox(errtitle, errmsg)
        msgbox.onOk = function()
            EnterGame.firstShow()
        end
    else
        EnterGame.firstShow()
    end
    if g_app.hasUpdater() and g_sounds then
        g_sounds.setAudioEnabled(g_settings.getBoolean('enableAudio'))
    end
end

function init()
    connect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd,
    })
    g_window.setCloseWarning(g_game.isOnline())

    if g_app.hasUpdater() then
        connect(g_app, {
            onUpdateFinished = startup,
        })
    else
        connect(g_app, {
            onRun = startup,
        })
    end
end

function terminate()
    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd,
    })
    g_window.setCloseWarning(false)

    if g_app.hasUpdater() then
        disconnect(g_app, {
            onUpdateFinished = startup,
        })
    else
        disconnect(g_app, {
            onRun = startup,
        })
    end
end
