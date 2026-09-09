# TaskBeacon palette

TaskBeacon keeps native macOS system surfaces and uses semantic accents from
[Radix Colors](https://www.radix-ui.com/colors), an MIT-licensed open-source
color system. This preserves the quiet white/graphite application icon while
giving task states consistent light- and dark-mode contrast.

| Role | Light | Dark | Radix token |
| --- | --- | --- | --- |
| Active foreground | `#2A7E3B` | `#71D083` | Grass 11 |
| Progress fill | `#94CE9A` | `#53B365` | Grass 7 / Grass 10 |
| Waiting | `#AB6400` | `#FFCA16` | Amber 11 |
| Failed | `#D13415` | `#FF977D` | Tomato 11 |
| Completed | `#7C8481` | `#717D79` | Sage 10 |

The progress fill intentionally uses a softer step in light mode. The status
label uses the higher-contrast foreground token, so lightening the bar does not
make task text harder to read.
