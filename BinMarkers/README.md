# Bin marker sheets

`markers.typ` is the source; the three PDFs beside it are what you print.

| Sheet | App setting | What is on it |
| --- | --- | --- |
| `BinMarkers_Dashes.pdf` | Marker strips → **Dashes** | **Start here.** Two pages, one per height: five 275 × 20 mm strips, then five 275 × 24 mm. Sixteen 8 mm dashes each — three bins and two spares |
| `BinMarkers_Chevrons.pdf` | Marker strips → **Chevrons** | One page, five sizes to choose between. Each dash bent into a V — opens a third sooner, for twice the time a frame |
| `BinMarkers_Bars.pdf` | Marker strips → **Bars** | One page, five sizes. Wants the largest print and fails first at distance |

The dash sheet is the one to mount: ten finished strips, five per height, and the only thing
left to decide is which of the two heights the rim can give up. The other two sheets are a
range of sizes to compare — cut them out and swap them under the camera, because the right size
depends on the lens, the mount height and the room.

### Which dash height

Both sets carry the same 8 mm dash, so the drawer travel is the same either way. What differs
is how many scan lines cross the row, which is what the **Row height** setting trades against
dashes. Rendered back through the scanner at four distances:

| | printed height | scan lines at 8 px/cm | Tall | Thin | Very thin |
| --- | --- | --- | --- | --- | --- |
| 275 × 20 mm | 14 mm | 11 | **misses** | reads | reads |
| 275 × 24 mm | 18 mm | 14 | reads | reads | reads |

So at this site's scale the 24 mm strip is the one that supports **Tall**, which opens on 5
dashes rather than 6 — 72 mm of drawer instead of 88 — and costs 10 ms a frame against 17.
The 20 mm strip is 11 scan lines against the 12 Tall needs, so it reads on **Thin** or shorter.

**Mount the taller one if the rim allows.** The three settings differ only in how finely the
frame is scanned, and finer is worse at everything except the height it can cope with:

| setting | wants | opens on | costs |
| --- | --- | --- | --- |
| Tall | 15 mm of printed height | 5 dashes · 72 mm of drawer | 10 ms a frame |
| Thin | 7.5 mm | 6 dashes · 88 mm | 17 ms |
| Very thin | 3.8 mm | 7 dashes · 104 mm | 31 ms |

None of the three reads anything false in this room. **Very thin** is below anything the sheets
print, so against these strips it only costs — it is there to be measured on the device, where
whether 31 ms a frame survives beside the model is a question a render cannot answer.

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

Rendered back through the scanner at three distances, every size on the chevron sheet reads at
all three; the bar sheet reads all five only once the strips are large enough, which is the
trade that sheet exists to show.

One mounting caveat, and it is new: every bin carries the same marker now, so two of them that
**overlap horizontally** in the frame have to be more than about sixteen scan lines apart
vertically, or the scan reads them as one row glimpsed through a gap and only one bin opens.
Bins side by side never overlap, so this does not arise on this site.

It does show up if you lay the dash sheet flat under the camera to check it: five strips to a
page leaves about 11 mm between them, so from far enough away the neighbours merge and the
scanner reports fewer rows than are printed. Measured, five strips to a page:

| px/cm | 275 × 20 mm | 275 × 24 mm |
| --- | --- | --- |
| 7.9 | 4 of 5 | 3 of 5 |
| 9.8 and closer | 5 of 5 | 5 of 5 |

That is the price of five strips instead of three, and it is only ever paid by the sheet — the
strips themselves, mounted a bin apart, do not overlap at all.

## The threshold is dashes, not blur

A drawer reveals the row a dash at a time, so the rule is a count and not a threshold on a
blur. Six dashes clear of the counter edge opens the bin on **Thin**; **Tall** wants twice the
printed height and opens on 5, **Very thin** half of it and opens on 7. Chevrons open on 4 at
Thin's height.

At the dash sheet's 8 mm pitch that is **88 mm of drawer** on Thin, or 72 mm on Tall. To
trigger sooner, print the dashes **smaller**, not fewer: six at a 4 mm pitch clear the edge in
half the travel that six at 8 mm need, and `markers.typ` takes the dash size as a variable if
that turns out to matter more than legibility does.
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
