# Bin marker sheets

`markers.typ` is the source; the three PDFs beside it are what you print.

| File | What is in it |
| --- | --- |
| `BinMarkers_Dashes.pdf` | **Start here.** Rows of equal dashes at five sizes, 3–12 mm. Nothing encoded; the bin is named by where the row appears |
| `BinMarkers_Color.pdf` | Yellow / magenta / cyan strips at six unit sizes (6–18 mm), plus a page of heights |
| `BinMarkers_Mono.pdf` | The same in black and white |
| `BinMarkers_Shapes.pdf` | Bars, slanted and chevron — three looks that read identically |

Print at **100%** — not fit-to-page — on matte stock.

The dash rows are the ones measured against the site: fifteen frames of the real room with
nothing installed produced no false readings, and a row pasted onto those same frames read
every time, down to dashes two samples wide. The colour and bar sheets are kept for comparison
— on this site's footage the original colour settings produced about six false readings per
frame, because two of its three inks sit on the hues the room is full of.

Start with a size that is comfortably too big, mount it, then read the two numbers the debug
overlay prints beside each strip (Settings → Bin Openness → Marker strips → Show debug overlay):

- **unit px / pitch** — samples per printed unit or dash. For dashes, two is the floor and
  nothing divides one width by another, so they hold up far smaller than the bar styles. For
  the bar styles, under six the widths stop separating.
- **×n** — how many scan lines cross the row. Three is the floor, and it is what a narrow rim
  actually limits — about 1.5 cm at this site.

The dash style reads the **full luma frame** rather than the half-size chroma grid the colour
styles need, which is worth exactly double the distance: measured on the site's frames, it
reads a row the half grid cannot see at all. It also means the dashes can be printed half the
size, and since a bin reads open once five dashes clear the counter edge, halving the pitch
halves the travel needed. Five 4 mm dashes clear in about 36 mm of drawer; five 8 mm dashes
need 76 mm.

Fewer than five dashes is not a setting. Below eight alternating runs the room itself starts
producing rows — 3 over fifteen frames at seven, 39 at five.

Work down through the sizes until one of those numbers gets close to its floor, then go back
one. The height page is staggered and cycles the three markers on purpose: the detector merges
same-marker readings that cover the same stretch, so six copies of one marker stacked flush
would collapse into a single reading and tell you nothing.

## Regenerating

```sh
brew install typst
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Dashes.pdf --input style=dashes
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Color.pdf  --input style=color
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Mono.pdf   --input style=mono
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Shapes.pdf --input style=shapes
```

The rhythms drawn here must match `BinMarkerPattern.all` in the app.
`BinMarkerPatternTests.patternsMatchThePrintedSheet` pins them and names this directory, so
changing one without the other fails a test rather than producing a sheet the scanner quietly
cannot read.
