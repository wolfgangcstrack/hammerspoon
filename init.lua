-- Hammerspoon config: window management ported from slate/.slate.
--
-- Slate bindings keep their key combinations, so muscle memory carries over,
-- except ctrl+1-4: the ctrl+cmd arrows' section grid does their job. Machine-local overrides live in ~/.hammerspoon/init.local.lua (start
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

-- Sections: three columns (a quarter, a half and a quarter of the screen
-- wide) by two rows (half the height each). ctrl+cmd+arrows move a window
-- one section at a time. Outside the grid, left/right push to that edge at
-- full height, and repeated presses cycle the width through half, quarter
-- and three quarters, flush to the edge. Pushing out past the grid's left or
-- right edge cycles a half-height window through the other two of three
-- quarters, a half and a quarter of the screen's width, narrowing and
-- wrapping from a quarter to three, then lands on that full-height half. Up/down halve a
-- full-height edge column's height and keep its width; any other window
-- drops into the top or bottom section of the column on the side it is
-- flush with, or the middle one if neither. Pressing up again in a top section (or down in a bottom
-- one) widens it to the full-width top (or bottom) half; up/down from there
-- swap halves. Pressing the other arrow while one is still held
-- (left+right) centers the half-width, full-height column.
local gridCols = { { 0, 0.25 }, { 0.25, 0.5 }, { 0.75, 0.25 } }
local edgeWidths = { 0.5, 0.25, 0.75 }
local wideWidths = { 0.5, 0.75 }
local function cellRect(c, r)
  return { gridCols[c][1], (r - 1) * 0.5, gridCols[c][2], 0.5 }
end
local function edgeRect(key, w) return { key == "right" and 1 - w or 0, 0, w, 1 } end

-- Where the last move left each window. A section or a quarter of a laptop
-- screen is narrower than many apps' minimum width, so the window lands
-- wider than asked and a frame check can't recognise it; the remembered
-- frame still can.
local placed = {}
local function place(win, rect, state)
  win:moveToUnit(rect)
  state.frame = win:frame()
  placed[win:id()] = state
end
local function toCell(win, c, r) place(win, cellRect(c, r), { cell = { c, r } }) end
local function toWide(win, key, r, i, steps)
  local w = wideWidths[i]
  place(win, { key == "right" and 1 - w or 0, (r - 1) * 0.5, w, 0.5 },
    { wide = key, r = r, i = i, steps = steps })
end
local function toBand(win, r) place(win, { 0, (r - 1) * 0.5, 1, 0.5 }, { band = r }) end
local function toEdge(win, key, i)
  place(win, edgeRect(key, edgeWidths[i]), { edge = key, i = i })
end

local function stateOf(win)
  local last = placed[win:id()]
  if last and last.frame:equals(win:frame()) then return last end
  for c = 1, #gridCols do
    for r = 1, 2 do
      if wm.atUnit(win, table.unpack(cellRect(c, r))) then return { cell = { c, r } } end
    end
  end
  for r = 1, 2 do
    if wm.atUnit(win, 0, (r - 1) * 0.5, 1, 0.5) then return { band = r } end
    for _, key in ipairs({ "left", "right" }) do
      for i, w in ipairs(wideWidths) do
        if wm.atUnit(win, key == "right" and 1 - w or 0, (r - 1) * 0.5, w, 0.5) then
          return { wide = key, r = r, i = i }
        end
      end
    end
  end
  for _, key in ipairs({ "left", "right" }) do
    for i, w in ipairs(edgeWidths) do
      if wm.atUnit(win, table.unpack(edgeRect(key, w))) then return { edge = key, i = i } end
    end
  end
  return {}
end

-- One outward press on a half-height window flush with `key`'s side, now
-- at width `j` of a quarter, half and three quarters (the corner section is
-- the quarter). `steps` is how many presses are left before the full-height
-- half; a window that arrived any other way gets the full cycle.
local function outward(win, key, r, j, steps)
  steps = steps or #wideWidths
  if steps == 0 then return toEdge(win, key, 1) end
  j = (j - 2) % (#wideWidths + 1) + 1 -- narrower; a quarter wraps to three quarters
  if j > 1 then return toWide(win, key, r, j - 1, steps - 1) end
  local c = key == "left" and 1 or 3
  place(win, cellRect(c, r), { cell = { c, r }, steps = steps - 1 })
end

local heldArrows = {}
local function sideways(key, other, dc)
  wm.hotkey(cc, key, function()
    heldArrows[key] = true
    local win = hs.window.focusedWindow()
    if not win then return end
    if heldArrows[other] then return win:moveToUnit({ 0.25, 0, 0.5, 1 }) end
    local st = stateOf(win)
    if st.cell then
      local c = st.cell[1] + dc
      if gridCols[c] then return toCell(win, c, st.cell[2]) end
      return outward(win, key, st.cell[2], 1, st.steps)
    end
    if st.wide then
      -- Back inward from a widened corner: the middle section of that row.
      if st.wide ~= key then return toCell(win, 2, st.r) end
      return outward(win, key, st.r, st.i + 1, st.steps)
    end
    toEdge(win, key, st.edge == key and st.i % #edgeWidths + 1 or 1)
  end, function() heldArrows[key] = nil end)
end
sideways("right", "left", 1)
sideways("left", "right", -1)

local function vertical(key, r)
  wm.bind(cc, key, function(win)
    local st = stateOf(win)
    local row = st.cell and st.cell[2] or st.r
    if st.band or row == r then return toBand(win, r) end
    if st.wide then return toWide(win, st.wide, r, st.i) end
    if st.cell then return toCell(win, st.cell[1], r) end
    -- A full-height edge column keeps its width: a quarter is the corner
    -- section, a half or three quarters a widened one.
    if st.edge then
      local w = edgeWidths[st.i]
      for i, ww in ipairs(wideWidths) do
        if ww == w then return toWide(win, st.edge, r, i) end
      end
      return toCell(win, st.edge == "left" and 1 or 3, r)
    end
    local s, f = win:screen():frame(), win:frame()
    local left = f.x <= s.x + 0.02 * s.w
    local right = f.x + f.w >= s.x + s.w - 0.02 * s.w
    toCell(win, left and not right and 1 or right and not left and 3 or 2, r)
  end)
end
vertical("up", 1)
vertical("down", 2)

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
