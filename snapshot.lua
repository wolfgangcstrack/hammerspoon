-- Window snapshots: save where every window sits, put them back later.
--
-- One snapshot per display count, so "laptop alone" and "laptop + monitor"
-- are separate arrangements. Positions are stored as fractions of the screen
-- each window was on, and screens are matched by name first, then by role
-- (built-in, or the largest external), so a snapshot taken at one desk
-- restores onto a different monitor at another.
--
-- Only windows on the Spaces currently showing are reachable, so a save
-- MERGES into the stored snapshot instead of replacing it: visit each desktop
-- and save once to cover them all. Restore follows the same limit and catches
-- up as you switch desktops (see the Spaces watcher at the bottom).
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

  local function describe(win)
    local s, f, app = win:screen(), win:frame(), win:application()
    local sf = s:frame()
    return {
      id = win:id(),
      app = app:bundleID() or app:name(),
      name = app:name(),
      title = win:title(),
      screen = { name = s:name(), builtin = isBuiltin(s) },
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

  local function place(win, entry)
    local s = findScreen(entry.screen)
    if not s then return end
    local sf, u = s:frame(), entry.unit
    win:setFrame({ x = sf.x + u.x * sf.w, y = sf.y + u.y * sf.h, w = u.w * sf.w, h = u.h * sf.h })
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
        if not seen[e.id] and (not live or live[e.id]) then entries[#entries + 1] = e end
      end
    end
    data[k] = { savedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"), windows = entries }
    hs.json.write(data, path, true, true)
    hs.alert.show(string.format("Saved %d windows (%d in the %s-display snapshot)", saved, #entries, k))
  end

  -- Put visible windows back where this display count's snapshot has them.
  -- Windows are matched by ID, which holds while the app stays open; after an
  -- app restart, by title, then by the app's remaining saved slots in order.
  -- Windows in `skip` (by ID) are left alone. Returns the IDs it placed.
  function wm.restoreSnapshot(skip)
    local snap = load()[key()]
    if not snap then return nil end
    skip = skip or {}
    local live = liveIds() or {}
    local byId, used, placed, leftover = {}, {}, {}, {}
    for _, e in ipairs(snap.windows) do byId[e.id] = e end

    for _, win in ipairs(visibleWindows()) do
      local id = win:id()
      if not skip[id] then
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
    return placed
  end

  -- After a display change, windows on desktops that are not showing yet get
  -- placed the first time you switch to them. A window is only restored once
  -- per display change, so moving it by hand afterwards sticks.
  local restored
  function wm.restoreForDisplayChange()
    restored = wm.restoreSnapshot()
    return restored ~= nil
  end

  wm.spacesWatcher = hs.spaces.watcher.new(function()
    if not restored then return end
    -- Spaces animate in; give the new desktop's windows a moment to settle.
    hs.timer.doAfter(0.5, function()
      for id in pairs(wm.restoreSnapshot(restored) or {}) do restored[id] = true end
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
