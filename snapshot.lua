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

  -- Which desktop each saved window goes to now. Windows saved on one desktop
  -- stay together and apart from the others. Saved desktops are matched in
  -- their saved order: to the same Space if it is still on that display;
  -- else to the desktop where most of their windows already are, such as one
  -- parked on the laptop when a monitor went away, so nothing has to move;
  -- else to the desktop in the same position, unless another saved desktop
  -- has it; else to a new desktop. Returns entry -> Space ID.
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

    local assigned = {}
    for _, b in pairs(byScreen) do
      table.sort(b.order, function(x, y)
        return (x.saved.index or math.huge) < (y.saved.index or math.huge)
      end)
      local desks = hs.spaces.spacesForScreen(b.screen) or {}
      local taken = {}
      for _, g in ipairs(b.order) do
        if indexOf(desks, g.saved.id) then g.space, taken[g.saved.id] = g.saved.id, true end
      end
      -- Where windows already sit, the saved desktop with the most of them
      -- there gets that desktop, so a stray window cannot claim it.
      local claims = {}
      for _, g in ipairs(b.order) do
        if not g.space then
          local count = {}
          for _, e in ipairs(g.entries) do
            local cur = spaceOfWindow(e.id)
            if indexOf(desks, cur) and not taken[cur] and hs.spaces.spaceType(cur) == "user" then
              count[cur] = (count[cur] or 0) + 1
            end
          end
          for space, n in pairs(count) do claims[#claims + 1] = { g = g, space = space, n = n } end
        end
      end
      table.sort(claims, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        return (x.g.saved.index or math.huge) < (y.g.saved.index or math.huge)
      end)
      for _, c in ipairs(claims) do
        if not c.g.space and not taken[c.space] then c.g.space, taken[c.space] = c.space, true end
      end
      for _, g in ipairs(b.order) do
        if not g.space then
          local at = g.saved.index and desks[g.saved.index]
          if at and not taken[at] then
            g.space = at
          else
            missionControlOpen = true
            if hs.spaces.addSpaceToScreen(b.screen, false) then
              desks = hs.spaces.spacesForScreen(b.screen) or {}
              g.space = desks[#desks]
            end
          end
          if g.space then taken[g.space] = true end
        end
        for _, e in ipairs(g.entries) do assigned[e] = g.space end
      end
    end
    return assigned
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

  -- Apps the desktop drag below leaves alone: their tabs sit in the title bar,
  -- where a grab can pull a tab out into a new window instead. Their windows
  -- stay on whatever desktop they are on. init.local.lua can edit this.
  wm.noDrag = {
    ["com.google.Chrome"] = true, ["com.google.chrome.for.testing"] = true,
    ["com.brave.Browser"] = true, ["com.microsoft.edgemac"] = true,
    ["company.thebrowser.Browser"] = true, ["org.mozilla.firefox"] = true,
    ["com.apple.Safari"] = true,
  }

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
      return { mods = mods, key = hs.keycodes.map[p[2]] }
    end
    local left = keyFor(79, { mods = { "ctrl" }, key = "left" })
    local right = keyFor(81, { mods = { "ctrl" }, key = "right" })
    return left and right and { left = left, right = right }
  end

  local function after(delay, fn) hs.timer.doAfter(delay, fn) end

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
        if spaceOfWindow(e.id) == group.target then
          vacated[group.source] = true
        else
          moveErrors[#moveErrors + 1] = e.name
        end
      end
      nextJob()
    end)
  end

  -- On one display: what a person does by hand. Hold the window by its title
  -- bar, just right of the green zoom button, press the "Move left/right a
  -- space" shortcut until the target desktop is showing, and let go; the
  -- window travels along. The pointer goes back where it was afterwards.
  local function dragAlong(e, target, keys, nextJob)
    local source = spaceOfWindow(e.id)
    if not activeSpaces()[source] then hs.spaces.gotoSpace(source) end
    after(0.8, function()
      local win = hs.window.get(e.id)
      local zoom = win and win:zoomButtonRect()
      local desks = hs.spaces.spacesForScreen(hs.spaces.spaceDisplay(source)) or {}
      local from, to = indexOf(desks, source), indexOf(desks, target)
      if not (zoom and from and to) then
        moveErrors[#moveErrors + 1] = e.name
        return nextJob()
      end
      local ev, types = hs.eventtap.event, hs.eventtap.event.types
      local grab = { x = zoom.x + zoom.w + 6, y = zoom.y + zoom.h / 2 }
      local held = { x = grab.x + 2, y = grab.y }
      local pointer = hs.mouse.absolutePosition()
      local key = to > from and keys.right or keys.left
      win:focus()
      ev.newMouseEvent(types.leftMouseDown, grab):post()
      after(0.15, function()
        ev.newMouseEvent(types.leftMouseDragged, held):post()
        local steps = math.abs(to - from)
        local function step()
          if steps == 0 then
            return after(0.4, function()
              ev.newMouseEvent(types.leftMouseUp, held):post()
              hs.mouse.absolutePosition(pointer)
              after(0.4, function()
                if spaceOfWindow(e.id) == target then
                  vacated[source] = true
                  local moved = hs.window.get(e.id)
                  if moved then place(moved, e) end
                else
                  moveErrors[#moveErrors + 1] = e.name
                end
                nextJob()
              end)
            end)
          end
          steps = steps - 1
          hs.eventtap.keyStroke(key.mods, key.key, 0)
          after(0.5, step)
        end
        step()
      end)
    end)
  end

  -- Remove the desktops this restore emptied, which would otherwise pile up
  -- with every dock and undock. Only a regular desktop with no window of its
  -- own left goes (windows shown on every desktop do not count), and never a
  -- display's last one. One that is showing is switched away from first,
  -- since macOS will not remove the active desktop.
  local function removeEmptied()
    local active = activeSpaces()
    for space in pairs(vacated) do
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
  -- snapshot or while a restore is already running.
  local running = false
  function wm.restoreSnapshot(done)
    local snap = load()[key()]
    if not snap or running then return false end
    running = true
    moveErrors, vacated, missionControlOpen = {}, {}, false
    local left = {}

    local jobs, across, keys = {}, {}, nil
    for e, target in pairs(assignDesktops(snap)) do
      local current = spaceOfWindow(e.id)
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

    -- Position whatever is showing. Saved windows match by ID; windows the
    -- snapshot does not know (an app restarted since) claim a saved slot of
    -- their app whose window is gone, by title first.
    local live = liveIds() or {}
    local byId, used, positioned = {}, {}, {}
    for _, e in ipairs(snap.windows) do byId[e.id] = e end
    local function placeShowing()
      local leftover = {}
      for _, win in ipairs(visibleWindows()) do
        local e = byId[win:id()]
        if e then
          place(win, e)
          used[e], positioned[e.id] = true, true
        elseif not positioned[win:id()] then
          leftover[#leftover + 1] = win
        end
      end
      local function claim(win, test)
        local app = win:application()
        app = app:bundleID() or app:name()
        for _, e in ipairs(snap.windows) do
          if not used[e] and not live[e.id] and e.app == app and test(e) then
            place(win, e)
            used[e], positioned[win:id()] = true, true
            return true
          end
        end
      end
      for _, win in ipairs(leftover) do
        local title = win:title()
        local _ = claim(win, function(e) return title ~= "" and e.title == title end)
          or claim(win, function() return true end)
      end
    end

    -- Each display can show one desktop at a time, and only windows on a
    -- showing desktop can be positioned, so visit every desktop that still
    -- holds an unpositioned saved window, then go back to what was showing.
    local startedOn = hs.spaces.activeSpaces() or {}
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
        for _, space in pairs(startedOn) do
          if not active[space] and not vacated[space] and hs.spaces.spaceDisplay(space) then
            hs.spaces.gotoSpace(space)
          end
        end
        after(0.5, finishUp)
      end)
    end

    finishUp = function()
      removeEmptied()
      if missionControlOpen then hs.spaces.closeMissionControl() end
      local report = {}
      if #moveErrors > 0 then
        report[#report + 1] = "Could not move to their desktop:\n" .. table.concat(moveErrors, "\n")
      end
      if #left > 0 then
        report[#report + 1] = "Left on their desktop (drag by hand):\n" .. table.concat(left, "\n")
      end
      hs.alert.show(#report > 0 and table.concat(report, "\n\n") or "Restored windows", #report > 0 and 8 or 2)
      running = false
      if done then done() end
    end

    if #jobs > 0 then hs.alert.show("Moving windows between desktops, hands off the mouse", 3) end
    local i = 0
    local function nextJob()
      i = i + 1
      if jobs[i] then jobs[i](nextJob) else finish() end
    end
    nextJob()
    return true
  end

  local cac = { "ctrl", "alt", "cmd" }
  wm.hotkey(cac, "s", function() wm.saveSnapshot(false) end)
  wm.hotkey({ "ctrl", "alt", "cmd", "shift" }, "s", function() wm.saveSnapshot(true) end)
  wm.hotkey(cac, "r", function()
    if not wm.restoreSnapshot() and not running then
      hs.alert.show("No " .. key() .. "-display snapshot saved yet")
    end
  end)
end
