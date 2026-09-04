local background

function init()
    background = g_ui.displayUI('background')
    background:lower()

    connect(g_game, {
        onGameStart = hide,
        onGameEnd = show
    })
end

function terminate()
    disconnect(g_game, {
        onGameStart = hide,
        onGameEnd = show
    })

    background:destroy()
    background = nil
end

function hide()
    background:hide()
end

function show()
    background:show()
end

function getBackground()
    return background
end
