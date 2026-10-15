-- Hammerspoon config: window management ported from slate/.slate.
--
-- Every Slate binding keeps its key combination, so muscle memory carries
-- over. Machine-local overrides live in ~/.hammerspoon/init.local.lua (start
-- from init.local.lua.example), which is loaded LAST: Hammerspoon lets the
-- most recently bound hotkey shadow an earlier one on the same combination
-- and logs it in the console, the opposite of Slate's first-bind-wins.
--
-- Deliberately absent, to keep this easy to justify on a company laptop:
-- hs.ipc (it lets any local process run Lua with Hammerspoon's Accessibility
-- rights), third-party Spoons, and crash-report uploads.

hs.uploadCrashData(false)
hs.autoLaunch(true)
-- Slate moved windows instantly; Hammerspoon animates unless told not to.
hs.window.animationDuration = 0

local wm = {}

-- Slate's `config defaultToCurrentScreen true`: every operation acts on the
-- screen the window is already on. Its resize and nudge steps were
-- percentages of that screen (`resizePercentOf`/`nudgePercentOf screenSize`),
-- not of the window, so the deltas below are fractions of the screen frame.

function wm.resize(dw, dh)
  return function(win)
    local s, f = win:screen():frame(), win:frame()
    f.w, f.h = f.w + dw * s.w, f.h + dh * s.h
    win:setFrame(f)
  end
end

function wm.nudge(dx, dy)
  return function(win)
    local s, f = win:screen():frame(), win:frame()
    f.x, f.y = f.x + dx * s.w, f.y + dy * s.h
    win:setFrame(f)
  end
end

-- Grow (or, with a negative step, shrink) by `d` of the screen in both
-- dimensions while keeping the window's center fixed. Slate spelled this as a
-- resize-then-nudge sequence.
function wm.grow(d)
  return function(win)
    local s, f = win:screen():frame(), win:frame()
    f.x, f.y = f.x - d / 2 * s.w, f.y - d / 2 * s.h
    f.w, f.h = f.w + d * s.w, f.h + d * s.h
    win:setFrame(f)
  end
end

-- Place the window on a unit rect of its screen: push, corner and center are
-- all this with different numbers.
function wm.unit(x, y, w, h)
  return function(win) win:moveToUnit({ x, y, w, h }) end
end

-- Whether the window already sits on a unit rect of its screen. Apps that
-- size in steps (Terminal's character cells) land a little short, so allow
-- 2% of the screen either way.
function wm.atUnit(win, x, y, w, h)
  local s, f = win:screen():frame(), win:frame()
  local function near(a, b, len) return math.abs(a - b) <= 0.02 * len end
  return near(f.x, s.x + x * s.w, s.w) and near(f.y, s.y + y * s.h, s.h)
    and near(f.w, w * s.w, s.w) and near(f.h, h * s.h, s.h)
end

-- Slate numbered screens from 0 in macOS's order, primary display first,
-- which is also the order hs.screen.allScreens() returns.
function wm.screen(index)
  return hs.screen.allScreens()[index + 1]
end

-- Set a frame that may be on another screen. macOS fits the new size to the
-- screen the window is still on before moving it, so a window headed for a
-- bigger display arrives too small; once it is there, the second set sticks.
function wm.setFrame(win, f)
  win:setFrame(f)
  local got = win:frame()
  if got.w < f.w - 1 or got.h < f.h - 1 then win:setFrame(f) end
end

-- `target` is a 0-based screen index or a direction: "East", "West", "North"
-- or "South". Directions are strict, as in Slate: with displays side by side
-- there is nothing to the north. `resize` fills the destination screen, or,
-- when there is no screen that way, the window's own screen, so pressing the
-- key again on the top display maximizes there. Without `resize` the window
-- keeps its size and a throw with nowhere to go does nothing.
function wm.throw(target, resize)
  return function(win)
    local dest
    if type(target) == "number" then
      dest = wm.screen(target)
    else
      dest = win:screen()["to" .. target](win:screen(), nil, true)
    end
    if resize then
      dest = dest or win:screen()
      wm.setFrame(win, dest:frame())
    elseif dest then
      win:moveToScreen(dest, true, true)
    end
  end
end

-- Bind a hotkey, remembering any combination macOS refuses. Hammerspoon
-- returns nil without a word when the system already owns a combination (a
-- Mission Control or Keyboard Shortcuts entry), so these get reported once
-- the config has loaded instead of the key just doing nothing.
wm.failedHotkeys = {}
function wm.hotkey(mods, key, fn, releasedFn)
  local hk = hs.hotkey.bind(mods, key, fn, releasedFn)
  if not hk then
    -- Say who owns it: a macOS shortcut (even a disabled one can block the
    -- combination) or, failing that, another running app.
    local sys = hs.hotkey.systemAssigned(mods, key)
    local owner = not sys and "another app"
      or ("macOS shortcut, " .. (sys.enabled and "enabled" or "disabled"))
    wm.failedHotkeys[#wm.failedHotkeys + 1] =
      table.concat(mods, "+") .. "+" .. key .. " (" .. owner .. ")"
  end
  return hk
end

-- Bind a window operation to the focused window.
function wm.bind(mods, key, op)
  return wm.hotkey(mods, key, function()
    local win = hs.window.focusedWindow()
    if win then op(win) end
  end)
end

-- Layouts: app name -> list of operations, applied to that app's windows in
-- order (first operation to the first window, and so on), the way Slate's
-- `|` separated per-window operations. Windows beyond the list are left alone.
-- A layout is a list of these steps, run one after another, so a throw to the
-- right screen can happen before a corner placement measures that screen.
function wm.applyLayout(steps)
  for _, step in ipairs(steps) do
    for appName, ops in pairs(step) do
      local app = hs.application.get(appName)
      if app then
        for i, win in ipairs(app:allWindows()) do
          if ops[i] and win:isStandard() then ops[i](win) end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Bindings
---------------------------------------------------------------------------

local ca, cc, csa, cac = { "ctrl", "alt" }, { "ctrl", "cmd" },
  { "ctrl", "shift", "alt" }, { "ctrl", "alt", "cmd" }

-- Resize
wm.bind(ca, "right", wm.resize(0.05, 0))
wm.bind(ca, "left", wm.resize(-0.05, 0))
wm.bind(ca, "up", wm.resize(0, -0.05))
wm.bind(ca, "down", wm.resize(0, 0.05))

-- Push to an edge, full height. Repeated presses cycle the width through
-- half, quarter and three quarters of the screen, flush to that edge; from
-- anywhere else it starts at the half. Pressing the other arrow while one is
-- still held (left+right) centers the half-width, full-height column.
local heldArrows = {}
local edgeWidths = { 0.5, 0.25, 0.75 }
local function edgeCycle(key, other, flushRight)
  local function rect(w) return { flushRight and 1 - w or 0, 0, w, 1 } end
  wm.hotkey(cc, key, function()
    heldArrows[key] = true
    local win = hs.window.focusedWindow()
    if not win then return end
    if heldArrows[other] then return win:moveToUnit({ 0.25, 0, 0.5, 1 }) end
    local nextW = edgeWidths[1]
    for i, w in ipairs(edgeWidths) do
      if wm.atUnit(win, table.unpack(rect(w))) then
        nextW = edgeWidths[i % #edgeWidths + 1]
        break
      end
    end
    win:moveToUnit(rect(nextW))
  end, function() heldArrows[key] = nil end)
end
edgeCycle("right", "left", true)
edgeCycle("left", "right", false)
wm.bind(cc, "up", wm.unit(0, 0, 1, 0.5))
wm.bind(cc, "down", wm.unit(0, 0.5, 1, 0.5))

-- Nudge
wm.bind(csa, "right", wm.nudge(0.05, 0))
wm.bind(csa, "left", wm.nudge(-0.05, 0))
wm.bind(csa, "up", wm.nudge(0, -0.05))
wm.bind(csa, "down", wm.nudge(0, 0.05))

-- Throw to another screen, filling it
wm.bind(ca, "1", wm.throw(0, true))
wm.bind(ca, "2", wm.throw(1, true))
wm.bind(ca, "3", wm.throw(2, true))
wm.bind(cac, "right", wm.throw("East", true))
wm.bind(cac, "left", wm.throw("West", true))
wm.bind(cac, "up", wm.throw("North", true))
wm.bind(cac, "down", wm.throw("South", true))

-- Quarter-screen corners, numbered like Cartesian quadrants
wm.bind({ "ctrl" }, "1", wm.unit(0.5, 0, 0.5, 0.5))   -- top right
wm.bind({ "ctrl" }, "2", wm.unit(0, 0, 0.5, 0.5))     -- top left
wm.bind({ "ctrl" }, "3", wm.unit(0, 0.5, 0.5, 0.5))   -- bottom left
wm.bind({ "ctrl" }, "4", wm.unit(0.5, 0.5, 0.5, 0.5)) -- bottom right

-- Center at half size; grow or shrink around the window's center
wm.bind({ "ctrl" }, "5", wm.unit(0.25, 0.25, 0.5, 0.5))
wm.bind(ca, "space", wm.grow(0.05))
wm.bind(ca, "e", wm.grow(0.05))
wm.bind(ca, "s", wm.grow(-0.05))

-- Window hints: a letter over every window, press it to focus that window
wm.hotkey({ "cmd" }, "escape", function() hs.hints.windowHints() end)

---------------------------------------------------------------------------
-- Layouts, one per display count
---------------------------------------------------------------------------

local u = wm.unit
local topLeft, topRight = u(0, 0, 0.5, 0.5), u(0.5, 0, 0.5, 0.5)
local bottomLeft, bottomRight = u(0, 0.5, 0.5, 0.5), u(0.5, 0.5, 0.5, 0.5)
local leftHalf, rightHalf = u(0, 0, 0.5, 1), u(0.5, 0, 0.5, 1)
local center = u(0.25, 0.25, 0.5, 0.5)

-- On more than one display the chat and monitoring apps go to the last
-- screen and Chrome's first window fills the primary one.
local function multiDisplay(last)
  local throwLast = wm.throw(last)
  return {
    {
      ["Docker Desktop"] = { throwLast },
      ["Slack"] = { throwLast },
      ["Discord"] = { throwLast },
      ["Activity Monitor"] = { throwLast },
      ["Music"] = { throwLast },
      ["Google Chrome"] = { wm.throw(0, true), throwLast },
      ["Messages"] = { wm.throw(0, true) },
    },
    {
      ["Docker Desktop"] = { bottomRight },
      ["Slack"] = { bottomRight },
      ["Discord"] = { bottomRight },
      ["Activity Monitor"] = { topRight },
      ["Music"] = { topRight },
      ["Google Chrome"] = { wm.throw(0, true), leftHalf },
      ["Messages"] = { center },
    },
  }
end

wm.layouts = {
  {
    {
      ["Docker Desktop"] = { topLeft },
      ["Slack"] = { bottomRight },
      ["Discord"] = { bottomRight },
      ["Activity Monitor"] = { bottomLeft },
      ["Music"] = { topRight },
      ["Google Chrome"] = { wm.throw(0, true), rightHalf },
      ["Messages"] = { center },
    },
  },
  multiDisplay(1),
  multiDisplay(2),
}

for n = 1, 3 do
  wm.hotkey(cac, tostring(n), function() wm.applyLayout(wm.layouts[n]) end)
end

-- Desktop maps: ctrl+alt+cmd+s records which desktop each app is on,
-- ctrl+alt+cmd+r moves them back. See snapshot.lua. Nothing rearranges
-- windows on its own when a display comes or goes; the hotkeys do it when
-- asked.
require("snapshot")(wm)

---------------------------------------------------------------------------
-- Machine-local overrides and auto-reload
---------------------------------------------------------------------------

local localConfig = hs.configdir .. "/init.local.lua"
if hs.fs.attributes(localConfig) then
  local chunk, err = loadfile(localConfig)
  if chunk then chunk(wm) else hs.showError(err) end
end

-- ~/.hammerspoon/init.lua is a symlink into the dotfiles repo, and edits land
-- on the target, so watch the directory the link resolves to.
local repoDir = hs.fs.pathToAbsolute(hs.configdir .. "/init.lua"):match("(.*)/")
wm.configWatcher = hs.pathwatcher.new(repoDir, function(paths)
  for _, p in ipairs(paths) do
    if p:sub(-4) == ".lua" then return hs.reload() end
  end
end):start()

if #wm.failedHotkeys > 0 then
  hs.alert.show("Hammerspoon could not bind:\n" .. table.concat(wm.failedHotkeys, "\n"), 15)
else
  hs.alert.show("Hammerspoon config loaded")
end
