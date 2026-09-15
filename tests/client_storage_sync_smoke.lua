-- Run from otclientrc.lua in an isolated native installation/profile.
local outstanding = {}
local count = 0
local finished = false
local timeout
local onResult
local function finish(ok, message)
  if finished then return end
  finished = true
  if timeout then removeEvent(timeout) end
  disconnect(g_resources, { onWritableStorageSync = onResult })
  g_resources.writeFileContentsToWorkDir('storage-sync-smoke-result.json', json.encode({
    status = ok and 'PASS' or 'FAIL', message = message, completedRequests = count
  }))
  scheduleEvent(function() g_app.exit() end, 100)
end
onResult = function(id, message)
  if not outstanding[id] then return finish(false, 'Unexpected or synchronous storage response') end
  if message ~= '' then return finish(false, message) end
  outstanding[id] = nil
  count = count + 1
  if count == 2 then finish(true, 'Native resource sync IDs and dispatcher signals verified') end
end
connect(g_resources, { onWritableStorageSync = onResult })
timeout = scheduleEvent(function() finish(false, 'Storage sync callback timed out') end, 5000)
for _ = 1, 2 do outstanding[g_resources.requestWritableStorageSync()] = true end
