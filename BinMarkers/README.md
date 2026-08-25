# Bin marker sheets

`markers.typ` is the source; the three PDFs beside it are what you print.

| File | What is in it |
| --- | --- |
| `BinMarkers_Color.pdf` | Yellow / magenta / cyan strips at six unit sizes (6–18 mm), plus a page of heights |
| `BinMarkers_Mono.pdf` | The same in black and white |
| `BinMarkers_Shapes.pdf` | Bars, slanted and chevron — three looks that read identically |

Print at **100%** — not fit-to-page — on matte stock.

Start with a size that is comfortably too big, mount it, then read the two numbers the debug
overlay prints beside each strip (Settings → Bin Openness → Marker strips → Show debug overlay):

- **unit px** — samples per printed unit. Under six the bar widths stop separating and the
  strip is named by its ink alone; under three it is not found at all.
- **×n** — how many scan lines cross the strip. Three is the floor, and it is what a narrow
  rim actually limits.

Work down through the sizes until one of those numbers gets close to its floor, then go back
one. The height page is staggered and cycles the three markers on purpose: the detector merges
same-marker readings that cover the same stretch, so six copies of one marker stacked flush
would collapse into a single reading and tell you nothing.

## Regenerating

```sh
brew install typst
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Color.pdf  --input style=color
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Mono.pdf   --input style=mono
typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Shapes.pdf --input style=shapes
```

The rhythms drawn here must match `BinMarkerPattern.all` in the app.
`BinMarkerPatternTests.patternsMatchThePrintedSheet` pins them and names this directory, so
changing one without the other fails a test rather than producing a sheet the scanner quietly
cannot read.
