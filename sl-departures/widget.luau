--!nonstrict
-- Bar widget: fetches the departures for this instance's stop, keeps the
-- board counting down between fetches, draws the bar capsule, and publishes
-- the board on the plugin state channel for the panel.
--
-- Every entry runs in its own VM, so there is no shared hub: each widget
-- instance fetches its own stop. Instances with the same stop and filters
-- publish under the same board key, which keeps the panel indifferent to
-- how many bars mount the widget.
--
-- Which stop:
--   1. the `site_id` widget setting, when set; or
--   2. the stop picked in the panel, saved in the plugin data directory.
-- Plugins cannot write their own settings, so the picker persists there.

local M = require("./model.luau")

local config = M.resolveConfig(function(key)
  return noctalia.getConfig(key)
end)

local dataDir = noctalia.pluginDataDir()
local STOP_FILE = dataDir and (dataDir .. "/stop.json") or nil

local function readPicked()
  if STOP_FILE == nil then
    return nil
  end
  local raw = noctalia.readFile(STOP_FILE)
  if raw == nil then
    return nil
  end
  local value = noctalia.json.decode(raw)
  if type(value) ~= "table" or tonumber(value.id) == nil then
    return nil
  end
  return { id = M.intOr(value.id, 0), name = M.plain(value.name) }
end

local picked = readPicked()

-- ------------------------------------------------------------ board state

local siteId = 0
local siteName = ""
local url = ""
local boardKey = ""

local function freshHub()
  return {
    departures = {},
    shaped = {},
    stopDeviations = {},
    hasPayload = false,
    lastUpdated = 0,
    clockOffset = 0,
    clockAnchored = false,
    error = "",
    fetching = false,
    fetchStarted = 0,
    nextDue = 0,
    rows = {},
    fetchState = "idle",
  }
end

local hub = freshHub()
local publishedSignature = ""

local function now()
  return noctalia.nowMs()
end

local function resolveSite()
  if config.siteId > 0 then
    siteId = config.siteId
    siteName = ""
  elseif picked ~= nil and picked.id > 0 then
    siteId = picked.id
    siteName = picked.name
  else
    siteId = 0
    siteName = ""
  end

  local nextUrl = siteId > 0 and M.departuresUrl(config, siteId) or ""
  if nextUrl ~= url then
    -- The rows on screen were derived from the old stop's payload; keeping
    -- them under the new name until the new fetch lands would present
    -- another stop's times as current.
    url = nextUrl
    hub = freshHub()
    publishedSignature = ""
  end

  local nextKey = siteId > 0 and M.boardKey(config, siteId) or ""
  if nextKey ~= boardKey then
    -- Follow the panel along: if it was showing this widget's board, point it
    -- at the new one so a picked stop shows up without a second click.
    local active = noctalia.state.get("active")
    if active == nil or active == boardKey then
      noctalia.state.set("active", nextKey)
    end
    boardKey = nextKey
  end
end

local function currentSiteName()
  if siteName ~= "" then
    return siteName
  end
  if hub.rows[1] ~= nil and hub.rows[1].stopName ~= "" then
    return hub.rows[1].stopName
  end
  if siteId > 0 then
    return "Site " .. siteId
  end
  return "No stop selected"
end

-- Re-derives the rows from the parsed payload against the anchored clock.
-- Cheap enough to run every tick: the parse happened once, at fetch time.
local function recompute()
  if not hub.hasPayload then
    hub.rows = {}
    if siteId <= 0 then
      hub.fetchState = "idle"
    elseif hub.error ~= "" then
      hub.fetchState = "error"
    else
      hub.fetchState = "loading"
    end
    return
  end
  local rows = M.filterRows(M.timeRows(hub.shaped, now() + hub.clockOffset), config)
  if not M.sameRows(hub.rows, rows) then
    hub.rows = rows
  end
  hub.fetchState = "ready"
end

-- Publishes the board for the panel. Skipped when nothing the panel shows
-- has changed, since every set() copies the table into the channel.
local function publish()
  if boardKey == "" then
    return
  end
  local signature = table.concat({
    hub.fetchState, hub.error, tostring(hub.lastUpdated), tostring(hub.fetching),
    tostring(#hub.rows), hub.rows[1] and hub.rows[1].key or "", hub.rows[1] and hub.rows[1].minutesText or "",
    hub.rows[#hub.rows] and hub.rows[#hub.rows].key or "", currentSiteName(),
  }, "|")
  -- A middle row can change (a delay) while the ends stay put; the tick
  -- count in the signature bounds how long that goes unpublished.
  signature = signature .. "|" .. math.floor(now() / 60000)
  if signature == publishedSignature then
    return
  end
  publishedSignature = signature
  noctalia.state.set(boardKey, {
    key = boardKey,
    siteId = siteId,
    siteName = currentSiteName(),
    fixed = config.siteId > 0,
    filterSummary = M.filterSummary(config),
    forecastMinutes = config.forecastMinutes,
    glyph = hub.rows[1] and hub.rows[1].glyph or M.DEFAULT_GLYPH,
    rows = table.move(hub.rows, 1, math.min(#hub.rows, 40), 1, {}),
    stopDeviations = hub.stopDeviations,
    lastUpdated = hub.lastUpdated,
    error = hub.error,
    fetchState = hub.fetchState,
    fetching = hub.fetching,
  })
end

local function render()
  local hasSite = siteId > 0
  local barRows = M.barRows(hub.rows, config)
  local glyph = M.BRAND_GLYPH
  if hasSite then
    glyph = barRows[1] and barRows[1].glyph or M.DEFAULT_GLYPH
  end
  local children = {}
  if barWidget.isVertical() then
    if config.showIcon then
      table.insert(children, ui.glyph({ name = glyph, size = 14 }))
    end
    for i, line in ipairs(M.verticalBarLines(barRows, config, hub.fetchState, hasSite)) do
      table.insert(children, ui.label({ key = "line-" .. i, text = line }))
    end
    barWidget.render(ui.column({ gap = 2, align = "center" }, children))
  else
    if config.showIcon then
      table.insert(children, ui.glyph({ name = glyph, size = 14 }))
    end
    table.insert(children, ui.label({ key = "text", text = M.barText(barRows, config, hub.fetchState, hasSite) }))
    barWidget.render(ui.row({ gap = 6, align = "center" }, children))
  end
  barWidget.setTooltip(M.tooltipRows(hub.rows, currentSiteName(), hasSite))
end

-- ------------------------------------------------------------------ fetch

local function applyPayload(body)
  local data = noctalia.json.decode(body)
  local ok, departures, stopDeviations, err = M.parseDepartures(data)
  if not ok then
    hub.error = err
    return
  end
  hub.departures = departures
  hub.shaped = M.shapeDepartures(departures)
  hub.stopDeviations = stopDeviations
  hub.hasPayload = true
  hub.lastUpdated = now()
  hub.error = ""

  local offset = M.clockOffset(departures, now())
  if M.saneClockOffset(offset) then
    hub.clockOffset = offset
    hub.clockAnchored = true
  elseif not hub.clockAnchored then
    -- No anchor yet: the machine clock, which is right for the
    -- Stockholm-based machines this widget is for.
    hub.clockOffset = 0
  end
end

local function fetch()
  if url == "" or hub.fetching then
    return
  end
  hub.fetching = true
  hub.fetchStarted = now()
  local requestUrl = url
  local accepted = noctalia.http({
    url = requestUrl,
    method = "GET",
    headers = { "Accept: application/json" },
    follow_redirects = false,
  }, function(res)
    if requestUrl ~= url then
      -- The stop changed while this request was in flight.
      return
    end
    hub.fetching = false
    hub.nextDue = now() + config.refreshSeconds * 1000
    if type(res) ~= "table" or not res.ok then
      -- The last good departures are kept: a stale board that keeps
      -- counting down beats a blank one.
      hub.error = "Could not reach SL"
    elseif res.status ~= 200 then
      hub.error = "SL answered HTTP " .. tostring(res.status)
    else
      applyPayload(res.body or "")
    end
    recompute()
    publish()
    render()
  end)
  if not accepted then
    hub.fetching = false
    hub.error = "Could not start the request"
    hub.nextDue = now() + config.refreshSeconds * 1000
  end
end

-- ------------------------------------------------------------- lifecycle

function update()
  local t = now()
  if hub.fetching and t - hub.fetchStarted > 30000 then
    hub.fetching = false
    hub.error = "Fetch timed out"
    hub.nextDue = t + config.refreshSeconds * 1000
  end
  if url ~= "" and not hub.fetching and t >= hub.nextDue then
    fetch()
  end
  recompute()
  publish()
  render()
end

function onClick()
  noctalia.state.set("active", boardKey)
  publish()
  noctalia.togglePanel(M.PANEL_ID)
end

function onRightClick()
  hub.nextDue = 0
  update()
end

function onIpc(event, _payload)
  if event == "refresh" then
    hub.nextDue = 0
    update()
  end
end

-- The panel picked a stop. Only instances without a fixed site_id follow.
noctalia.state.watch("picked", function(value)
  if type(value) ~= "table" then
    return
  end
  picked = { id = M.intOr(value.id, 0), name = M.plain(value.name) }
  resolveSite()
  update()
end)

-- The panel asked for a refresh of the board it is showing.
noctalia.state.watch("refresh", function(value)
  if type(value) == "table" and boardKey ~= "" and value.key == boardKey then
    hub.nextDue = 0
    update()
  end
end)

noctalia.setUpdateInterval(15000)
resolveSite()
update()
