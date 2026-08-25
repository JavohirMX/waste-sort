// Printable bin marker sheets.
//
//   typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Color.pdf   --input style=color
//   typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Mono.pdf    --input style=mono
//   typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Shapes.pdf  --input style=shapes
//
// The rhythms below must match `BinMarkerPattern.all` in the app. `BinMarkerPatternTests`
// pins them and names this file, so changing one without the other fails a test rather than
// producing a sheet the scanner quietly cannot read.

#let style = sys.inputs.at("style", default: "dashes")
#let colored = style == "color" or style == "shapes"

#set page(paper: "a4", flipped: true, margin: 12mm)
#set text(font: ("Helvetica Neue", "Helvetica", "Arial"), size: 9pt, fill: rgb("#1a1a1a"))
#set par(leading: 0.6em, spacing: 0.9em)

// The three printed rhythms. Palindromes, so it does not matter which end faces the camera;
// wide is exactly twice narrow, because bar widths are the first thing distance takes away.
#let markers = (
  (id: 1, bars: (1, 1, 2, 1, 1), ink: rgb("#FFF200"), name: "Yellow"),
  (id: 2, bars: (2, 1, 1, 1, 2), ink: rgb("#EC008C"), name: "Magenta"),
  (id: 3, bars: (2, 1, 2, 1, 2), ink: rgb("#00AEEF"), name: "Cyan"),
)

#let total-units(bars) = bars.sum() + bars.len() - 1

// One bar. Only the outline differs between shapes: the scanner reads one line of pixels at a
// time and never looks above or below it, so any shape whose horizontal cross-section is the
// same at every height reads exactly like a plain rectangle.
// Rounded corners were tried and dropped. Rounding narrows a bar near its ends, which widens
// the gap there — and the gaps are the ruler everything else is measured against. Scanned back
// at 14 samples per unit, a 30% radius reported 21.5 and split three markers into five
// detections; even a 6% radius still reported 15. Identification survived, but the unit px
// readout is the number an operator sizes the print by, and a shape that quietly inflates it
// is worse than no shape at all. Slant and chevron soften the look for free.
#let bar(w, h, shape, fill) = {
  if shape == "rectangle" {
    rect(width: w, height: h, fill: fill, stroke: none)
  } else {
    // A sheared bar has to occupy exactly `w` of layout width, with the shear hanging outside
    // it. Left to lay out naturally the polygon claims `w + shear`, which pushes every
    // following bar along and quietly widens every gap by the shear — and the gaps are the
    // ruler the scanner measures everything else against. The bars would then read as 0.67
    // and 1.33 units instead of 1 and 2, no rhythm would match, and the sheet would look like
    // a detector fault.
    //
    // `place` takes the polygon out of the flow, and half the shear on each side keeps the
    // sticker balanced: at mid-height the bar sits exactly where a rectangle would.
    let s = if shape == "slanted" { h * 0.35 } else { h * 0.22 }
    let points = if shape == "slanted" {
      ((0mm, h), (w, h), (w + s, 0mm), (s, 0mm))
    } else {
      ((0mm, h), (w, h), (w + s, h / 2), (w, 0mm), (0mm, 0mm), (s, h / 2))
    }
    box(width: w, height: h, place(dx: -s / 2, polygon(fill: fill, ..points)))
  }
}

// One sticker: bars, the quiet zone at the two ends, and the cut outline.
//
// The quiet zone is at the ends ONLY. Each scan line is read on its own, so what sits above
// and below a bar is never consulted; what lies beyond the outermost bars is what tells the
// scan where the strip stops. The 3mm top and bottom is for the scissors.
#let strip(marker, unit, height, shape: "rectangle", colored: true) = {
  let fill = if colored { marker.ink } else { rgb("#000000") }
  let bleed = 3mm
  box(
    fill: white,
    stroke: (paint: luma(180), thickness: 0.3mm, dash: "dashed"),
    inset: (x: unit, y: bleed),
    stack(
      dir: ltr,
      ..marker.bars
        .map(b => bar(b * unit, height, shape, fill))
        .intersperse(h(unit)),
    ),
  )
}

#let caption(marker, colored) = {
  let wide = if marker.id == 1 { "one wide bar" } else { str(marker.id) + " wide bars" }
  let parts = if colored { (marker.name, wide) } else { (wide,) }
  text(size: 7.5pt, fill: luma(110), tracking: 0.4pt)[
    #upper("Marker " + str(marker.id) + " · " + parts.join(" · "))
  ]
}

#let bin-line = text(size: 7.5pt, fill: luma(130))[Bin: #box(width: 55mm, line(length: 100%, stroke: 0.3pt + luma(150)))]

#let sticker-block(marker, unit, height, shape: "rectangle", colored: true) = {
  caption(marker, colored)
  v(1.5mm, weak: true)
  strip(marker, unit, height, shape: shape, colored: colored)
  v(1.5mm, weak: true)
  bin-line
  v(5mm)
}

// MARK: - Pages

#let scale-page(unit, height, colored) = {
  let lengths = markers.map(m => total-units(m.bars) * unit + unit * 2)
  // Lengths print as points unless they are divided back out; the whole sheet is authored in
  // millimetres because that is the only unit that means anything once it is on a bin.
  text(size: 15pt, weight: "bold")[Marker strips — #calc.round(unit / 1mm) mm unit]
  v(1mm, weak: true)
  text(size: 9pt, fill: luma(90))[
    Stickers #calc.round(lengths.at(0) / 1mm) – #calc.round(lengths.at(2) / 1mm) mm long,
    #calc.round((height + 6mm) / 1mm) mm tall.
    Print at 100% — no fit-to-page. Matte stock.
  ]
  v(4mm)
  for m in markers { sticker-block(m, unit, height, colored: colored) }
}

#let height-page(unit, colored) = {
  text(size: 15pt, weight: "bold")[How thin can it be]
  v(1mm, weak: true)
  text(size: 9pt, fill: luma(90))[
    Marker 1 at a #calc.round(unit / 1mm) mm unit, in six heights. Three scan lines have to cross a strip before it
    counts, so the short side is what a rim actually limits. Mount the tallest that fits, then
    read the #emph[×n] in the debug overlay — three is the floor.
  ]
  v(4mm)
  // Staggered, and cycling through all three markers, both for the same reason: the detector
  // merges same-marker detections that cover the same stretch — correctly, since a real bin
  // carries one of each. Six copies of one marker stacked flush collapse into a single reading
  // and the page answers nothing. Cycling puts two rows of any one marker far enough apart to
  // stay separate, so each height reports its own ×n.
  for (index, h) in (4mm, 6mm, 8mm, 11mm, 14mm, 20mm).enumerate() {
    let marker = markers.at(calc.rem(index, markers.len()))
    pad(left: index * 22mm)[
      #text(size: 7pt, fill: luma(110), tracking: 0.4pt)[
        #upper(
          str(calc.round(h / 1mm)) + " mm bars · "
            + str(calc.round((h + 6mm) / 1mm)) + " mm sticker · marker " + str(marker.id)
        )
      ]
      #v(1.2mm, weak: true)
      #strip(marker, unit, h, colored: colored)
    ]
    v(4mm)
  }
}

#let shapes = (
  (
    key: "rectangle",
    name: "Bars",
    note: [The baseline. Every scan line across it measures the same widths.],
  ),
  (
    key: "slanted",
    name: "Slanted",
    note: [A sheared bar is exactly as wide at every height, so it reads identically to the
      baseline. Purely a matter of looks.],
  ),
  (
    key: "chevron",
    name: "Chevron",
    note: [Sheared one way above the midline and the other below it — also constant in width at
      every height, so also identical to read.],
  ),
)

// A row of equal dashes, half duty, carrying nothing at all.
//
// Which bin it is comes from where the row appears — the camera is bolted overhead and the
// bins do not move, so position already answers the question a code was being asked to answer.
// What the marker has to be is only unmistakable, and on fifteen frames of the real site with
// nothing installed, nine alternating runs of one pitch never once occurred by accident.
#let dash-row(count, dash, height) = {
  let quiet = dash
  box(
    fill: white,
    stroke: (paint: luma(180), thickness: 0.3mm, dash: "dashed"),
    inset: (x: quiet, y: 3mm),
    stack(
      dir: ltr,
      ..range(count).map(_ => rect(width: dash, height: height, fill: black, stroke: none))
        .intersperse(h(dash)),
    ),
  )
}

#let dash-page(dash, height, count) = {
  let span = count * dash * 2 - dash + dash * 2
  text(size: 15pt, weight: "bold")[Dash row — #calc.round(dash / 1mm) mm dashes]
  v(1mm, weak: true)
  text(size: 9pt, fill: luma(90))[
    #count dashes, #calc.round(span / 1mm) mm long, #calc.round((height + 6mm) / 1mm) mm tall.
    Reads once five dashes are clear of the counter edge — about
    #calc.round((5 * dash * 2 - dash) / 1mm) mm of travel. Print at 100%, matte stock.
  ]
  v(5mm)
  for index in range(3) {
    text(size: 7.5pt, fill: luma(110), tracking: 0.4pt)[#upper("Bin " + str(index + 1))]
    v(1.5mm, weak: true)
    dash-row(count, dash, height)
    v(1.5mm, weak: true)
    bin-line
    v(6mm)
  }
}

// MARK: - Documents

#if style == "dashes" {
  text(size: 18pt, weight: "bold")[Bin marker dash rows]
  v(3mm)
  let notes = (
    (
      "All three rows are identical",
      [There is nothing to tell them apart, and nothing to bind in settings. A row is credited
        to whichever bin it appears nearest, because the camera and the bins do not move —
        which is the whole reason this design has no colour, no rhythm and no code in it.],
    ),
    (
      "Mount along the rim, inside",
      [Where a shut drawer hides the row under the counter. Visible means open. Mount it level:
        the scan walks rows and columns, so a row lying flat or standing upright is found and
        one at an angle is not.],
    ),
    (
      "Five dashes is the threshold",
      [A drawer reveals the row a dash at a time as it slides out from under the edge. Five
        dashes clear of it is what makes the bin read open — a legible rule rather than a
        threshold on a blur. To trigger sooner, print the dashes *smaller*, not fewer: five at
        a 4 mm pitch clear the edge in half the travel that five at 8 mm need. Fewer than five
        is not a setting — below that the room itself starts producing rows.],
    ),
    (
      "Which size to print",
      [Start large and work down. The debug overlay reports the dash count, the pitch in
        samples, and how many scan lines crossed the row. Dashes hold up down to two samples
        of pitch, and this style reads the full luma frame rather than the half-size chroma
        grid the colour styles need — which is worth exactly double the distance. The row must
        be at least twelve samples tall, about 1.5 cm at this site.],
    ),
    (
      "An arm across it costs nothing",
      [Repetition is the design. Covering the middle of the row leaves two shorter rows, and
        the longer one still answers.],
    ),
  )
  for (title, body) in notes {
    text(size: 10.5pt, weight: "bold")[#title]
    v(0.5mm, weak: true)
    text(size: 9pt, fill: luma(70))[#body]
    v(3mm)
  }
  for (dash, count) in ((3mm, 20), (4mm, 18), (6mm, 14), (8mm, 12), (12mm, 9)) {
    pagebreak()
    dash-page(dash, 16mm, count)
  }
} else if style == "shapes" {
  text(size: 18pt, weight: "bold")[Bar shapes]
  v(2mm)
  text(size: 10pt)[
    The scanner reads one line of pixels at a time and never looks above or below it. Any shape
    whose horizontal cross-section is the same at every height therefore reads exactly like a
    plain rectangle — which makes this document a question of how the bins should look, not of
    what works. All three below were rendered and scanned back at three densities; all three
    named all three bins every time.
  ]
  v(2mm)
  text(size: 9pt, fill: luma(90))[
    What is #emph[not] here is rounded corners. Rounding narrows a bar near its ends, which
    widens the gap there — and the gaps are the ruler everything else is measured against.
    Scanned back at 14 samples per unit, a generous radius reported 21.5 and split three
    markers into five detections; even a barely-there radius still reported 15. The bins were
    still identified, but #emph[unit px] is the number you size the print by, and a shape that
    quietly inflates it is worse than no shape at all.
  ]
  v(4mm)
  for s in shapes {
    text(size: 10.5pt, weight: "bold")[#s.name]
    v(0.5mm, weak: true)
    text(size: 9pt, fill: luma(70))[#s.note]
    v(3mm)
  }
  for s in shapes {
    pagebreak()
    text(size: 15pt, weight: "bold")[#s.name]
    v(1mm, weak: true)
    text(size: 9pt, fill: luma(90))[#s.note]
    v(4mm)
    for m in markers { sticker-block(m, 10mm, 14mm, shape: s.key, colored: true) }
  }
} else {
  text(size: 18pt, weight: "bold")[
    Bin marker strips — #if colored { "colour" } else { "black & white" }
  ]
  v(3mm)

  let notes = (
    (
      "Print at 100%",
      [No fit-to-page, or the bars stop being whole units and the rhythm stops resolving. Matte
        stock: gloss under a ceiling lamp throws a highlight that washes the colour out of
        exactly the bars being measured.],
    ),
    (
      "Cut on the dashed line",
      [The white at the two ends is part of the marker — it is what tells the scan where the
        strip stops. The few millimetres above and below are only for cutting.],
    ),
    (
      "Mount inside, and level",
      [The bins are in pull-out drawers, so the strip goes on the rim of the drawer wall, where
        a shut drawer hides it under the counter. Visible means open, and that is the entire
        signal. The scan walks rows and columns, so a strip lying flat or standing upright is
        found and one at an angle is not.],
    ),
    (
      "Mount near the front of the rim",
      [A drawer does not reveal the marker all at once — it slides out from under the counter
        edge. Near the front, the strip clears that edge early; near the back it needs the
        drawer pulled almost the whole way.],
    ),
    (
      "Which size to print",
      [Start large and work down. In the debug overlay each strip reports two numbers:
        #emph[unit px], the samples per printed unit — under six the bar widths stop separating
        — and #emph[×n], how many scan lines cross it, where three is the floor.],
    ),
    (
      if colored { "Then calibrate" } else { "Nothing to calibrate" },
      if colored [
        Yellow, magenta and cyan are the three process inks, each laid down by a single
        cartridge, which is why they reproduce consistently between printers. Once mounted,
        open a drawer with the debug overlay showing and tap #emph[Calibrate colours] once —
        that records what this room's light actually does to the print.
      ] else [
        Identity here comes from the bar rhythm alone, so there is no colour to record. The
        trade is that a strip too small or too soft to measure is not a bin read uncertainly —
        it is a bin lost entirely. This style wants a larger print than colour does.
      ],
    ),
  )
  for (title, body) in notes {
    text(size: 10.5pt, weight: "bold")[#title]
    v(0.5mm, weak: true)
    text(size: 9pt, fill: luma(70))[#body]
    v(3mm)
  }

  for unit in (6mm, 8mm, 10mm, 12mm, 15mm, 18mm) {
    pagebreak()
    scale-page(unit, 14mm, colored)
  }
  pagebreak()
  height-page(10mm, colored)
}
