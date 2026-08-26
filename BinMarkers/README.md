# Bin marker sheets

`markers.typ` is the source; the three PDFs beside it are what you print. **One sheet, one kind
of marker, five sizes of it.** Print all three, cut everything out, and swap sizes under the
camera — the right size depends on the lens, the mount height and the room, so it is chosen on
site and not here.

| Sheet | App setting | Opens after | Notes |
| --- | --- | --- | --- |
| `BinMarkers_Dashes.pdf` | Marker strips → **Dashes** | 6 dashes | **Start here.** A row of equal dashes, nothing encoded |
| `BinMarkers_Chevrons.pdf` | Marker strips → **Chevrons** | 4 dashes | Each dash bent into a V. A third less drawer travel, about twice the time a frame |
| `BinMarkers_Bars.pdf` | Marker strips → **Bars** | — | Five black bars. Wants the largest print and fails first at distance |

Print at **100%** — not fit-to-page — on matte stock, and cut on the dashed line. The white at
the two ends is part of the marker; the few millimetres above and below are for the scissors.

## Nothing here says which bin it is

Every bin carries the **same** strip, and a marker is credited to whichever bin it appears
nearest. The camera is bolted overhead and the bins do not move, so position already answers
the question a code was being asked to answer — and every failure this feature has had came
from the encoding rather than from the finding. There is nothing to bind in settings and
nothing that can be stuck on the wrong drawer.

Mount it **level and inside**, on the rim of the drawer wall, where a shut drawer hides it
under the counter. Visible means open, and that is the whole signal. Mount it near the front of
the rim: a drawer does not reveal the marker all at once, it slides out from under the counter
edge, and near the back it needs the drawer pulled almost the whole way.

The scan walks rows finely and columns coarsely — that asymmetry is what buys the thin flat row
— so a strip lying flat is found and one standing on end has to be several times broader. One
mounted at an angle is not found at all.

## Choosing the size

Start with a size that is comfortably too big, mount it, then read the two numbers the debug
overlay prints beside each marker (Settings → Bin Openness → Marker strips → Show debug
overlay):

- **pitch / unit px** — samples per printed dash or unit. Dashes hold up down to two, because
  nothing divides one width by another; bars need six before the widths separate, and stop
  working again past about 40, where a bar grows wider than the threshold window and loses its
  own middle.
- **×n** — how many scan lines cross the marker. Three is the floor, and it is what a narrow
  rim actually limits.

Work down through the sizes until one of those gets close to its floor, then go back one.

Rendered back through the scanner at three distances, every size on the dash and chevron sheets
reads at all three; the bar sheet reads all five only once the strips are large enough, which
is the trade that sheet exists to show.

## The threshold is dashes, not blur

A drawer reveals the row a dash at a time, so the rule is a count and not a threshold on a
blur. Six dashes clear of the counter edge opens the bin on the default **Thin** row height;
**Tall** wants twice the printed height and opens on 5, **Hairline** half of it and opens on 7.
Chevrons open on 4 at Thin's height.

To trigger sooner, print the dashes **smaller**, not fewer: six at a 4 mm pitch clear the edge
in half the travel that six at 8 mm need, and the sheet prints the travel beside each size.
Fewer is not a setting — below the threshold the room itself starts producing rows. Measured on
fifteen frames of this room with nothing installed: 185 false rows at five alternating runs, 27
at six, 5 at seven, none at eight. The chevron check takes that to none at seven, which is
where its extra dash of sensitivity comes from.

Repetition is the design, so an arm across the middle of a row costs nothing: it leaves two
shorter rows and the longer one still answers. Print more dashes than the threshold needs.

## Regenerating

```sh
brew install typst
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Dashes.pdf   --input kind=dashes
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Chevrons.pdf --input kind=chevrons
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Bars.pdf     --input kind=bars
```

The bar rhythm drawn here must be one of `BinMarkerPattern.all` in the app.
`BinMarkerScannerTests.patternsMatchThePrintedSheet` pins those and names this directory, so
changing one without the other fails a test rather than producing a sheet the scanner quietly
cannot read.

Colour is gone from the sheets and from the app's picker. It is still in `BinMarkerStyle` and
still tested, but this site settled it: three hue cones wide enough to survive the room's light
claim a third of every hue there is, and the room is full of blue liners and warm wood. It
outlined everything in sight.
