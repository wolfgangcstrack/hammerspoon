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
-- desktop, which takes some indirection on recent macOS (see relocate()).
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

  -- The desktop on screen `s` a saved window belongs on: the same Space if it
  -- is still on that display, else the desktop in the same position there.
  -- With `create`, missing desktops are added up to that position, so the
  -- second desktop at home still has a second desktop at work.
  local function targetSpace(s, saved, create)
    if not saved then return nil end
    local order = hs.spaces.spacesForScreen(s) or {}
    for _, space in ipairs(order) do
      if space == saved.id then return space end
    end
    if not saved.index then return nil end
    while create and #order < saved.index do
      missionControlOpen = true
      if not hs.spaces.addSpaceToScreen(s, false) then break end
      order = hs.spaces.spacesForScreen(s) or {}
    end
    return order[saved.index]
  end

  -- Size and position the window on its saved screen. Moving a window onto
  -- another display lands it on whichever desktop that display is showing,
  -- which relocate() below arranges to be the right one. A window that still
  -- ends up on the wrong desktop gets one direct request to macOS, which
  -- recent versions quietly ignore for other apps' windows, so the result is
  -- checked rather than trusted.
  local function place(win, entry, create)
    local s = findScreen(entry.screen)
    if not s then return end
    local id = win:id()
    local before = spaceOfWindow(id)
    local sf, u = s:frame(), entry.unit
    wm.setFrame(win, { x = sf.x + u.x * sf.w, y = sf.y + u.y * sf.h, w = u.w * sf.w, h = u.h * sf.h })
    local space = targetSpace(s, entry.space, create)
    if space and spaceOfWindow(id) ~= space then
      hs.spaces.moveWindowToSpace(win, space)
      if spaceOfWindow(id) ~= space then moveErrors[#moveErrors + 1] = entry.name end
    end
    local after = spaceOfWindow(id)
    if before and after ~= before then vacated[before] = true end
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

  -- macOS will not let another app move a window to a different desktop, and
  -- cannot move a desktop between displays at all; only Mission Control's
  -- drag does that. Unplugging a monitor parks its desktops on the laptop,
  -- and plugging in another leaves them there. What does work is the move in
  -- place(): onto another display, into whichever desktop it is showing. Each
  -- display shows a desktop of its own, so for every (desktop the windows are
  -- on, desktop they belong on) pair across two displays, show both, then
  -- move the windows over. Showing the parked desktop is also what makes its
  -- windows reachable at all. Pairs run one after another; `done` runs last.
  -- Windows in `skip` are left alone.
  local function relocate(snap, skip, placed, done)
    local groups, order = {}, {}
    for _, e in ipairs(snap.windows) do
      local current = not skip[e.id] and spaceOfWindow(e.id)
      local s = current and e.space and hs.spaces.spaceType(current) == "user" and findScreen(e.screen)
      local target = s and targetSpace(s, e.space, true)
      if target and target ~= current then
        local k = current .. ">" .. target
        if not groups[k] then
          groups[k] = { source = current, target = target }
          order[#order + 1] = groups[k]
        end
        table.insert(groups[k], e)
      end
    end

    local i = 0
    local function nextGroup()
      i = i + 1
      local g = order[i]
      if not g then return done() end
      local across = hs.spaces.spaceDisplay(g.source) ~= hs.spaces.spaceDisplay(g.target)
      if across then
        local active = activeSpaces()
        for _, space in ipairs({ g.source, g.target }) do
          if not active[space] then hs.spaces.gotoSpace(space) end
        end
      end
      -- Let the desktops finish sliding in before reaching for their windows.
      hs.timer.doAfter(across and 0.8 or 0, function()
        for _, e in ipairs(g) do
          local win = hs.window.get(e.id)
          if win and not win:isMinimized() then
            place(win, e, true)
            placed[e.id] = true
          elseif not win then
            -- Same display as its desktop, which cannot be shown alongside.
            moveErrors[#moveErrors + 1] = e.name
          end
        end
        nextGroup()
      end)
    end
    nextGroup()
  end

  -- Remove the desktops this restore emptied, which would otherwise pile up
  -- on the laptop with every dock. Only a regular desktop with no window of
  -- its own left goes (windows shown on every desktop do not count), and
  -- never a display's last one. One that is showing is switched away from
  -- first, since macOS will not remove the active desktop.
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

  -- Put windows back where this display count's snapshot has them. Windows
  -- are matched by ID, which holds while the app stays open; after an app
  -- restart, by title, then by the app's remaining saved slots in order.
  -- Windows in `skip` (by ID) are left alone. With `relocateFirst`, windows
  -- on the wrong desktop, showing or not, are moved to theirs first; that
  -- part is asynchronous, so `done(placed)` is called when everything is in
  -- place. Returns nil without a snapshot, else the (still filling) set of
  -- placed IDs.
  function wm.restoreSnapshot(skip, relocateFirst, done)
    local snap = load()[key()]
    if not snap then return nil end
    skip = skip or {}
    moveErrors, vacated, missionControlOpen = {}, {}, false
    local placed = {}

    local function placeVisible()
      local live = liveIds() or {}
      local byId, used, leftover = {}, {}, {}
      for _, e in ipairs(snap.windows) do byId[e.id] = e end

      for _, win in ipairs(visibleWindows()) do
        local id = win:id()
        if not skip[id] and not placed[id] then
          if byId[id] then
            place(win, byId[id])
            used[byId[id]], placed[id] = true, true
          else
            leftover[#leftover + 1] = win
          end
        end
      end

      local function claim(win, test)
        local app = win:application()
        app = app:bundleID() or app:name()
        for _, e in ipairs(snap.windows) do
          if not used[e] and not live[e.id] and e.app == app and test(e) then
            place(win, e)
            used[e], placed[win:id()] = true, true
            return true
          end
        end
      end
      for _, win in ipairs(leftover) do
        local title = win:title()
        local _ = claim(win, function(e) return title ~= "" and e.title == title end)
          or claim(win, function() return true end)
      end

      removeEmptied()
      if missionControlOpen then hs.spaces.closeMissionControl() end
      if #moveErrors > 0 then
        hs.alert.show("Could not move to their desktop (drag in Mission Control):\n"
          .. table.concat(moveErrors, "\n"), 8)
      end
      if done then done(placed) end
    end

    if relocateFirst then relocate(snap, skip, placed, placeVisible) else placeVisible() end
    return placed
  end

  -- After a display change, any window the first pass could not reach gets
  -- another try each time you switch desktops. A window is only
  -- restored once per display change, so moving it by hand afterwards
  -- sticks. `busy` covers a restore in progress, whose own desktop switches
  -- fire the watcher too.
  local restored, busy
  function wm.restoreForDisplayChange()
    busy, restored = true, {}
    local placed = wm.restoreSnapshot(nil, true, function(p)
      for id in pairs(p) do restored[id] = true end
      hs.timer.doAfter(1, function() busy = false end)
    end)
    if not placed then busy, restored = false, nil end
    return placed ~= nil
  end

  wm.spacesWatcher = hs.spaces.watcher.new(function()
    if not restored or busy then return end
    -- Spaces animate in; give the new desktop's windows a moment to settle.
    hs.timer.doAfter(0.5, function()
      if busy then return end
      busy = true
      wm.restoreSnapshot(restored, true, function(p)
        for id in pairs(p) do restored[id] = true end
        hs.timer.doAfter(1, function() busy = false end)
      end)
    end)
  end):start()

  local cac = { "ctrl", "alt", "cmd" }
  wm.hotkey(cac, "s", function() wm.saveSnapshot(false) end)
  wm.hotkey({ "ctrl", "alt", "cmd", "shift" }, "s", function() wm.saveSnapshot(true) end)
  wm.hotkey(cac, "r", function()
    if wm.restoreForDisplayChange() then
      hs.alert.show("Restored windows")
    else
      hs.alert.show("No " .. key() .. "-display snapshot saved yet")
    end
  end)
end
