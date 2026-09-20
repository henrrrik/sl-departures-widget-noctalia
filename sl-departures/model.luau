--!nonstrict
-- Pure helpers shared by the bar widget and the panel: config resolution, SL
-- payload shaping, the clock anchor, row filtering, and the bar/tooltip text.
-- Nothing here calls the host (`noctalia.*`), so the rules can be read and
-- reasoned about without a running shell: decoded JSON tables go in, plain
-- tables come out.
--
-- Data comes from SL's open "Transport" API, which needs no key:
--   https://transport.integration.sl.se/v1/sites?expand=false
--   https://transport.integration.sl.se/v1/sites/<siteId>/departures
-- Responses are Swedish-language and Europe/Stockholm-local throughout.

local M = {}

M.API_BASE = "https://transport.integration.sl.se/v1"
M.PLUGIN_ID = "henrrrik/sl-departures"
M.PANEL_ID = M.PLUGIN_ID .. ":board"

-- SL's transport_mode values mapped to Tabler glyph names the shell draws.
M.MODE_GLYPHS = {
  BUS = "bus",
  METRO = "train",
  TRAIN = "train",
  TRAM = "bus-stop",
  SHIP = "ship",
  FERRY = "ship",
  TAXI = "car",
}
M.DEFAULT_GLYPH = "clock"
M.BRAND_GLYPH = "bus"

M.MODE_NAMES = {
  BUS = "Bus",
  METRO = "Metro",
  TRAIN = "Train",
  TRAM = "Tram",
  SHIP = "Ship",
  FERRY = "Ferry",
  TAXI = "Taxi",
}

-- Luau's pattern functions cost on the order of a hundred microseconds a
-- call in the shell's plugin VMs, and a callback has 25 ms. The helpers on
-- this hot path therefore work with string.byte and plain finds.
local function isSpace(b)
  return b == 32 or b == 10 or b == 13 or b == 9
end

function M.trim(value)
  if value == nil then
    return ""
  end
  local s = tostring(value)
  local first, last = 1, #s
  while first <= last and isSpace(string.byte(s, first)) do
    first += 1
  end
  while last >= first and isSpace(string.byte(s, last)) do
    last -= 1
  end
  if first == 1 and last == #s then
    return s
  end
  return string.sub(s, first, last)
end

-- API-derived display strings pass through here before anything renders
-- them. The shell draws plain labels, so this is mostly parity with the
-- Omarchy widget; angle brackets never occur in legitimate SL names anyway.
function M.plain(value)
  local s = M.trim(value)
  if string.find(s, "<", 1, true) == nil and string.find(s, ">", 1, true) == nil then
    return s
  end
  return (string.gsub(s, "[<>]", ""))
end

function M.intOr(value, fallback)
  local n = tonumber(value)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then
    return fallback
  end
  return math.floor(n)
end

function M.clamp(value, lo, hi)
  return math.max(lo, math.min(hi, value))
end

function M.transportGlyph(mode)
  return M.MODE_GLYPHS[string.upper(tostring(mode or ""))] or M.DEFAULT_GLYPH
end

function M.transportName(mode)
  local key = string.upper(tostring(mode or ""))
  if M.MODE_NAMES[key] then
    return M.MODE_NAMES[key]
  end
  if key == "" then
    return ""
  end
  return string.sub(key, 1, 1) .. string.lower(string.sub(key, 2))
end

-- ------------------------------------------------------------------ config

function M.parseLineFilter(raw)
  local out = {}
  for part in string.gmatch(tostring(raw or ""), "[^,%s]+") do
    table.insert(out, string.upper(part))
  end
  return out
end

-- One place that turns the declared settings into the values the plugin
-- actually uses, so the widget and the panel never repeat a default or a
-- bound. `read(key)` is the host's getConfig, injected so this stays pure.
function M.resolveConfig(read)
  local function str(key)
    local v = read(key)
    if v == nil then
      return ""
    end
    return M.trim(tostring(v))
  end
  local function int(key, fallback, lo, hi)
    return M.clamp(M.intOr(read(key), fallback), lo, hi)
  end

  local transport = string.upper(str("transport"))
  if transport == "ALL" or M.MODE_NAMES[transport] == nil then
    transport = ""
  end
  local barFormat = str("bar_format")
  if barFormat == "" then
    barFormat = "{line} {wait}"
  end
  local showIcon = read("show_icon")
  if showIcon == nil then
    showIcon = true
  end

  return {
    siteId = math.max(0, M.intOr(read("site_id"), 0)),
    transport = transport,
    direction = int("direction", 0, 0, 2),
    lines = M.parseLineFilter(str("lines")),
    walkMinutes = int("walk_minutes", 0, 0, 120),
    barCount = int("bar_count", 2, 1, 6),
    forecastMinutes = int("forecast_minutes", 90, 10, 360),
    refreshSeconds = int("refresh_seconds", 30, 15, 600),
    barFormat = barFormat,
    showIcon = showIcon ~= false,
  }
end

-- Server-side filters keep the payload small; `lines` and `walkMinutes` are
-- applied client-side because the API has no equivalent. Every value that
-- lands in the URL is an integer or a vetted mode name, so no encoding.
function M.departuresUrl(config, siteId)
  local query = { "forecast=" .. config.forecastMinutes }
  if config.transport ~= "" then
    table.insert(query, "transport=" .. config.transport)
  end
  if config.direction ~= 0 then
    table.insert(query, "direction=" .. config.direction)
  end
  return M.API_BASE .. "/sites/" .. siteId .. "/departures?" .. table.concat(query, "&")
end

-- Identifies one board: every widget instance with the same stop and filters
-- publishes to the same state key, and the panel reads whichever is active.
function M.boardKey(config, siteId)
  return table.concat({
    "board", siteId, config.transport, config.direction,
    table.concat(config.lines, ","), config.walkMinutes, config.forecastMinutes,
  }, ":")
end

-- A one-line summary of the filters in force, for the panel header.
function M.filterSummary(config)
  local parts = {}
  if config.transport ~= "" then
    table.insert(parts, M.transportName(config.transport))
  end
  if #config.lines > 0 then
    table.insert(parts, "Line " .. table.concat(config.lines, ", "))
  end
  if config.direction ~= 0 then
    table.insert(parts, "Direction " .. config.direction)
  end
  if config.walkMinutes > 0 then
    table.insert(parts, config.walkMinutes .. " min walk")
  end
  return table.concat(parts, " · ")
end

-- -------------------------------------------------------------------- time

-- Parses "2026-08-25T23:30:00" as a wall-clock time with no zone applied,
-- in milliseconds. os.time interprets the table as machine-local time; the
-- clock anchor below cancels that out, so the result is right in any zone.
local function digits(s, from, to)
  local n = 0
  for i = from, to do
    local b = string.byte(s, i)
    if b == nil or b < 48 or b > 57 then
      return nil
    end
    n = n * 10 + (b - 48)
  end
  return n
end

-- Memoised: a payload repeats each timestamp (expected and scheduled are
-- usually equal) and every tick re-reads them all.
local naiveCache = {}
local naiveCacheSize = 0

function M.parseNaive(value)
  if type(value) ~= "string" or #value < 16 then
    return nil
  end
  local cached = naiveCache[value]
  if cached ~= nil then
    return cached or nil
  end
  local result = nil
  local sep = string.byte(value, 11)
  if (sep == 84 or sep == 32) and string.byte(value, 5) == 45 and string.byte(value, 8) == 45
    and string.byte(value, 14) == 58 then
    local y, mo, d = digits(value, 1, 4), digits(value, 6, 7), digits(value, 9, 10)
    local h, mi = digits(value, 12, 13), digits(value, 15, 16)
    local sec = 0
    if string.byte(value, 17) == 58 then
      sec = digits(value, 18, 19) or 0
    end
    if y and mo and d and h and mi then
      local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec })
      if t ~= nil then
        result = t * 1000
      end
    end
  end
  if naiveCacheSize > 4000 then
    naiveCache = {}
    naiveCacheSize = 0
  end
  naiveCache[value] = result or false
  naiveCacheSize += 1
  return result
end

local function isImminent(display)
  local lower = string.lower(display)
  return lower == "nu" or lower == "now"
end

-- "4 min" / "12min" -> 4 / 12, else nil.
local function relativeMinutes(display)
  local n = #display
  if n < 4 or string.lower(string.sub(display, n - 2, n)) ~= "min" then
    return nil
  end
  local last = n - 3
  while last >= 1 and isSpace(string.byte(display, last)) do
    last -= 1
  end
  if last < 1 then
    return nil
  end
  return digits(display, 1, last)
end

-- Departure timestamps are naive Europe/Stockholm wall-clock times, so
-- subtracting the machine's clock is only right on a machine set to
-- Stockholm. Instead the board anchors itself to the API's own clock: a
-- departure that reports both a relative `display` ("4 min") and an absolute
-- `expected` pins down what "now" was when the server answered.
--
-- Returns the offset to add to the wall clock to land in the API's frame, or
-- nil when the payload carries nothing to anchor on, in which case the caller
-- keeps the offset it learned last.
function M.clockOffset(departures, wallNow)
  local samples = {}
  for _, d in ipairs(departures or {}) do
    if type(d) == "table" then
      local display = M.trim(d.display)
      local relative = relativeMinutes(display)
      local imminent = isImminent(display)
      if relative ~= nil or imminent then
        local stamp = M.parseNaive(d.expected or d.scheduled)
        if stamp ~= nil then
          -- The server floors its minute counts, so each sample sits up to
          -- a minute late; the half-minute correction centers them.
          table.insert(samples, stamp - (imminent and 0 or relative * 60000) - 30000)
        end
      end
    end
  end
  if #samples == 0 then
    return nil
  end
  table.sort(samples)
  return samples[math.floor(#samples / 2) + 1] - wallNow
end

-- A legitimate anchor offset is bounded by how far a machine's timezone can
-- sit from Stockholm: just over a day across the extremes of UTC-12 and
-- UTC+14. Anything past that is a garbage anchor, not a timezone.
function M.saneClockOffset(offset)
  return offset ~= nil and math.abs(offset) < 26 * 3600 * 1000
end

function M.clockText(departure)
  local stamp = departure.expected or departure.scheduled
  if type(stamp) ~= "string" or #stamp < 16 or string.byte(stamp, 11) ~= 84 then
    return ""
  end
  return string.sub(stamp, 12, 16)
end

-- Minutes as the bar and panel show them. Under a minute reads "now" rather
-- than "0": the number is the wait, and there isn't one.
function M.minutesText(minutes)
  if minutes == nil then
    return "?"
  end
  return minutes <= 0 and "now" or tostring(minutes)
end

function M.waitText(minutes)
  if minutes == nil then
    return "?"
  end
  return minutes <= 0 and "now" or (minutes .. "′")
end

function M.waitLabel(minutes)
  if minutes == nil then
    return "?"
  end
  return minutes <= 0 and "now" or (minutes .. " min")
end

-- ------------------------------------------------------------- departures

-- Validates a decoded departures payload. Returns ok, departures,
-- stopDeviations, error.
function M.parseDepartures(data)
  if type(data) ~= "table" then
    return false, {}, {}, "Unreadable response from SL"
  end
  local departures = type(data.departures) == "table" and data.departures or {}
  local stopDeviations = {}
  if type(data.stop_deviations) == "table" then
    for _, dev in ipairs(data.stop_deviations) do
      if type(dev) == "table" then
        table.insert(stopDeviations, {
          message = M.plain(dev.message),
          importance_level = M.intOr(dev.importance_level, 0),
        })
      end
    end
  end
  return true, departures, stopDeviations, ""
end

function M.deviationText(deviations)
  local messages = {}
  local seen = {}
  for _, dev in ipairs(deviations or {}) do
    if type(dev) == "table" then
      local message = M.plain(dev.message)
      if message ~= "" and not seen[message] then
        seen[message] = true
        table.insert(messages, message)
      end
    end
  end
  return table.concat(messages, " · ")
end

function M.maxImportance(deviations)
  local level = 0
  for _, dev in ipairs(deviations or {}) do
    if type(dev) == "table" then
      level = math.max(level, M.intOr(dev.importance_level, 0))
    end
  end
  return level
end

-- Flattens the API shape into rows the UI reads directly. Rows are plain
-- data because they travel through the plugin state channel to the panel.
-- Done once per payload; the time-dependent fields are filled per tick by
-- timeRows, since a tick has no budget to spare for re-reading strings.
function M.shapeDepartures(departures)
  local rows = {}
  for i, d in ipairs(departures or {}) do
    if type(d) == "table" then
      local line = type(d.line) == "table" and d.line or {}
      local journey = type(d.journey) == "table" and d.journey or {}
      local stopPoint = type(d.stop_point) == "table" and d.stop_point or {}
      local stopArea = type(d.stop_area) == "table" and d.stop_area or {}
      local deviations = type(d.deviations) == "table" and d.deviations or {}
      local stateText = string.upper(tostring(d.state or ""))
      local cancelled = stateText == "CANCELLED"
      for _, dev in ipairs(deviations) do
        if type(dev) == "table" and string.upper(tostring(dev.consequence or "")) == "CANCELLED" then
          cancelled = true
        end
      end
      local mode = string.upper(tostring(line.transport_mode or ""))
      local display = M.plain(d.display)
      local fallbackMinutes = relativeMinutes(display)
      if fallbackMinutes == nil and isImminent(display) then
        fallbackMinutes = 0
      end
      rows[#rows + 1] = {
        key = tostring(journey.id or i) .. ":" .. tostring(d.scheduled or i),
        line = M.plain(line.designation),
        mode = mode,
        glyph = M.transportGlyph(mode),
        destination = M.plain(d.destination or d.direction),
        direction = M.intOr(d.direction_code, 0),
        -- Timestamps lead; the relative display is only a fallback for a
        -- payload that omits both times, frozen at what the fetch said.
        stampMs = M.parseNaive(d.expected or d.scheduled),
        fallbackMinutes = fallbackMinutes,
        clock = M.clockText(d),
        display = display,
        atStop = stateText == "ATSTOP",
        cancelled = cancelled,
        -- The berth letter is the useful half of stop_point; its name just
        -- repeats the site you asked for. The area name, though, is how the
        -- widget learns the stop's name without loading the site list.
        berth = M.plain(stopPoint.designation),
        stopName = M.plain(stopArea.name),
        deviationText = M.deviationText(deviations),
        deviationLevel = M.maxImportance(deviations),
      }
    end
  end
  return rows
end

-- Fills the countdown fields against the anchored clock. Returns new row
-- tables, so a published board never shares state with the next tick.
function M.timeRows(shaped, now)
  local rows = {}
  for i, base in ipairs(shaped) do
    local minutes
    if base.stampMs ~= nil then
      minutes = math.max(0, math.round((base.stampMs - now) / 60000))
    else
      minutes = base.fallbackMinutes
    end
    local row = table.clone(base)
    row.minutes = minutes
    row.minutesText = M.minutesText(minutes)
    row.waitText = M.waitText(minutes)
    row.waitLabel = M.waitLabel(minutes)
    rows[i] = row
  end
  return rows
end

function M.toRows(departures, now)
  return M.timeRows(M.shapeDepartures(departures), now)
end

-- Client-side narrowing: line whitelist, and dropping departures that leave
-- before you could physically get there. Sorted because a line filter can
-- interleave modes the API returned in separate blocks.
function M.filterRows(rows, config)
  local wanted = nil
  if #config.lines > 0 then
    wanted = {}
    for _, l in ipairs(config.lines) do
      wanted[l] = true
    end
  end
  local out = {}
  for _, row in ipairs(rows) do
    local keep = true
    if wanted ~= nil and not wanted[string.upper(row.line)] then
      keep = false
    end
    if row.minutes ~= nil and row.minutes < config.walkMinutes then
      keep = false
    end
    if keep then
      table.insert(out, row)
    end
  end
  table.sort(out, function(a, b)
    local am = a.minutes == nil and 1e9 or a.minutes
    local bm = b.minutes == nil and 1e9 or b.minutes
    if am ~= bm then
      return am < bm
    end
    return a.key < b.key
  end)
  return out
end

-- Whether two row lists render identically, over exactly the fields the UI
-- displays. Lets a tick skip republishing when nothing changed.
function M.sameRows(a, b)
  if a == nil or b == nil or #a ~= #b then
    return false
  end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.key ~= y.key or x.minutesText ~= y.minutesText or x.clock ~= y.clock
      or x.display ~= y.display or x.cancelled ~= y.cancelled
      or x.deviationText ~= y.deviationText or x.deviationLevel ~= y.deviationLevel then
      return false
    end
  end
  return true
end

-- The bar shows what you can actually board, so cancellations are dropped
-- here; the panel still lists them because a cancellation is exactly the
-- thing you open the panel to find out about.
function M.barRows(rows, config)
  local out = {}
  for _, row in ipairs(rows) do
    if not row.cancelled then
      table.insert(out, row)
      if #out >= config.barCount then
        break
      end
    end
  end
  return out
end

-- One gsub with a replacement function: row fields come from the API, and
-- a field containing a {token} must not itself be substituted.
function M.formatSegment(template, row)
  local fields = {
    line = row.line, wait = row.waitText, min = row.minutesText, clock = row.clock,
    display = row.display, destination = row.destination, icon = "",
  }
  local out = string.gsub(tostring(template), "{(%a+)}", function(key)
    return fields[key]
  end)
  return M.trim(out)
end

-- The bar label text. The mode glyph is drawn separately by the widget.
function M.barText(rows, config, fetchState, hasSite)
  if not hasSite then
    return "SL"
  end
  if #rows == 0 then
    if fetchState == "loading" then
      return "…"
    end
    if fetchState == "error" then
      return "✗"
    end
    return "–"
  end
  local segments = {}
  for _, row in ipairs(rows) do
    local segment = M.formatSegment(config.barFormat, row)
    if segment ~= "" then
      table.insert(segments, segment)
    end
  end
  return table.concat(segments, " · ")
end

-- Vertical bars get one short line per departure instead of a wide label.
function M.verticalBarLines(rows, config, fetchState, hasSite)
  if not hasSite then
    return { "SL" }
  end
  if #rows == 0 then
    return { fetchState == "loading" and "…" or (fetchState == "error" and "✗" or "–") }
  end
  local lines = {}
  for _, row in ipairs(rows) do
    table.insert(lines, row.minutesText == "now" and "●" or row.minutesText)
  end
  return lines
end

-- The bar tooltip: the shell lays out key/value rows itself, so the columns
-- need no padding tricks.
function M.tooltipRows(rows, siteLabel, hasSite)
  if not hasSite then
    return "SL Departures — click to pick a stop"
  end
  if #rows == 0 then
    return siteLabel .. " — no departures"
  end
  local out = {}
  for i = 1, math.min(#rows, 5) do
    local row = rows[i]
    table.insert(out, {
      key = row.line .. "  " .. row.destination,
      value = row.minutes == nil and row.clock or row.waitLabel,
    })
  end
  return out
end

-- ------------------------------------------------------------------- sites

-- Diacritic folding, so a stop can be found from a keyboard the typist
-- actually has: "sodermalm" reaches Södermalm, "radmans" reaches
-- Rådmansgatan. A table rather than a normalization library, which Luau
-- does not have.
local FOLD = {}
do
  local groups = {
    ["àáâãäåÀÁÂÃÄÅ"] = "a", ["èéêëÈÉÊË"] = "e", ["ìíîïÌÍÎÏ"] = "i",
    ["òóôõöøÒÓÔÕÖØ"] = "o", ["ùúûüÙÚÛÜ"] = "u", ["ýÿÝŸ"] = "y",
    ["çÇ"] = "c", ["ñÑ"] = "n", ["šŠ"] = "s", ["žŽ"] = "z",
  }
  for chars, ascii in pairs(groups) do
    for _, cp in utf8.codes(chars) do
      FOLD[cp] = ascii
    end
  end
end

function M.fold(value)
  local s = tostring(value or "")
  local length = utf8.len(s)
  -- ASCII-only (one codepoint per byte): the native lowercase suffices.
  if length == nil or length == #s then
    return string.lower(s)
  end
  local out = {}
  for _, cp in utf8.codes(s) do
    local mapped = FOLD[cp]
    if mapped ~= nil then
      table.insert(out, mapped)
    elseif cp < 128 then
      table.insert(out, string.lower(string.char(cp)))
    else
      table.insert(out, utf8.char(cp))
    end
  end
  return table.concat(out)
end

-- One site from the API list, with its folded search keys precomputed:
-- a search runs on every keystroke over all ~6500 sites, so folding inside
-- the search loop would redo millions of comparisons per keypress.
function M.siteRecord(site)
  if type(site) ~= "table" or tonumber(site.id) == nil or site.name == nil then
    return nil
  end
  local name = M.plain(site.name)
  if name == "" then
    return nil
  end
  local note = M.plain(site.note)
  return {
    id = M.intOr(site.id, 0),
    name = name,
    note = note,
    folded = M.fold(name),
    foldedNote = note == "" and "" or M.fold(note),
  }
end

function M.parseSites(data)
  local out = {}
  if type(data) ~= "table" then
    return out
  end
  for _, site in ipairs(data) do
    local record = M.siteRecord(site)
    if record ~= nil then
      table.insert(out, record)
    end
  end
  return out
end

-- Finds the next top-level site object in the raw list text, starting at
-- `pos`. Returns the object's text and the position to continue from, or
-- nil at the end. Decoding the whole 1.3 MB list in one call blows a
-- plugin's 25 ms CPU budget, so the panel decodes it one slice per frame.
--
-- Only plain substring finds and byte scans here: Luau's pattern matcher
-- costs hundreds of microseconds per call on this input, while a plain
-- find and a native decode of the resulting slice are effectively free.
-- Every site opens with its "id" member, and no other key or value
-- contains that quoted text, so it marks each object.
local ID_KEY = '"id"'
local BRACE_OPEN = string.byte("{")
local BRACE_CLOSE = string.byte("}")

local function isSpace(b)
  return b == 32 or b == 10 or b == 13 or b == 9
end

function M.nextSiteSlice(raw, pos)
  local idAt = string.find(raw, ID_KEY, pos, true)
  if idAt == nil then
    return nil, nil
  end
  -- Back up over the whitespace between the opening brace and the key.
  local start = idAt - 1
  while start > 1 and isSpace(string.byte(raw, start)) do
    start -= 1
  end
  if string.byte(raw, start) ~= BRACE_OPEN then
    return nil, nil
  end
  local nextId = string.find(raw, ID_KEY, idAt + #ID_KEY, true)
  -- The object's closing brace is the last one before the next object (or
  -- the end of the list); the nested "valid" object closes earlier.
  local stop = nextId ~= nil and (nextId - 1) or #raw
  while stop > start and string.byte(raw, stop) ~= BRACE_CLOSE do
    stop -= 1
  end
  if stop <= start then
    return nil, nil
  end
  return string.sub(raw, start, stop), nextId or (#raw + 1)
end

-- ------------------------------------------------------------ site index
--
-- A search runs on every keystroke, and one substring find per site is
-- 6500 host calls: far past a callback's 25 ms budget. So the folded names
-- are laid out in one string, one line per site ("\n" name "\t" note), and
-- a search is a few plain finds over that string, each hit mapped back to
-- its site with a binary search over the line starts. Prefix hits come
-- from finding "\n" .. needle; the rest from the bare needle.

function M.newSiteIndex()
  return { parts = {}, starts = {}, sites = {}, length = 0, text = nil }
end

function M.indexAdd(index, record)
  local line = "\n" .. record.folded .. "\t" .. record.foldedNote
  local i = #index.sites + 1
  index.sites[i] = record
  index.starts[i] = index.length + 1
  index.parts[i] = line
  index.length += #line
end

function M.indexFinish(index)
  index.parts[#index.parts + 1] = "\n"
  index.starts[#index.sites + 1] = index.length + 1
  index.text = table.concat(index.parts)
  index.parts = nil
  return index
end

-- Largest i with starts[i] <= pos: the site whose line contains pos.
local function siteAt(index, pos)
  local lo, hi = 1, #index.sites
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if index.starts[mid] <= pos then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

-- Ranked substring search. Prefix matches come first because typing "slu"
-- should surface Slussen ahead of every stop that merely contains "slu";
-- among equals, shorter names first. Hits per pass are capped, so a
-- one-letter needle costs a bounded number of finds rather than thousands.
local MAX_HITS_PER_PASS = 240

function M.searchIndex(index, query, limit)
  local needle = string.gsub(M.fold(M.trim(query)), "[\n\t]", "")
  if needle == "" or index == nil or index.text == nil then
    return {}
  end
  local max = M.intOr(limit, 8)
  local text = index.text
  local scored = {}
  local seen = {}

  local function collect(pattern, lead)
    local init = 1
    local hits = 0
    while hits < MAX_HITS_PER_PASS do
      local at = string.find(text, pattern, init, true)
      if at == nil then
        return
      end
      local i = siteAt(index, at)
      local site = index.sites[i]
      if not seen[i] then
        seen[i] = true
        local matchPos = at + lead
        local nameStart = index.starts[i] + 1
        local tabAt = nameStart + #site.folded
        local offset = matchPos < tabAt and (matchPos - nameStart) or 100
        scored[#scored + 1] = { site = site, score = offset * 1000 + #site.folded }
        hits += 1
      end
      init = index.starts[i + 1]
    end
  end

  collect("\n" .. needle, 1)
  if #scored < max then
    collect(needle, 0)
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score < b.score
    end
    return a.site.name < b.site.name
  end)
  local out = {}
  for i = 1, math.min(#scored, max) do
    out[i] = scored[i].site
  end
  return out
end

-- Unindexed fallback, for small lists.
function M.searchSites(sites, query, limit)
  local index = M.newSiteIndex()
  for _, site in ipairs(sites) do
    M.indexAdd(index, site)
  end
  return M.searchIndex(M.indexFinish(index), query, limit)
end

function M.findSiteById(sites, id)
  for _, site in ipairs(sites) do
    if site.id == id then
      return site
    end
  end
  return nil
end

function M.siteLabel(site)
  if site == nil then
    return ""
  end
  if site.note == nil or site.note == "" then
    return site.name
  end
  return site.name .. " (" .. site.note .. ")"
end

return M
