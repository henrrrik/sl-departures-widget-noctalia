# SL Departures

Live departure times for a Stockholm (SL) bus stop, metro or train station,
tram stop, or ferry berth, in the Noctalia bar. Click for the full board,
service messages, and a searchable stop picker.

## Plugin

| Field | Value |
| --- | --- |
| ID | `henrrrik/sl-departures` |
| Entries | Bar widget: `departures`; panel: `board` |

## Usage

Add the `departures` widget from the Add-widget picker, or by hand:

```toml
[widget.sl]
type = "henrrrik/sl-departures:departures"

[bar.default]
center = ["clock", "sl"]
```

Click the widget and search for a stop. The choice is saved in the plugin's
data directory, and every widget without a fixed `site_id` shows it.

| Gesture | Action |
| --- | --- |
| Left click | Open or close the board panel |
| Right click | Refresh now |
| Middle click | Widget settings |

## Settings

Widget settings, per widget instance:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `site_id` | `int` | `0` | Fixes this widget to one SL site. `0` uses the picked stop. |
| `transport` | `select` | `ALL` | `BUS`, `METRO`, `TRAM`, `TRAIN`, `SHIP`, or `FERRY`. |
| `direction` | `int` | `0` | SL's direction code, `1` or `2`. `0` shows both. |
| `lines` | `string` | `""` | Comma-separated line designations, e.g. `"4, 74"`. |
| `walk_minutes` | `int` | `0` | Hide departures leaving sooner than this. |
| `bar_count` | `int` | `2` | Departures shown in the bar. |
| `forecast_minutes` | `int` | `90` | How far ahead to ask for. |
| `refresh_seconds` | `int` | `30` | Seconds between fetches (minimum 15). |
| `bar_format` | `string` | `{line} {wait}` | Template per departure: `{line}` `{wait}` `{min}` `{clock}` `{destination}` `{display}`. |
| `show_icon` | `bool` | `true` | Mode glyph in front of the label. |

Panel settings, under Settings → Plugins:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `panel_count` | `int` | `12` | Rows the board panel lists. |

## IPC

```sh
noctalia msg plugin henrrrik/sl-departures:departures focused refresh
noctalia msg panel-toggle henrrrik/sl-departures:board
```
