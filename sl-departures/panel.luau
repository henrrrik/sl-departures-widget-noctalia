--!nonstrict
-- Panel: the full departure board for whichever widget was clicked, the
-- stop's service messages, and a searchable stop picker.
--
-- The panel owns no fetching. Widgets publish their boards on the plugin
-- state channel under a board key and mark the one they opened the panel
-- for as "active"; this script watches that key and re-renders on change.
-- Picking a stop writes stop.json in the plugin data directory and
-- announces it on the channel, and every widget without a fixed site_id
-- follows.

local M = require("./model.luau")

local panelCount = M.clamp(M.intOr(noctalia.getConfig("panel_count"), 12), 1, 40)

local dataDir = noctalia.pluginDataDir()
local STOP_FILE = dataDir and (dataDir .. "/stop.json") or nil
local SITES_FILE = dataDir and (dataDir .. "/sites.json") or nil
local SITES_MAX_AGE = 7 * 86400

local isOpen = false
local activeKey = ""
local board = nil
local watched = {}

local picking = false
local query = ""
local suggestions = {}
local sites = nil
local sitesLoading = false
local sitesError = ""
local saveError = ""

local render

-- --------------------------------------------------------------- boards

local function readBoard()
  if activeKey == "" then
    return nil
  end
  local value = noctalia.state.get(activeKey)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

local function watchBoard(key)
  if key == "" or watched[key] then
    return
  end
  watched[key] = true
  noctalia.state.watch(key, function(value)
    if key ~= activeKey then
      return
    end
    board = type(value) == "table" and value or nil
    if isOpen then
      render()
    end
  end)
end

local function activate(key)
  activeKey = tostring(key or "")
  board = readBoard()
  watchBoard(activeKey)
end

noctalia.state.watch("active", function(value)
  activate(value)
  if isOpen then
    render()
  end
end)

local function requestRefresh()
  if activeKey ~= "" then
    noctalia.state.set("refresh", { key = activeKey, at = noctalia.nowMs() })
  end
end

-- ---------------------------------------------------------------- picker

local function updateSuggestions()
  if sites == nil then
    suggestions = {}
    return
  end
  suggestions = M.searchIndex(sites, query, 8)
end

-- Sites are parsed incrementally, a few milliseconds of CPU per frame,
-- because decoding all of it in one call exceeds the CPU budget a plugin
-- callback gets. The frame tick is the only host callback that comes back
-- promptly: a changed update interval only applies after the next
-- scheduled update, which can be 15 s away.
local parse = nil
local PARSE_SLICES_PER_FRAME = 100

local function finishParse()
  local index = M.indexFinish(parse.index)
  parse = nil
  panel.setNeedsFrameTick(false)
  sitesLoading = false
  if #index.sites == 0 then
    sitesError = "The SL stop list came back empty"
    render()
    return
  end
  sites = index
  sitesError = ""
  updateSuggestions()
  render()
end

local function parseStep()
  for _ = 1, PARSE_SLICES_PER_FRAME do
    local slice, nextPos = M.nextSiteSlice(parse.raw, parse.pos)
    if slice == nil then
      finishParse()
      return
    end
    local record = M.siteRecord(noctalia.json.decode(slice))
    if record ~= nil then
      M.indexAdd(parse.index, record)
    end
    parse.pos = nextPos
  end
end

local function loadSitesFromDisk()
  local raw = SITES_FILE and noctalia.readFile(SITES_FILE) or nil
  if raw == nil then
    sitesLoading = false
    sitesError = "Could not read the SL stop list"
    render()
    return
  end
  parse = { raw = raw, pos = 1, index = M.newSiteIndex() }
  panel.setNeedsFrameTick(true)
  render()
end

local function downloadSites()
  if SITES_FILE == nil then
    sitesLoading = false
    sitesError = "No plugin data directory to cache the stop list in"
    render()
    return
  end
  local accepted = noctalia.download(M.API_BASE .. "/sites?expand=false", SITES_FILE, function(ok)
    if ok then
      loadSitesFromDisk()
    else
      sitesLoading = false
      sitesError = "Could not download the SL stop list"
      render()
    end
  end)
  if not accepted then
    sitesLoading = false
    sitesError = "Could not start the stop list download"
    render()
  end
end

-- The 1.3 MB site list is cached on disk, refreshed weekly, and parsed into
-- memory once per panel runtime, only when the picker actually opens.
local function ensureSites()
  if sites ~= nil or sitesLoading then
    return
  end
  sitesLoading = true
  sitesError = ""
  local info = SITES_FILE and noctalia.fileInfo(SITES_FILE) or nil
  local fresh = type(info) == "table" and not info.isDir and (info.size or 0) > 0
    and (os.time() - (info.mtime or 0)) < SITES_MAX_AGE
  if fresh then
    loadSitesFromDisk()
  else
    downloadSites()
  end
end

local function startPicking()
  picking = true
  query = ""
  suggestions = {}
  saveError = ""
  ensureSites()
end

local function cancelPicking()
  picking = false
  query = ""
  suggestions = {}
end

local function selectSite(site)
  if site == nil then
    return
  end
  if STOP_FILE == nil then
    saveError = "No plugin data directory to save the stop in"
    render()
    return
  end
  local encoded = noctalia.json.encode({ id = site.id, name = site.name, note = site.note })
  local ok, err = noctalia.writeFile(STOP_FILE, encoded)
  if not ok then
    saveError = "Could not save the stop: " .. tostring(err)
    render()
    return
  end
  saveError = ""
  noctalia.state.set("picked", { id = site.id, name = M.siteLabel(site), at = noctalia.nowMs() })
  cancelPicking()
  render()
end

local function onSearchChanged(value)
  query = tostring(value or "")
  updateSuggestions()
  render()
end

local function onSearchSubmit(value)
  query = tostring(value or query)
  updateSuggestions()
  if suggestions[1] ~= nil then
    selectSite(suggestions[1])
  else
    render()
  end
end

-- ---------------------------------------------------------------- render

local function ageText(ms)
  local seconds = math.max(0, math.round((noctalia.nowMs() - ms) / 1000))
  if seconds < 60 then
    return seconds .. "s ago"
  end
  return math.round(seconds / 60) .. " min ago"
end

local function hasBoard()
  return board ~= nil and (board.siteId or 0) > 0
end

local function headerBlock()
  local title, meta, glyph
  if hasBoard() then
    title = board.siteName ~= "" and board.siteName or ("Site " .. board.siteId)
    if picking then
      meta = "Search for a stop"
    elseif board.filterSummary ~= "" then
      meta = board.filterSummary
    else
      meta = "Live departures"
    end
    glyph = board.glyph or M.DEFAULT_GLYPH
  else
    title = "SL Departures"
    meta = "Search for a stop"
    glyph = M.BRAND_GLYPH
  end
  return ui.row({ align = "center", gap = 10 }, {
    ui.glyph({ name = glyph, size = 22, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 16, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = meta, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      key = "refresh", glyph = "refresh", variant = "ghost", tooltip = "Refresh",
      enabled = hasBoard() and not picking,
      onClick = function()
        requestRefresh()
        render()
      end,
    }),
    ui.button({ key = "close", glyph = "close", variant = "ghost", onClick = function()
      panel.close()
    end }),
  })
end

local function pickerBlock()
  local placeholder = "Stop, station or berth"
  if sitesLoading then
    placeholder = "Loading stops…"
    if parse ~= nil then
      placeholder = string.format("Loading stops… %d%%", math.floor(100 * (parse.pos - 1) / #parse.raw))
    end
  end
  local children = {
    ui.input({
      key = "stop-search",
      placeholder = placeholder,
      value = query,
      focus = true,
      enabled = not sitesLoading,
      onChange = onSearchChanged,
      onSubmit = onSearchSubmit,
    }),
  }
  if sitesError ~= "" then
    table.insert(children, ui.label({ text = sitesError, color = "error", fontSize = 12, maxLines = 3 }))
  end
  if saveError ~= "" then
    table.insert(children, ui.label({ text = saveError, color = "error", fontSize = 12, maxLines = 3 }))
  end
  if not sitesLoading and sitesError == "" and query ~= "" and #suggestions == 0 then
    table.insert(children, ui.label({ text = "No stop matches that.", color = "on_surface_variant", fontSize = 12 }))
  end
  for _, site in ipairs(suggestions) do
    table.insert(children, ui.button({
      key = "site-" .. site.id,
      text = M.siteLabel(site),
      variant = "ghost",
      contentAlign = "start",
      controlSize = "sm",
      onClick = function()
        selectSite(site)
      end,
    }))
  end
  return ui.column({ gap = 6 }, children)
end

-- A single line of the board: mode glyph, line, where it is headed, and how
-- long you have. Cancelled services stay on the board, in the error color,
-- because their absence is the information you opened the panel for.
local function departureRow(row)
  local imminent = row.minutes ~= nil and row.minutes <= 1
  local color = row.cancelled and "error" or "on_surface"
  local wait
  if row.cancelled then
    wait = "Cancelled"
  elseif row.minutes == nil then
    wait = row.clock ~= "" and row.clock or row.display
  else
    wait = row.waitLabel
  end
  local waitColor = "on_surface"
  if row.cancelled then
    waitColor = "error"
  elseif imminent then
    waitColor = "primary"
  end

  local line = {
    ui.glyph({ name = row.glyph, size = 16, color = color }),
    ui.label({ text = row.line, fontWeight = "bold", width = 44, color = color, maxLines = 1 }),
    ui.label({ text = row.destination, flexGrow = 1, color = color, maxLines = 1 }),
  }
  if row.berth ~= "" then
    table.insert(line, ui.label({ text = row.berth, fontSize = 11, color = "on_surface_variant" }))
  end
  table.insert(line, ui.label({ text = wait, fontWeight = imminent and "bold" or "medium", color = waitColor }))

  local children = { ui.row({ gap = 10, align = "center" }, line) }
  if row.deviationText ~= "" then
    table.insert(children, ui.label({
      text = row.deviationText, fontSize = 11, maxLines = 2,
      color = row.deviationLevel >= 5 and "error" or "on_surface_variant",
    }))
  end
  return ui.column({ key = row.key, gap = 2, paddingV = 4 }, children)
end

local function boardBlock()
  local children = {}
  if not hasBoard() then
    table.insert(children, ui.label({ text = "No stop selected yet.", color = "on_surface_variant", textAlign = "center" }))
    return ui.column({ gap = 4 }, children)
  end
  if board.error ~= "" then
    table.insert(children, ui.label({ text = board.error, color = "error", fontSize = 12, maxLines = 3 }))
  end
  local rows = board.rows or {}
  if #rows == 0 and board.error == "" then
    local text
    if board.fetchState == "loading" then
      text = "Loading departures…"
    else
      text = "Nothing leaving in the next " .. tostring(board.forecastMinutes) .. " minutes."
    end
    table.insert(children, ui.label({ text = text, color = "on_surface_variant", textAlign = "center" }))
  end
  for i = 1, math.min(#rows, panelCount) do
    table.insert(children, departureRow(rows[i]))
  end
  local deviations = board.stopDeviations or {}
  if #deviations > 0 then
    table.insert(children, ui.separator({ spacing = 8 }))
    table.insert(children, ui.label({ text = "SERVICE INFO", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
    for i, dev in ipairs(deviations) do
      table.insert(children, ui.label({
        key = "dev-" .. i,
        text = "• " .. tostring(dev.message or ""), fontSize = 12, maxLines = 4,
        color = (dev.importance_level or 0) >= 5 and "error" or "on_surface_variant",
      }))
    end
  end
  return ui.column({ gap = 4 }, children)
end

local function footerBlock()
  local hint
  if picking then
    hint = "Type to search · Enter picks the first match"
  elseif board ~= nil and board.fixed then
    hint = "Stop set in this widget's settings"
  elseif board ~= nil and board.fetching then
    hint = "Refreshing…"
  elseif board ~= nil and (board.lastUpdated or 0) > 0 then
    hint = "Updated " .. ageText(board.lastUpdated)
  else
    hint = ""
  end
  local canChange = not (board ~= nil and board.fixed)
  return ui.row({ align = "center", gap = 8 }, {
    ui.label({ text = hint, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
    ui.button({
      key = "change",
      text = picking and "Cancel" or "Change stop",
      controlSize = "sm",
      enabled = picking or canChange,
      onClick = function()
        if picking then
          cancelPicking()
        else
          startPicking()
        end
        render()
      end,
    }),
  })
end

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    headerBlock(),
    ui.scroll({ flexGrow = 1, gap = 4 }, { picking and pickerBlock() or boardBlock() }),
    footerBlock(),
  }))
end

-- ------------------------------------------------------------- lifecycle

function onOpen(_context)
  isOpen = true
  if parse ~= nil then
    panel.setNeedsFrameTick(true)
  end
  activate(noctalia.state.get("active"))
  picking = false
  -- A stop has to be chosen before there is anything to show, so an
  -- unconfigured widget opens straight into the picker.
  if not hasBoard() then
    startPicking()
  else
    requestRefresh()
  end
  render()
end

function onClose()
  isOpen = false
  cancelPicking()
end

-- Re-renders the "updated N ago" line while open; the board itself arrives
-- through the state watcher.
function onFrameTick(_deltaMs)
  if parse ~= nil then
    parseStep()
    -- A frame callback only comes back after the surface commits new
    -- content, so each step draws its progress to earn the next frame.
    render()
  end
end

function update()
  if isOpen then
    render()
  end
end

noctalia.setUpdateInterval(15000)
activate(noctalia.state.get("active"))
