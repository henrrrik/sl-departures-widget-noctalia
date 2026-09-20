# SL Departures for Noctalia

Live departure times for a Stockholm (SL) bus stop, metro or train station,
tram stop, or ferry berth, as a [Noctalia](https://noctalia.dev) bar widget
with a board panel and a searchable stop picker.

This is the Noctalia v5 port of
[sl-departures-widget](https://github.com/henrrrik/sl-departures-widget), the
Omarchy shell widget. Noctalia plugins are Luau scripts rather than QML, so it
is a rewrite that keeps the same behaviour: the bar shows the next departures,
the panel shows the full board with service messages, and the picker finds a
stop by name with diacritic folding.

## Install

The repository is a Noctalia plugin source. Add it and enable the plugin:

```sh
noctalia msg plugins source add henrrrik git https://github.com/henrrrik/sl-departures-widget-noctalia
noctalia msg plugins enable henrrrik/sl-departures
```

Then add the `departures` widget from the Add-widget picker in Settings, or by
hand in `~/.config/noctalia/config.toml`:

```toml
[widget.sl]
type = "henrrrik/sl-departures:departures"

[bar.default]
center = ["clock", "sl"]
```

Click the widget and search for a stop. See
[sl-departures/README.md](sl-departures/README.md) for the settings, gestures,
and IPC events.

## How it works

| File | Role |
| --- | --- |
| `sl-departures/plugin.toml` | Manifest: the widget and panel entries and their typed settings. |
| `sl-departures/model.luau` | All parsing, filtering, and formatting. Pure functions, no host calls. |
| `sl-departures/widget.luau` | Bar widget: fetches with the shell's HTTP client, counts down, publishes the board. |
| `sl-departures/panel.luau` | The board panel and the stop picker. |
| `sl-departures/translations/en.json` | Labels for the settings GUI. |
| `catalog.toml` | Source index so Noctalia can list the plugin without a full clone. |

Each widget instance fetches its own stop with the shell's native HTTP client
and publishes the shaped board on the plugin state channel under a key built
from the stop and filters. Clicking a widget marks its board active and opens
the panel, which watches that key. Identical instances on several bars publish
the same key, so the panel does not care how many there are.

Noctalia plugins can read their settings but not write them, so the stop
picked in the panel is saved to the plugin data directory (`stop.json`) and
announced on the state channel. Every widget without a fixed `site_id`
follows. The stop list (`sites.json`, 1.3 MB) is cached next to it and
refreshed weekly, and is only loaded when the picker opens.

### Staying inside the CPU budget

Every plugin callback gets 25 ms of worker-thread CPU, and in the plugin VMs
Luau's pattern functions (`string.match`, `string.gsub`, pattern `find`)
cost on the order of a hundred microseconds a call, while plain finds,
`string.byte`, and the host's JSON decoder are effectively free. Two things
follow from that:

- The stop list is parsed a slice at a time from the panel's frame tick:
  each site's object is cut out with plain finds and byte scans and decoded
  natively, about a hundred per frame, so the whole list takes about a
  second and never trips the budget. The panel redraws a progress line each
  step because a surface only gets its next frame callback after it commits.
- Searching is one string, one line per folded name, so a keystroke is a few
  capped plain finds rather than one find per site. Timestamps and trims on
  the departures path are parsed with byte arithmetic, rows are shaped once
  per payload, and only the countdown is recomputed per tick.

SL returns naive Europe/Stockholm times. The board anchors itself to SL's own
clock from departures that report both a relative wait and an absolute time,
so the countdown is right on a laptop in any timezone.

## Development

Point Noctalia at a checkout as a path source, or symlink the plugin
directory into the local plugin dir:

```sh
ln -s "$PWD/sl-departures" ~/.local/share/noctalia/plugins/sl-departures
noctalia msg plugins enable henrrrik/sl-departures
```

Edits to the `.luau` files hot-reload. Manifest changes need a config reload.
`noctalia plugins lint sl-departures` cross-checks the declared settings
against the scripts. Runtime errors, including budget overruns, land in
`~/.cache/noctalia/noctalia.log` tagged `[luau]`. `noctalia.log()` output did
not reach that file at the default level, so tracing through a file in
`noctalia.pluginDataDir()` is the reliable probe.

Useful IPC while developing:

```sh
noctalia msg panel-toggle henrrrik/sl-departures:board
noctalia msg plugin henrrrik/sl-departures:departures focused refresh
```

## License

MIT, see [LICENSE](LICENSE).
