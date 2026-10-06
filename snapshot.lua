-- Window snapshots: save where every window sits, put them back later.
--
-- One snapshot per display count, so "laptop alone" and "laptop + monitor"
-- are separate arrangements. Positions are stored as fractions of the screen
-- each window was on, and screens are matched by name first, then by role
-- (built-in, or the largest external), so a snapshot taken at one desk
-- restores onto a different monitor at another.
--
-- Only windows on the Spaces currently showing can be measured, so a save
-- MERGES into the stored snapshot instead of replacing it: visit each desktop
-- and save once to cover them all. Restore also puts windows back on their own
-- desktop, which takes some indirection on recent macOS (see moveAcross() and
-- dragAlong()). Nothing runs on its own: ctrl+alt+cmd+r restores.
--
-- Stored in ~/.hammerspoon/window-snapshots.json, a real file on each machine
-- rather than a link into the repo, since the windows are this Mac's.

return function(wm)
  local path = hs.configdir .. "/window-snapshots.json"

  local function isBuiltin(screen) return screen:name():match("^Built%-in") ~= nil end
  local function area(screen) local f = screen:fullFrame() return f.w * f.h end
  local function key() return tostring(#hs.screen.allScreens()) end
  local function load() return hs.json.read(path) or {} end

  -- Windows worth saving: standard, visible on a Space that is showing, and
  -- not Hammerspoon's own console or alerts.
  local function visibleWindows()
    local r = {}
    for _, win in ipairs(hs.window.visibleWindows()) do
      local app = win:application()
      if win:isStandard() and app and app:bundleID() ~= "org.hammerspoon.Hammerspoon" then
        r[#r + 1] = win
      end
    end
    return r
  end

  -- IDs of every open window on every Space, or nil if macOS will not say.
  -- Lets a save drop windows that have since closed, and keeps a restore from
  -- handing a still-open window's slot to a different one.
  local function liveIds()
    local spaces = hs.spaces.allSpaces()
    if not spaces then return nil end
    local ids = {}
    for _, list in pairs(spaces) do
      for _, space in ipairs(list) do
        for _, id in ipairs(hs.spaces.windowsForSpace(space) or {}) do ids[id] = true end
      end
    end
    return ids
  end

  -- Which desktop a window is on: the Space ID, plus the desktop's position
  -- among its display's desktops, for restoring onto a different monitor
  -- whose Spaces have other IDs. `screenName` is the display it sits on.
  -- Works for windows on desktops that are not showing, too.
  local function spaceOf(id)
    local space = (hs.spaces.windowSpaces(id) or {})[1]
    if not space then return nil end
    local uuid = hs.spaces.spaceDisplay(space)
    local screen = uuid and hs.screen.find(uuid)
    local r = { id = space, screenName = screen and screen:name() }
    for i, s in ipairs(uuid and hs.spaces.spacesForScreen(uuid) or {}) do
      if s == space then r.index = i end
    end
    return r
  end

  local function describe(win)
    local s, f, app = win:screen(), win:frame(), win:application()
    local sf = s:frame()
    return {
      id = win:id(),
      app = app:bundleID() or app:name(),
      name = app:name(),
      title = win:title(),
      screen = { name = s:name(), builtin = isBuiltin(s) },
      space = spaceOf(win:id()),
      unit = {
        x = (f.x - sf.x) / sf.w, y = (f.y - sf.y) / sf.h,
        w = f.w / sf.w, h = f.h / sf.h,
      },
    }
  end

  local function findScreen(spec)
    local screens = hs.screen.allScreens()
    for _, s in ipairs(screens) do
      if s:name() == spec.name then return s end
    end
    local best
    for _, s in ipairs(screens) do
      if isBuiltin(s) == spec.builtin and (not best or area(s) > area(best)) then best = s end
    end
    return best
  end

  -- State for the restore in progress: windows that did not reach their
  -- desktop, for the alert; desktops windows were moved off, candidates for
  -- removal; and whether adding a desktop left Mission Control open.
  local moveErrors, vacated, missionControlOpen

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

  -- Which desktop each saved window goes to now, by position alone, so the
  -- outcome is the same whatever the starting state: a display's saved
  -- desktops, in their saved order, go to its 1st, 2nd, ... desktop, with
  -- desktops added when there are too few. Windows saved on one desktop stay
  -- together. Returns entry -> Space ID, and display UUID -> how many
  -- desktops the snapshot fills there; removeEmptied() clears out the rest.
  local function assignDesktops(snap)
    local byScreen = {}
    for _, e in ipairs(snap.windows) do
      local s = e.space and spaceOfWindow(e.id) and findScreen(e.screen)
      if s then
        local b = byScreen[s:name()] or { screen = s, groups = {}, order = {} }
        byScreen[s:name()] = b
        local k = tostring(e.space.id)
        if not b.groups[k] then
          b.groups[k] = { saved = e.space, entries = {} }
          b.order[#b.order + 1] = b.groups[k]
        end
        table.insert(b.groups[k].entries, e)
      end
    end

    local assigned, filled = {}, {}
    for _, b in pairs(byScreen) do
      table.sort(b.order, function(x, y)
        local xi, yi = x.saved.index or math.huge, y.saved.index or math.huge
        if xi ~= yi then return xi < yi end
        return x.saved.id < y.saved.id
      end)
      local desks = userDesktops(b.screen)
      while #desks < #b.order do
        missionControlOpen = true
        if not hs.spaces.addSpaceToScreen(b.screen, false) then break end
        desks = userDesktops(b.screen)
      end
      for i, g in ipairs(b.order) do
        for _, e in ipairs(g.entries) do assigned[e] = desks[i] end
      end
      filled[b.screen:getUUID()] = #b.order
    end
    return assigned, filled
  end

  -- Size and position a window on its saved screen. Moving it onto another
  -- display lands it on whichever desktop that display is showing.
  local function place(win, entry)
    local s = findScreen(entry.screen)
    if not s then return end
    local sf, u = s:frame(), entry.unit
    wm.setFrame(win, { x = sf.x + u.x * sf.w, y = sf.y + u.y * sf.h, w = u.w * sf.w, h = u.h * sf.h })
  end

  -- Save the visible windows into this display count's snapshot. `fresh`
  -- discards what was stored first, for starting an arrangement over.
  function wm.saveSnapshot(fresh)
    local data = load()
    local k = key()
    local entries, seen = {}, {}
    for _, win in ipairs(visibleWindows()) do
      local e = describe(win)
      entries[#entries + 1], seen[e.id] = e, true
    end
    local saved = #entries
    if not fresh and data[k] then
      local live = liveIds()
      for _, e in ipairs(data[k].windows) do
        if not seen[e.id] and (not live or live[e.id]) then
          -- Not showing, so its position is as saved, but its desktop can
          -- still be read. Only trust it while the window is on the same
          -- display it was saved on; a desktop that migrated to another
          -- display when a monitor was unplugged says nothing about where
          -- the window belongs.
          local space = spaceOf(e.id)
          if space and space.screenName == e.screen.name then e.space = space end
          entries[#entries + 1] = e
        end
      end
    end
    data[k] = { savedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"), windows = entries }
    hs.json.write(data, path, true, true)
    hs.alert.show(string.format("Saved %d windows (%d in the %s-display snapshot)", saved, #entries, k))
  end

  -- Apps (by bundle ID) the desktop drag below leaves alone; their windows
  -- stay on whatever desktop they are on and are reported. Empty by default:
  -- browsers keep tabs in the title bar, but grabPoint() skips tabs and other
  -- controls, and a grab that does not move the window is let go in place.
  -- init.local.lua can add to it.
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

  -- What the last restore did, step by step, in ~/.hammerspoon/restore.log:
  -- desktop moves happen out of sight and too fast to watch, and this is how
  -- to tell a shortcut that did not fire from a window that did not follow.
  -- Each line is written as it happens, so a restore that stops partway
  -- still shows how far it got.
  local logPath = hs.configdir .. "/restore.log"
  local function log(fmt, ...)
    local f = io.open(logPath, "a")
    if f then f:write(os.date("%H:%M:%S "), string.format(fmt, ...), "\n") f:close() end
  end

  -- A restore is a chain of timed steps. `run` counts restores, so a step
  -- left over from one that was stopped does nothing; an error in any step
  -- stops the restore with an alert instead of leaving it hung, since a Lua
  -- error inside a timer only reaches the Hammerspoon console.
  local running, run, stop = false, 0, nil
  local function guarded(fn)
    local mine = run
    return function()
      if mine ~= run or not running then return end
      local ok, err = xpcall(fn, debug.traceback)
      if not ok then stop("error: " .. tostring(err)) end
    end
  end
  local function after(delay, fn) hs.timer.doAfter(delay, guarded(fn)) end

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
    local active = activeSpaces()
    for _, space in ipairs({ group.source, group.target }) do
      if not active[space] then hs.spaces.gotoSpace(space) end
    end
    -- Let the desktops finish sliding in before reaching for their windows.
    after(0.8, function()
      for _, e in ipairs(group) do
        local win = hs.window.get(e.id)
        if win then place(win, e) end
        log("across %s (window %d): desktop %s -> %s, now on %s", e.name, e.id,
          tostring(group.source), tostring(group.target), tostring(spaceOfWindow(e.id)))
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
    if not activeSpaces()[source] then hs.spaces.gotoSpace(source) end
    after(0.8, function()
      local win = hs.window.get(e.id)
      local desks = hs.spaces.spacesForScreen(hs.spaces.spaceDisplay(source)) or {}
      local from, to = indexOf(desks, source), indexOf(desks, target)
      log("drag %s (window %d): desktop %s -> %s, positions %s -> %s of [%s]", e.name, e.id,
        tostring(source), tostring(target), tostring(from), tostring(to), table.concat(desks, ","))
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
        local held = grab
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
            held = { x = grab.x + dx, y = grab.y }
            ev.newMouseEvent(types.leftMouseDragged, held):post()
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
                  ev.newMouseEvent(types.leftMouseUp, held):post()
                  hs.mouse.absolutePosition(pointer)
                  after(0.4, function()
                    log("  after release: %s", where())
                    if spaceOfWindow(e.id) ~= target then
                      return fail("the window did not land on desktop " .. tostring(target))
                    end
                    vacated[source] = true
                    local moved = hs.window.get(e.id)
                    if moved then place(moved, e) end
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
  -- undock: the ones this restore emptied, and any past the number the
  -- snapshot fills on a display (`filled`, display UUID -> count). Only a
  -- regular desktop with no window of its own left goes (windows shown on
  -- every desktop do not count), and never a display's last one. One that is
  -- showing is switched away from first, since macOS will not remove the
  -- active desktop.
  local function removeEmptied(filled)
    local candidates = {}
    for space in pairs(vacated) do candidates[space] = true end
    for uuid, n in pairs(filled) do
      for i, space in ipairs(userDesktops(uuid)) do
        if i > n then candidates[space] = true end
      end
    end
    local active = activeSpaces()
    for space in pairs(candidates) do
      local empty = hs.spaces.spaceType(space) == "user"
      for _, id in ipairs(hs.spaces.windowsForSpace(space) or {}) do
        if #(hs.spaces.windowSpaces(id) or {}) == 1 then empty = false end
      end
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

  -- Put windows back where this display count's snapshot has them: first
  -- onto their desktops (the moves above, one after another), then into
  -- position. Windows are matched by ID, which holds while the app stays
  -- open; after an app restart, by title, then by the app's remaining saved
  -- slots in order. Moving between desktops takes a few seconds, so this
  -- returns at once and calls `done` when finished. Returns false without a
  -- snapshot or while a restore is already running. A restore that errors
  -- or runs past two minutes is stopped, with the mouse button let go.
  -- Pair saved windows with open ones, on every desktop. A window keeps its
  -- ID while its app stays open; after an app restart its windows have new
  -- IDs and take the app's saved slots, by title first, then largest window
  -- first (an app's small extra windows are panels and popups). Returns
  -- copies of the saved entries carrying the open window's ID; saved
  -- windows with no open match are left out.
  local function matchWindows(entries)
    local open, byId = {}, {}
    for _, w in ipairs(hs.window.list and hs.window.list(true) or {}) do
      local id, space = w.kCGWindowNumber, nil
      if w.kCGWindowLayer == 0 and id then space = spaceOfWindow(id) end
      if space and hs.spaces.spaceType(space) == "user" then
        local app = hs.application.applicationForPID(w.kCGWindowOwnerPID)
        local b = w.kCGWindowBounds or {}
        local o = { id = id, app = app and (app:bundleID() or app:name()),
          title = w.kCGWindowName or "", area = (b.Width or 0) * (b.Height or 0) }
        open[#open + 1], byId[id] = o, o
      end
    end
    table.sort(open, function(a, b) return a.area > b.area end)
    local taken, pairsFound = {}, {}
    for _, e in ipairs(entries) do
      if byId[e.id] then pairsFound[e], taken[e.id] = e.id, true end
    end
    local function claim(test)
      for _, e in ipairs(entries) do
        if not pairsFound[e] then
          for _, o in ipairs(open) do
            if not taken[o.id] and o.app == e.app and test(e, o) then
              pairsFound[e], taken[o.id] = o.id, true
              log("matched %s: saved window %d is now %d", e.name, e.id, o.id)
              break
            end
          end
        end
      end
    end
    claim(function(e, o) return o.title ~= "" and o.title == e.title end)
    claim(function() return true end)
    local r = {}
    for _, e in ipairs(entries) do
      if pairsFound[e] then
        r[#r + 1] = setmetatable({ id = pairsFound[e] }, { __index = e })
      else
        log("not open: %s (saved window %d)", e.name, e.id)
      end
    end
    return r
  end

  local watchdog, restore
  stop = function(why)
    run = run + 1
    running = false
    if watchdog then watchdog:stop() end
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, hs.mouse.absolutePosition()):post()
    if missionControlOpen then hs.spaces.closeMissionControl() end
    log("stopped: %s", why)
    hs.alert.show("Restore stopped partway (" .. why:match("^[^\n]*") .. ")\nDetails in ~/.hammerspoon/restore.log", 10)
  end

  function wm.restoreSnapshot(done)
    local snap = load()[key()]
    if not snap or running then return false end
    running, run = true, run + 1
    moveErrors, vacated, missionControlOpen = {}, {}, false
    local f = io.open(logPath, "w")
    if f then f:close() end
    watchdog = hs.timer.doAfter(120, guarded(function() stop("took over two minutes") end))
    guarded(function() restore(snap, done) end)()
    return true
  end

  restore = function(saved, done)
    log("restore %s-display snapshot (%d windows)", key(), #saved.windows)
    local snap = { windows = matchWindows(saved.windows) }
    local left = {}

    local jobs, across, keys = {}, {}, nil
    local assigned, filled = assignDesktops(snap)
    for _, e in ipairs(snap.windows) do
      local current, target = spaceOfWindow(e.id), assigned[e]
      if target and current ~= target and hs.spaces.spaceType(current) == "user" then
        if hs.spaces.spaceDisplay(current) ~= hs.spaces.spaceDisplay(target) then
          local k = current .. ">" .. target
          if not across[k] then
            across[k] = { source = current, target = target }
            jobs[#jobs + 1] = function(nextJob) moveAcross(across[k], nextJob) end
          end
          table.insert(across[k], e)
        elseif wm.noDrag[e.app] then
          left[#left + 1] = e.name
        else
          keys = keys or spaceSwitchKeys()
          if keys then
            jobs[#jobs + 1] = function(nextJob) dragAlong(e, target, keys, nextJob) end
          else
            moveErrors[#moveErrors + 1] = e.name .. " (turn on Move left/right a space)"
          end
        end
      end
    end

    -- Position whatever saved window is showing.
    local live = liveIds() or {}
    local byId, positioned = {}, {}
    for _, e in ipairs(snap.windows) do byId[e.id] = e end
    local function placeShowing()
      for _, win in ipairs(visibleWindows()) do
        local e = byId[win:id()]
        if e then place(win, e) positioned[e.id] = true end
      end
    end

    -- Each display can show one desktop at a time, and only windows on a
    -- showing desktop can be positioned, so visit every desktop that still
    -- holds an unpositioned saved window. Then show each display's first
    -- desktop, so the restore ends the same way every time.
    local function visitDesktops(done)
      local desks, seen = {}, {}
      for _, e in ipairs(snap.windows) do
        local space = not positioned[e.id] and live[e.id] and spaceOfWindow(e.id)
        if space and not seen[space] and hs.spaces.spaceType(space) == "user" then
          desks[#desks + 1], seen[space] = space, true
        end
      end
      local i = 0
      local function visitNext()
        i = i + 1
        local space = desks[i]
        if not space then return done() end
        hs.spaces.gotoSpace(space)
        after(0.8, function() placeShowing() visitNext() end)
      end
      visitNext()
    end

    local finishUp
    local function finish()
      placeShowing()
      visitDesktops(function()
        local active = activeSpaces()
        for uuid in pairs(filled) do
          local first = userDesktops(uuid)[1]
          if first and not active[first] then hs.spaces.gotoSpace(first) end
        end
        after(0.5, finishUp)
      end)
    end

    finishUp = function()
      removeEmptied(filled)
      if missionControlOpen then hs.spaces.closeMissionControl() end
      local report = {}
      if #moveErrors > 0 then
        report[#report + 1] = "Could not move to their desktop:\n" .. table.concat(moveErrors, "\n")
      end
      if #left > 0 then
        report[#report + 1] = "Left on their desktop (drag by hand):\n" .. table.concat(left, "\n")
      end
      hs.alert.show(#report > 0 and table.concat(report, "\n\n") or "Restored windows", #report > 0 and 8 or 2)
      log("done: %s", #report > 0 and table.concat(report, " / "):gsub("\n", " ") or "all restored")
      running = false
      if watchdog then watchdog:stop() end
      if done then done() end
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
  wm.hotkey(cac, "s", function() wm.saveSnapshot(false) end)
  wm.hotkey({ "ctrl", "alt", "cmd", "shift" }, "s", function() wm.saveSnapshot(true) end)
  wm.hotkey(cac, "r", function()
    if running then
      hs.alert.show("Still restoring, hands off the mouse")
    elseif not wm.restoreSnapshot() then
      hs.alert.show("No " .. key() .. "-display snapshot saved yet")
    end
  end)
end
