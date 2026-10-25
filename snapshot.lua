-- Desktop maps: which apps live on which desktop, and a hotkey to put every
-- window back there.
--
-- One map per display count, so "laptop alone" and "laptop + monitor" are
-- separate arrangements. A map lists each display's desktops in order and
-- the apps on each, by app name or bundle ID, and each app's windows, oldest
-- first: the display (its place in `displays`), the desktop on it, and the
-- window's size and place as fractions of the screen ([x, y, w, h]):
--
--   "2": { "displays": [
--     { "name": "Built-in Retina Display", "builtin": true,
--       "desktops": [ ["Granola", "Slack"], ["Google Chrome"] ] },
--     { "name": "MSI MPG341CQR", "builtin": false,
--       "desktops": [ ["Google Chrome"], ["Claude", "Cursor"] ] } ],
--     "windows": {
--       "Google Chrome": [ { "display": 2, "desktop": 1, "frame": [0, 0, 1, 1], "id": 4711 },
--                          { "display": 1, "desktop": 2, "frame": [0, 0, 0.5, 1], "id": 5120 } ],
--       ... } }
--
-- `desktops` is the summary to read; `windows` is what restore follows. An
-- app with no `windows` entry (added by hand, or from a map saved before
-- windows were tracked one by one) goes wholly to the first desktop that
-- lists it, taking any per-display `sizes` in window order.
--
-- Restore moves each window to its desktop by position, so desktop 2 stays
-- desktop 2 even when nothing on desktop 1 is open. A window still open
-- since the save (same window ID) goes back to its own place; the app's
-- other windows take the remaining places in window order, and windows
-- beyond the saved ones take the last. Displays are matched by name, then
-- by role (built-in, or the largest external), so a map saved at one desk
-- restores onto a different monitor at another.
--
-- ctrl+alt+cmd+s writes the map from where windows are now (apps not running
-- keep their saved desktop; +shift forgets them), and ctrl+alt+cmd+r
-- restores. Nothing runs on its own. The map lives in
-- ~/.hammerspoon/desktops.json, a real file on each machine rather than a
-- link into the repo, and is meant to be edited by hand too.

return function(wm)
  local path = hs.configdir .. "/desktops.json"
  local function isBuiltin(screen) return screen:name():match("^Built%-in") ~= nil end
  local function area(screen) local f = screen:fullFrame() return f.w * f.h end
  local function key() return tostring(#hs.screen.allScreens()) end
  local function load() return hs.json.read(path) or {} end

  -- A map's windows by app, oldest first: { display, desktop, frame, id },
  -- with frame and id optional. Apps listed in `desktops` but missing from
  -- `windows` get one entry per saved size (or one bare entry) on the first
  -- desktop that lists them.
  local function windowsOf(map)
    local wins = {}
    for app, list in pairs(map.windows or {}) do wins[app] = list end
    for di, d in ipairs(map.displays or {}) do
      for pos, apps in ipairs(d.desktops or {}) do
        for _, app in ipairs(apps) do
          if not wins[app] then
            local list = {}
            for _, u in ipairs(d.sizes and d.sizes[app] or {}) do
              list[#list + 1] = { display = di, desktop = pos, frame = u }
            end
            if #list == 0 then list[1] = { display = di, desktop = pos } end
            wins[app] = list
          end
        end
      end
    end
    return wins
  end

  -- What the last save or restore did, step by step, in
  -- ~/.hammerspoon/restore.log: desktop moves happen out of sight and too
  -- fast to watch, and this is how to tell a shortcut that did not fire from
  -- a window that did not follow. Each line is written as it happens, so a
  -- restore that stops partway still shows how far it got.
  local logPath = hs.configdir .. "/restore.log"
  local function log(fmt, ...)
    local f = io.open(logPath, "a")
    if f then f:write(os.date("%H:%M:%S "), string.format(fmt, ...), "\n") f:close() end
  end
  local function clearLog()
    local f = io.open(logPath, "w")
    if f then f:close() end
  end

  local function spaceOfWindow(id) return (hs.spaces.windowSpaces(id) or {})[1] end

  local function activeSpaces()
    local r = {}
    for _, space in pairs(hs.spaces.activeSpaces() or {}) do r[space] = true end
    return r
  end

  local function indexOf(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
  end

  -- A display's regular desktops in order, skipping full-screen apps.
  -- `screen` is a screen or a display UUID.
  local function userDesktops(screen)
    local r = {}
    for _, space in ipairs(hs.spaces.spacesForScreen(screen) or {}) do
      if hs.spaces.spaceType(space) == "user" then r[#r + 1] = space end
    end
    return r
  end

  -- The screen a saved display is now: same name, else same role (the
  -- largest one), skipping screens in `used`, display UUID -> true.
  local function findScreen(spec, used)
    local screens = hs.screen.allScreens()
    for _, s in ipairs(screens) do
      if s:name() == spec.name and not used[s:getUUID()] then return s end
    end
    local best
    for _, s in ipairs(screens) do
      if not used[s:getUUID()] and isBuiltin(s) == spec.builtin and (not best or area(s) > area(best)) then
        best = s
      end
    end
    return best
  end

  -- Where a desktop is, for the log and alerts: "MSI MPG341CQR desktop 2".
  local function describeSpace(space)
    local uuid = space and hs.spaces.spaceDisplay(space)
    local screen = uuid and hs.screen.find(uuid)
    local i = uuid and indexOf(userDesktops(uuid), space)
    return string.format("%s desktop %s", screen and screen:name() or "?", tostring(i or space))
  end

  -- A save or restore is a chain of timed steps. `run` counts restores, so a step
  -- left over from one that was stopped does nothing; an error in any step
  -- stops it with an alert instead of leaving it hung, since a Lua
  -- error inside a timer only reaches the Hammerspoon console.
  local running, run, stop = false, 0, nil
  local function guarded(fn)
    local mine = run
    return function(...)
      if mine ~= run or not running then return end
      local ok, err = xpcall(fn, debug.traceback, ...)
      if not ok then stop("error: " .. tostring(err)) end
    end
  end
  local function after(delay, fn) hs.timer.doAfter(delay, guarded(fn)) end

  -- Every open window of an ordinary app on exactly one regular desktop,
  -- on every display: { id, name, bundle, space }, passed to `done`.
  -- Neither Accessibility nor the window server's list in Hammerspoon sees
  -- windows on a desktop that is not showing, so show each desktop in turn
  -- and read the windows showing at each step. Accessibility tells real windows from
  -- an app's hidden helpers, and leaves out minimized ones. The displays
  -- are left showing their last desktop; `shown` is what showed before.
  -- A window's frame as fractions of its screen, [x, y, w, h], rounded so
  -- the map stays readable.
  local function unitOf(win)
    local f, s = win:frame(), win:screen()
    if not (f and s) then return nil end
    local sf = s:frame()
    local function r(v) return math.floor(v * 10000 + 0.5) / 10000 end
    return { r((f.x - sf.x) / sf.w), r((f.y - sf.y) / sf.h), r(f.w / sf.w), r(f.h / sf.h) }
  end

  local function scanWindows(done)
    local found, seen, visited = {}, {}, {}
    local shown = hs.spaces.activeSpaces() or {}
    local function collect()
      for space in pairs(activeSpaces()) do visited[space] = true end
      for _, win in ipairs(hs.window.visibleWindows()) do
        local app, id = win:application(), win:id()
        if win:isStandard() and app and not seen[id] and app:bundleID() ~= "org.hammerspoon.Hammerspoon" then
          local spaces = hs.spaces.windowSpaces(id) or {}
          if #spaces == 1 and hs.spaces.spaceType(spaces[1]) == "user" then
            seen[id] = true
            found[#found + 1] = { id = id, name = app:name(), bundle = app:bundleID(),
              space = spaces[1], unit = unitOf(win) }
          elseif #spaces == 0 then
            log("no desktop for %s window %d; left alone", app:name(), id)
          end
        end
      end
    end
    local desks = {}
    for _, s in ipairs(hs.screen.allScreens()) do
      for _, space in ipairs(userDesktops(s)) do desks[#desks + 1] = space end
    end
    collect()
    local i = 0
    local function step()
      i = i + 1
      local space = desks[i]
      if not space then
        table.sort(found, function(a, b) return a.id < b.id end)
        return done(found, shown)
      end
      if visited[space] then return step() end
      hs.spaces.gotoSpace(space)
      -- Let the desktop finish sliding in before reading its windows.
      after(0.8, function() collect() step() end)
    end
    step()
  end

  -- Show these desktops (a list, or display UUID -> Space ID) where they
  -- are not, then call `done`. One at a time: macOS drops a desktop switch
  -- that arrives while another display's switch is still sliding in.
  local function showSpaces(spaces, done)
    local list = {}
    for _, space in pairs(spaces) do list[#list + 1] = space end
    local i = 0
    local function nextSpace()
      i = i + 1
      local space = list[i]
      if not space then return done() end
      if activeSpaces()[space] then return nextSpace() end
      hs.spaces.gotoSpace(space)
      after(0.8, nextSpace)
    end
    nextSpace()
  end

  local watchdog
  local function startRun()
    running, run = true, run + 1
    clearLog()
    watchdog = hs.timer.doAfter(120, guarded(function() stop("took over two minutes") end))
  end
  local function endRun()
    running = false
    if watchdog then watchdog:stop() end
  end

  local save
  local function sortedKeys(t)
    local r = {}
    for k in pairs(t) do r[#r + 1] = k end
    table.sort(r)
    return r
  end

  -- A map's desktops, one display per line group, for the save alert.
  local function summary(displays)
    local lines = {}
    for _, d in ipairs(displays) do
      local desks = {}
      for i, apps in ipairs(d.desktops) do
        desks[#desks + 1] = i .. ": " .. (#apps > 0 and table.concat(apps, ", ") or "(empty)")
      end
      lines[#lines + 1] = d.name .. "\n  " .. table.concat(desks, "\n  ")
    end
    return table.concat(lines, "\n")
  end

  -- Write this display count's map from where windows are now, every window
  -- in its own place, so an app spread over several desktops stays spread.
  -- Unless `fresh`, apps in the stored map that have no window open keep
  -- their stored places. Reading every desktop takes a
  -- moment of desktops switching; each display ends on the desktop it was
  -- showing. Returns false while a save or restore is running.
  function wm.saveSnapshot(fresh)
    if running then return false end
    startRun()
    log("save %s-display map", key())
    scanWindows(guarded(function(found, shown)
      local message = save(fresh, found)
      -- An alert stays on the desktop it opened on, so show it once back.
      showSpaces(shown, function()
        hs.alert.show(message, 6)
        endRun()
      end)
    end))
    return true
  end

  save = function(fresh, found)
    local data, k = load(), key()
    local screens = hs.screen.allScreens()
    local order = {}
    for i, s in ipairs(screens) do order[s:getUUID()] = i end

    -- app name -> its windows, oldest first (found is in window order)
    local windows = {}
    for _, w in ipairs(found) do
      local uuid = hs.spaces.spaceDisplay(w.space)
      local pos = uuid and indexOf(userDesktops(uuid), w.space)
      log("saw %s window %d on %s", w.name, w.id, describeSpace(w.space))
      if pos and order[uuid] then
        windows[w.name] = windows[w.name] or {}
        table.insert(windows[w.name], { display = order[uuid], desktop = pos, frame = w.unit, id = w.id })
      end
    end

    -- Apps not running keep their stored places, carried onto whichever
    -- display each stored one is now. Their window IDs are gone with them.
    local kept, old = 0, data[k]
    if not fresh and old and old.displays then
      local used, now = {}, {}
      for di, d in ipairs(old.displays) do
        local s = findScreen(d, used)
        if s then
          used[s:getUUID()] = true
          now[di] = order[s:getUUID()]
        end
      end
      for app, list in pairs(windowsOf(old)) do
        if not windows[app] then
          local carried = {}
          for _, e in ipairs(list) do
            if now[e.display] then
              carried[#carried + 1] = { display = now[e.display], desktop = e.desktop, frame = e.frame }
            end
          end
          if #carried > 0 then
            windows[app] = carried
            kept = kept + 1
          end
        end
      end
    end

    -- The summary: every app on each desktop it has a window on.
    local displays, listed = {}, {}
    for i, s in ipairs(screens) do
      displays[i] = { name = s:name(), builtin = isBuiltin(s), desktops = {} }
    end
    for _, app in ipairs(sortedKeys(windows)) do
      for _, e in ipairs(windows[app]) do
        local d, slot = displays[e.display], string.format("%d:%d:%s", e.display, e.desktop, app)
        if d and not listed[slot] then
          listed[slot] = true
          for j = #d.desktops + 1, e.desktop do d.desktops[j] = {} end
          table.insert(d.desktops[e.desktop], app)
        end
      end
    end

    data[k] = { savedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"), displays = displays, windows = windows }
    hs.json.write(data, path, true, true)
    log("saved %s-display map (%d kept from before):\n%s", k, kept, summary(displays))
    return "Saved " .. k .. "-display desktops\n" .. summary(displays)
      .. (kept > 0 and string.format("\n(%d not running, kept from before)", kept) or "")
  end

  -- Apps (by bundle ID or name) the desktop drag below leaves alone; their
  -- windows stay on whatever desktop they are on and are reported. Empty by
  -- default: browsers keep tabs in the title bar, but grabPoint() skips tabs
  -- and other controls, and a grab that does not move the window is let go
  -- in place. init.local.lua can add to it.
  wm.noDrag = {}

  -- The keys macOS's "Move left a space" and "Move right a space" shortcuts
  -- are set to, read from System Settings, or nil when either is off. An
  -- entry that was never changed is still the default ctrl+left/right.
  local function spaceSwitchKeys()
    local prefs = hs.plist.read(os.getenv("HOME") .. "/Library/Preferences/com.apple.symbolichotkeys.plist")
    local all = prefs and prefs.AppleSymbolicHotKeys or {}
    local function keyFor(id, default)
      local e = all[tostring(id)]
      if e == nil then return default end
      if e.enabled == false or e.enabled == 0 then return nil end
      local p = e.value and e.value.parameters
      if not p then return nil end
      local flags, mods = p[3], {}
      if flags & 0x40000 ~= 0 then mods[#mods + 1] = "ctrl" end
      if flags & 0x80000 ~= 0 then mods[#mods + 1] = "alt" end
      if flags & 0x100000 ~= 0 then mods[#mods + 1] = "cmd" end
      if flags & 0x20000 ~= 0 then mods[#mods + 1] = "shift" end
      return { mods = mods, key = hs.keycodes.map[p[2]], fn = flags & 0x800000 ~= 0 }
    end
    local left = keyFor(79, { mods = { "ctrl" }, key = "left", fn = true })
    local right = keyFor(81, { mods = { "ctrl" }, key = "right", fn = true })
    return left and right and { left = left, right = right }
  end

  -- Press a shortcut with exactly the flags macOS has on file for it. Arrow
  -- keys carry the fn flag, and a shortcut stored with it does not fire for
  -- a press without it.
  local function press(key)
    for _, down in ipairs({ true, false }) do
      local event = hs.eventtap.event.newKeyEvent(key.mods, key.key, down)
      if key.fn then
        local flags = event:getFlags()
        flags.fn = true
        event:setFlags(flags)
      end
      event:post()
    end
  end

  -- State for the restore in progress: windows that did not reach their
  -- desktop, for the alert; desktops windows were moved off, candidates for
  -- removal; and whether adding a desktop left Mission Control open.
  local moveErrors, vacated, missionControlOpen

  -- Keep a window's place relative to the screen when it changes display.
  local function carry(win, target)
    local to = hs.screen.find(hs.spaces.spaceDisplay(target))
    local from, f = win:screen(), win:frame()
    if not (to and from and f) then return end
    local sf, tf = from:frame(), to:frame()
    local w, h = math.min(f.w / sf.w, 1), math.min(f.h / sf.h, 1)
    local x = math.max(0, math.min((f.x - sf.x) / sf.w, 1 - w))
    local y = math.max(0, math.min((f.y - sf.y) / sf.h, 1 - h))
    wm.setFrame(win, { x = tf.x + x * tf.w, y = tf.y + y * tf.h, w = w * tf.w, h = h * tf.h })
  end

  -- macOS will not let another app move a window to a different desktop, and
  -- cannot move a desktop between displays at all; only Mission Control's
  -- drag does that. Two moves still work, and restore builds on them:
  --
  -- Across displays: moving a window onto another display lands it on
  -- whichever desktop that display is showing. Each display shows a desktop
  -- of its own, so show the window's desktop on one and its target on the
  -- other, then move it over. Showing its desktop is also what makes the
  -- window reachable at all.
  local function moveAcross(group, nextJob)
    showSpaces({ group.source, group.target }, function()
      for _, e in ipairs(group) do
        local win = hs.window.get(e.id)
        if win then carry(win, group.target) end
        log("across %s (window %d): %s -> %s, now on %s", e.name, e.id, describeSpace(group.source),
          describeSpace(group.target), describeSpace(spaceOfWindow(e.id)))
        if spaceOfWindow(e.id) == group.target then
          vacated[group.source] = true
        else
          moveErrors[#moveErrors + 1] = e.name
        end
      end
      nextJob()
    end)
  end

  -- Roles a mouse-down would operate instead of dragging the window.
  local controlRoles = {
    AXButton = true, AXCheckBox = true, AXRadioButton = true, AXRadioGroup = true,
    AXPopUpButton = true, AXMenuButton = true, AXTextField = true, AXTextArea = true,
    AXSearchField = true, AXComboBox = true, AXSlider = true, AXTabGroup = true,
    AXLink = true, AXDisclosureTriangle = true, AXIncrementor = true, AXColorWell = true,
  }

  -- A spot on the window's title bar that a mouse-down will drag by: scan
  -- along the row of the traffic-light buttons and take the first point
  -- whose element belongs to this window (so no window in front of it) and
  -- is not a control (so nothing gets clicked). Returns nil, reason.
  --
  -- Apps whose title bar is web content (Electron: Cursor, Claude, Slack)
  -- may not say which window an element is in; then look up its parents,
  -- and failing that accept an element of the window's own app while that
  -- window is the focused one, since it was just brought to the front.
  local function ownsElement(win, el)
    local node = el
    for _ = 1, 30 do
      if not node then break end
      local owner = node:attributeValue("AXRole") == "AXWindow" and node or node:attributeValue("AXWindow")
      local ownerWin = owner and owner:asHSWindow()
      if ownerWin then return ownerWin:id() == win:id() end
      node = node:attributeValue("AXParent")
    end
    local focused = hs.window.focusedWindow()
    return el:pid() == win:pid() and focused ~= nil and focused:id() == win:id()
  end

  local function grabPoint(win)
    local zoom, f = win:zoomButtonRect(), win:frame()
    if not zoom then return nil, "no zoom button" end
    local y, other = zoom.y + zoom.h / 2, nil
    for x = zoom.x + zoom.w + 6, f.x + f.w - 20, 16 do
      local el = hs.axuielement.systemElementAtPosition(x, y)
      local role = el and el:attributeValue("AXRole")
      if el and ownsElement(win, el) then
        if not controlRoles[role] then return { x = x, y = y }, role end
      else
        other = other or string.format("%s of pid %s at %.0f,%.0f", tostring(role),
          tostring(el and el:pid()), x, y)
      end
    end
    return nil, other and ("another window is in front: " .. other) or "only controls on the title bar"
  end

  -- On one display: what a person does by hand. Hold the window by its title
  -- bar, just right of the green zoom button, press the "Move left/right a
  -- space" shortcut until the target desktop is showing, and let go; the
  -- window travels along. The pointer goes back where it was afterwards. A
  -- move that fails is tried once more, from wherever the window ended up,
  -- before it is reported.
  local function dragAlong(e, target, keys, nextJob, attempt)
    attempt = attempt or 1
    local function fail(why)
      log("  gave up: %s", why)
      if attempt < 2 then
        log("  trying once more")
        return after(0.5, function() dragAlong(e, target, keys, nextJob, attempt + 1) end)
      end
      moveErrors[#moveErrors + 1] = e.name
      nextJob()
    end
    local source = spaceOfWindow(e.id)
    if not source then return fail("window is on no desktop") end
    if source == target then return nextJob() end
    if not activeSpaces()[source] then hs.spaces.gotoSpace(source) end
    after(0.8, function()
      local win = hs.window.get(e.id)
      local desks = hs.spaces.spacesForScreen(hs.spaces.spaceDisplay(source)) or {}
      local from, to = indexOf(desks, source), indexOf(desks, target)
      log("drag %s (window %d): %s -> %s, positions %s -> %s of [%s]", e.name, e.id,
        describeSpace(source), describeSpace(target), tostring(from), tostring(to), table.concat(desks, ","))
      if not (win and from and to) then
        return fail(not win and "window not reachable" or "desktop not on this display")
      end
      -- Bring it to the front first and give that a moment: a click lands on
      -- whatever window is frontmost at that spot.
      win:focus()
      after(0.3, function()
        local grab, why = grabPoint(win)
        if not grab then return fail(why) end
        local ev, types = hs.eventtap.event, hs.eventtap.event.types
        local start = win:frame()
        local pointer = hs.mouse.absolutePosition()
        local key = to > from and keys.right or keys.left
        local display = hs.spaces.spaceDisplay(source)
        local function where()
          local f = win:frame() or {}
          return string.format("showing %s, window on %s, window at %s,%s",
            tostring((hs.spaces.activeSpaces() or {})[display]), tostring(spaceOfWindow(e.id)),
            tostring(f.x), tostring(f.y))
        end
        log("  grabbing %.0f,%.0f (%s); key %s+%s%s", grab.x, grab.y, why,
          table.concat(key.mods, "+"), key.key, key.fn and " (fn)" or "")
        ev.newMouseEvent(types.leftMouseDown, grab):post()
        after(0.15, function()
          -- Move far enough for macOS to treat it as a drag, not a click.
          for dx = 2, 10, 2 do
            ev.newMouseEvent(types.leftMouseDragged, { x = grab.x + dx, y = grab.y }):post()
          end
          after(0.15, function()
            log("  after grab: %s", where())
            -- Only switch desktops once the window is visibly being dragged;
            -- otherwise drag back and let go where the grab started, which
            -- grabPoint() checked is not a control, so nothing is clicked and
            -- a tab that was picked up drops back into place.
            if math.abs(win:frame().x - start.x) < 4 then
              ev.newMouseEvent(types.leftMouseDragged, grab):post()
              ev.newMouseEvent(types.leftMouseUp, grab):post()
              hs.mouse.absolutePosition(pointer)
              return fail("the window did not move with the grab")
            end
            local steps = math.abs(to - from)
            local function step()
              if steps == 0 then
                return after(0.4, function()
                  -- Drag back to where the grab started before letting go,
                  -- so the window lands where it was, not 10 points over.
                  ev.newMouseEvent(types.leftMouseDragged, grab):post()
                  ev.newMouseEvent(types.leftMouseUp, grab):post()
                  hs.mouse.absolutePosition(pointer)
                  after(0.4, function()
                    log("  after release: %s", where())
                    if spaceOfWindow(e.id) ~= target then
                      return fail("the window did not land on " .. describeSpace(target))
                    end
                    vacated[source] = true
                    nextJob()
                  end)
                end)
              end
              steps = steps - 1
              press(key)
              after(0.5, function()
                log("  after key press: %s", where())
                step()
              end)
            end
            step()
          end)
        end)
      end)
    end)
  end

  -- Remove empty desktops, which would otherwise pile up with every dock and
  -- undock: any past the number the map lists for a display (`filled`,
  -- display UUID -> count), and ones this restore emptied on a display the
  -- map does not cover. Desktops the map lists stay even when empty, so
  -- the ones after them keep their numbers. Only a regular desktop with
  -- none of the windows the scan found (`found`) left on it goes, and never
  -- a display's last one: apps park hidden helper windows on desktops, so
  -- the window server's own list would keep every desktop. One that is
  -- showing is switched away from first, since macOS will not remove the
  -- active desktop.
  local function removeEmptied(filled, found)
    local occupied = {}
    for _, e in ipairs(found) do
      local space = spaceOfWindow(e.id)
      if space then occupied[space] = true end
    end
    local candidates = {}
    for space in pairs(vacated) do
      if not filled[hs.spaces.spaceDisplay(space)] then candidates[space] = true end
    end
    for uuid, n in pairs(filled) do
      for i, space in ipairs(userDesktops(uuid)) do
        if i > n then candidates[space] = true end
      end
    end
    local active = activeSpaces()
    for space in pairs(candidates) do
      local empty = hs.spaces.spaceType(space) == "user" and not occupied[space]
      local uuid = hs.spaces.spaceDisplay(space)
      local siblings = uuid and hs.spaces.spacesForScreen(uuid) or {}
      if empty and #siblings > 1 then
        if active[space] then
          hs.spaces.gotoSpace(siblings[1] ~= space and siblings[1] or siblings[2])
        end
        missionControlOpen = true
        hs.spaces.removeSpace(space, false)
      end
    end
  end

  local restore
  stop = function(why)
    run = run + 1
    endRun()
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, hs.mouse.absolutePosition()):post()
    if missionControlOpen then hs.spaces.closeMissionControl() end
    log("stopped: %s", why)
    hs.alert.show("Stopped partway (" .. why:match("^[^\n]*") .. ")\nDetails in ~/.hammerspoon/restore.log", 10)
  end

  -- Move every window of the apps in this display count's map to its
  -- desktop, adding desktops where a display has too few, then show each
  -- display's first desktop. Moving between desktops takes a few seconds,
  -- so this returns at once and calls `done` when finished. Returns false
  -- without a map or while a restore is already running. A restore that
  -- errors or runs past two minutes is stopped, with the mouse button let go.
  function wm.restoreSnapshot(done)
    local map = load()[key()]
    if not (map and map.displays) or running then return false end
    startRun()
    moveErrors, vacated, missionControlOpen = {}, {}, false
    log("restore %s-display map", key())
    scanWindows(guarded(function(found) restore(map, found, done) end))
    return true
  end

  restore = function(map, found, done)

    -- App name or bundle ID -> its saved windows; the desktops each display
    -- needs, counting windows placed past its summary by hand.
    local wins = windowsOf(map)
    local need = {}
    for _, list in pairs(wins) do
      for _, e in ipairs(list) do need[e.display] = math.max(need[e.display] or 0, e.desktop) end
    end

    -- Saved display -> { screen, desks } on the screen it is now.
    local place, filled, used = {}, {}, {}
    for di, d in ipairs(map.displays) do
      local s = findScreen(d, used)
      if not s then
        log("no screen for %s; its apps stay put", d.name)
      else
        local uuid = s:getUUID()
        used[uuid] = true
        local n = math.max(#d.desktops, need[di] or 0)
        local desks = userDesktops(uuid)
        while #desks < n do
          missionControlOpen = true
          if not hs.spaces.addSpaceToScreen(s, false) then break end
          desks = userDesktops(uuid)
        end
        filled[uuid] = math.max(n, 1)
        place[di] = { screen = s, desks = desks }
      end
    end

    -- Give every open window of a saved app one of its saved places: the
    -- window's own if it was open at the save, otherwise the next one left,
    -- in window order (found is oldest first), and the last one past them.
    local byApp, slotOf = {}, {}
    for _, e in ipairs(found) do
      local label = wins[e.name] and e.name or (e.bundle and wins[e.bundle] and e.bundle)
      if label then
        byApp[label] = byApp[label] or {}
        table.insert(byApp[label], e)
      end
    end
    for label, list in pairs(byApp) do
      local saved, taken = wins[label], {}
      for _, e in ipairs(list) do
        for j, s in ipairs(saved) do
          if s.id == e.id and not taken[j] then
            slotOf[e.id], taken[j] = s, true
            break
          end
        end
      end
      local j = 1
      for _, e in ipairs(list) do
        if not slotOf[e.id] then
          while taken[j] do j = j + 1 end
          slotOf[e.id], taken[j] = saved[j] or saved[#saved], true
        end
      end
    end

    local jobs, across, keys, left = {}, {}, nil, {}
    local rectOf = {}
    for _, e in ipairs(found) do
      local slot = slotOf[e.id]
      local p = slot and place[slot.display]
      local target = p and p.desks[slot.desktop]
      if not target then goto continue end
      e.target = target
      if slot.frame then rectOf[e.id] = { screen = p.screen, unit = slot.frame } end
      if e.space == target then
        log("in place: %s window %d on %s", e.name, e.id, describeSpace(target))
      elseif hs.spaces.spaceDisplay(e.space) ~= hs.spaces.spaceDisplay(target) then
        local k = e.space .. ">" .. target
        if not across[k] then
          across[k] = { source = e.space, target = target }
          jobs[#jobs + 1] = function(nextJob) moveAcross(across[k], nextJob) end
        end
        table.insert(across[k], e)
      elseif wm.noDrag[e.name] or (e.bundle and wm.noDrag[e.bundle]) then
        left[#left + 1] = e.name
      else
        keys = keys or spaceSwitchKeys()
        if keys then
          jobs[#jobs + 1] = function(nextJob) dragAlong(e, target, keys, nextJob) end
        else
          moveErrors[#moveErrors + 1] = e.name .. " (turn on Move left/right a space)"
        end
      end
      ::continue::
    end

    local function finishUp()
      removeEmptied(filled, found)
      if missionControlOpen then hs.spaces.closeMissionControl() end
      local report = {}
      if #moveErrors > 0 then
        report[#report + 1] = "Could not move to their desktop:\n" .. table.concat(moveErrors, "\n")
      end
      if #left > 0 then
        report[#report + 1] = "Left on their desktop (drag by hand):\n" .. table.concat(left, "\n")
      end
      hs.alert.show(#report > 0 and table.concat(report, "\n\n") or "Restored desktops", #report > 0 and 8 or 2)
      log("done: %s", #report > 0 and table.concat(report, " / "):gsub("\n", " ") or "all in place")
      endRun()
      if done then done() end
    end

    -- Size every window that reached its desktop. Only windows on a showing
    -- desktop can be sized, so visit each desktop that has one, those
    -- showing first.
    local function sizeWindows(nextStep)
      local spaces, listed, active = {}, {}, activeSpaces()
      for _, e in ipairs(found) do
        local space = rectOf[e.id] and spaceOfWindow(e.id)
        if space and space == e.target and not listed[space] then
          listed[space] = true
          table.insert(spaces, active[space] and 1 or #spaces + 1, space)
        end
      end
      local i = 0
      local function nextSpace()
        i = i + 1
        local space = spaces[i]
        if not space then return nextStep() end
        local function sizeHere()
          for _, e in ipairs(found) do
            local r = rectOf[e.id]
            local win = r and spaceOfWindow(e.id) == space and hs.window.get(e.id)
            if win then
              local sf, u = r.screen:frame(), r.unit
              wm.setFrame(win, { x = sf.x + u[1] * sf.w, y = sf.y + u[2] * sf.h, w = u[3] * sf.w, h = u[4] * sf.h })
            end
          end
          nextSpace()
        end
        if activeSpaces()[space] then return sizeHere() end
        hs.spaces.gotoSpace(space)
        after(0.8, sizeHere)
      end
      nextSpace()
    end

    -- End the same way every time: each display shows its first desktop.
    local function finish()
      sizeWindows(function()
        local firsts = {}
        for uuid in pairs(filled) do firsts[uuid] = userDesktops(uuid)[1] end
        showSpaces(firsts, finishUp)
      end)
    end

    if #jobs > 0 then hs.alert.show("Moving windows between desktops, hands off the mouse", 3) end
    local i = 0
    local function nextJob()
      i = i + 1
      if jobs[i] then jobs[i](nextJob) else finish() end
    end
    nextJob()
  end

  local cac = { "ctrl", "alt", "cmd" }
  local function saveKey(fresh)
    return function()
      if not wm.saveSnapshot(fresh) then hs.alert.show("Still busy, hands off the mouse") end
    end
  end
  wm.hotkey(cac, "s", saveKey(false))
  wm.hotkey({ "ctrl", "alt", "cmd", "shift" }, "s", saveKey(true))
  wm.hotkey(cac, "r", function()
    if running then
      hs.alert.show("Still busy, hands off the mouse")
    elseif not wm.restoreSnapshot() then
      hs.alert.show("No " .. key() .. "-display desktops saved yet (ctrl+alt+cmd+s)")
    end
  end)
end
