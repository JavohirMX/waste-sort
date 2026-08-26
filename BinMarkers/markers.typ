// Printable bin marker sheets — one kind of marker per sheet, every size of it on that sheet.
//
//   typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Dashes.pdf   --input kind=dashes
//   typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Chevrons.pdf --input kind=chevrons
//   typst compile --root . BinMarkers/markers.typ BinMarkers/BinMarkers_Bars.pdf     --input kind=bars
//
// One sheet, one kind, several sizes: print all three, cut everything out, and swap sizes
// under the camera until the debug overlay stops being marginal. That is the only way the
// right size gets chosen, because it depends on the lens, the mount height and the room.
//
// Nothing here encodes which bin it is. Every bin carries the same strip, and a marker is
// credited to whichever bin it appears nearest — the camera is bolted overhead and the bins
// do not move, so position already answers the question a code was being asked to answer.

#let kind = sys.inputs.at("kind", default: "dashes")
#let bent = kind == "chevrons"

// The dash sheet prints its strips to one fixed length — the widest an A4 sheet holds — so its
// margin is narrower than the others'. Printing a marker at anything but 100% is printing a
// different marker, so the page has to give the strip its full width rather than scale it.
#let page-margin = if kind == "dashes" { 11mm } else { 12mm }
#let content-width = 297mm - 2 * page-margin

#set page(paper: "a4", flipped: true, margin: page-margin)
#set text(font: ("Helvetica Neue", "Helvetica", "Arial"), size: 9pt, fill: rgb("#1a1a1a"))
#set par(leading: 0.6em)

// The quiet zone is at the two ends ONLY. Each scan line is read on its own and what sits
// above or below a mark is never consulted; what lies beyond the outermost mark is what tells
// the scan where the marker stops. The 3 mm top and bottom is for the scissors.
#let cut(quiet, body) = box(
  fill: white,
  stroke: (paint: luma(180), thickness: 0.3mm, dash: "dashed"),
  inset: (x: quiet, y: 3mm),
  body,
)

#let caption(body) = text(size: 7.5pt, fill: luma(110), tracking: 0.4pt)[#upper(body)]

// One printed mark. A chevron has to occupy exactly `w` of layout width with the bend hanging
// outside it: left to lay out naturally the polygon claims `w + shear`, which pushes every
// following mark along and quietly widens every gap — and the gaps are the ruler the scanner
// measures everything else against. `place` takes it out of the flow, and half the shear on
// each side keeps the sticker balanced.
//
// Half the height of shear, so the row's edge climbs one sample per scan line and falls one
// per line after the apex. Measured: at that bend the scanner reads every rendered row at
// every size, and fifteen frames of the empty room produce nothing.
#let mark(w, h) = if not bent {
  rect(width: w, height: h, fill: black, stroke: none)
} else {
  let s = h * 0.5
  box(width: w, height: h, place(dx: -s / 2, polygon(
    fill: black,
    (0mm, h), (w, h), (w + s, h / 2), (w, 0mm), (0mm, 0mm), (s, h / 2),
  )))
}

#let dash-row(count, dash, height) = cut(dash, stack(
  dir: ltr,
  ..range(count).map(_ => mark(dash, height)).intersperse(h(dash)),
))

// A strip cut to a fixed length, filled with as many dashes of a fixed pitch as go into it.
//
// The count falls out of the two measurements rather than being chosen: a row opens and closes
// on a dash with a gap between each pair, and it needs a quiet zone of at least one dash at
// either end, because what lies beyond the outermost dash is the only thing that tells the
// scan where the row stops. Whatever the dashes do not use is spent widening those two quiet
// zones, which is the one place the leftover can go without disturbing the pitch — and the
// pitch has to be exact, since agreement between the runs is the entire signature.
//
// At 275 mm with an 8 mm dash: 16 dashes span 248 mm and each end gets 13.5 mm.
#let filled-row(length, dash) = {
  let count = calc.floor((length - dash) / (2 * dash))
  let span = count * dash * 2 - dash
  (count: count, span: span, quiet: (length - span) / 2)
}

/// A strip whose outer dimensions — the dashed line you cut along — are exactly what is asked
/// for. The 3 mm above and below the dashes is inside that, so a 20 mm strip carries 14 mm of
/// printed height.
#let fixed-strip(length, height, dash) = {
  let row = filled-row(length, dash)
  box(
    width: length,
    fill: white,
    stroke: (paint: luma(180), thickness: 0.3mm, dash: "dashed"),
    inset: (x: row.quiet, y: 3mm),
    stack(
      dir: ltr,
      ..range(row.count).map(_ => mark(dash, height - 6mm)).intersperse(h(dash)),
    ),
  )
}

// One bar rhythm, printed for every bin. It has to be one the app knows — the scanner still
// refuses a rhythm it never printed, which is what keeps a striped carton out — but *which*
// one no longer means anything, so all three bins get the same one.
#let bars = (1, 1, 2, 1, 1)
#let bar-units = bars.sum() + bars.len() - 1

#let bar-strip(unit, height) = cut(unit, stack(
  dir: ltr,
  ..bars.map(b => rect(width: b * unit, height: height, fill: black, stroke: none))
    .intersperse(h(unit)),
))

#let mm-of(length) = calc.round(length / 1mm, digits: 1)

#let header(title, lead) = {
  text(size: 16pt, weight: "bold")[#title]
  v(1mm, weak: true)
  text(size: 8.5pt, fill: luma(90))[#lead]
  v(4.5mm)
}

#let block-gap = 5mm

// MARK: - Sheets

#if kind == "bars" {
  header(
    [Bin markers — bars],
    [Settings → Bin Openness → Marker strips → #emph[Bars]. Five black bars, one or two units
      wide, with one-unit gaps; the widths are measured rather than counted, so this wants the
      largest print of the three and is the first to fail at distance. All five below are the
      same rhythm — every bin carries the same strip. Print at 100%, no fit-to-page, matte
      stock, and cut on the dashed line.],
  )
  // Alternating sides, and not for looks. Every strip here is the same rhythm, and the
  // scanner joins same-rhythm readings that cover the same stretch — correctly, because a
  // blurred strip's middle can read as nothing while its two edges still alternate. Stacked
  // flush, five identical strips are one reading and the sheet answers nothing; pushed to
  // opposite edges, no two adjacent ones share a stretch and each reports its own.
  for (index, (unit, height)) in (
    (6mm, 8mm), (8mm, 10mm), (10mm, 12mm), (12mm, 16mm), (15mm, 20mm),
  ).enumerate() {
    let strip-width = bar-units * unit + unit * 2
    let indent = if calc.even(index) { 0mm } else { content-width - strip-width }
    pad(left: indent)[
      #caption(
        str(mm-of(unit)) + " mm unit · " + str(mm-of(strip-width)) + " × "
          + str(mm-of(height + 6mm)) + " mm sticker"
      )
      #v(1.5mm, weak: true)
      #bar-strip(unit, height)
    ]
    v(block-gap)
  }
} else if kind == "dashes" {
  // Six strips to mount, not a range of sizes to choose between: two sets of three, one strip
  // per bin, differing only in how tall they are. Both sets carry the same 8 mm dash, so the
  // travel a drawer needs before it reads open is the same either way — the sets exist to
  // settle how much height the rim can actually give up.
  let dash = 8mm
  let length = content-width
  let row = filled-row(length, dash)
  // A page per height, five strips on each: three bins and two spares, since a strip that goes
  // on crooked or picks up a thumbprint is cheaper to replace than to reprint. Splitting the
  // heights across two pages is also what stops them being mixed up once they are cut apart.
  //
  // The space between them is `1fr`, so the five spread to fill whatever the header leaves.
  // That is worth having rather than a fixed gap: the scan joins rows that cover the same
  // stretch and lie within a few scan lines of each other — right for one row glimpsed through
  // a gap, wrong for two stickers stacked flush — so the further apart they sit, the closer
  // the sheet laid flat under the camera comes to reading as five rows rather than one. On a
  // bin it never arises, because the bins are side by side and share no stretch at all.
  let copies = 5
  for (index, height) in (20mm, 24mm).enumerate() {
    if index > 0 { pagebreak() }
    header(
      [Bin markers — dashes, #mm-of(length) × #mm-of(height) mm],
      [Settings → Bin Openness → Marker strips → #emph[Dashes]. Set #(index + 1) of 2:
        #copies strips — three bins and two spares — #mm-of(length) mm long and
        #mm-of(height) mm tall, carrying #row.count dashes of #mm-of(dash) mm with
        #mm-of(row.quiet) mm of quiet paper at either end. #mm-of(height - 6mm) mm of that
        height is printed; the rest is for the scissors. Every bin carries the same strip — a
        marker is credited to whichever bin it appears nearest — so these are interchangeable.
        #if height >= 24mm [
          Tall enough for the #emph[Tall] row height, which opens once 5 dashes are clear of
          the counter edge: #mm-of(dash * 9) mm of drawer.
        ] else [
          #mm-of(height - 6mm) mm is short of the #emph[Tall] row height at this site's scale,
          so this set reads on #emph[Thin] — 6 dashes clear, or #mm-of(dash * 11) mm of drawer.
        ]
        Print at 100%, no fit-to-page, matte stock, and cut on the dashed line.],
    )
    for copy in range(copies) {
      fixed-strip(length, height, dash)
      if copy < copies - 1 { v(1fr) }
    }
  }
} else {
  header(
    [Bin markers — chevrons],
    [Settings → Bin Openness → Marker strips → #emph[Chevrons]. Each dash bent into a V,
      which no straight edge in the room can counterfeit — a counter lip or a wood seam seen in
      perspective ramps steadily, and none of them can reverse that ramp at a midline. Opens on
      4 dashes where a plain row of the same height needs 6, for about twice the time a frame.
      Print at 100%, no fit-to-page, matte stock, and cut on the dashed line.],
  )
  for (dash, height, count) in (
    (3mm, 8mm, 20), (4mm, 10mm, 18), (6mm, 14mm, 14), (8mm, 18mm, 12), (12mm, 24mm, 9),
  ) {
    // A drawer reveals the row a dash at a time as it slides out from under the counter edge,
    // so the pitch is what the travel is measured in — and it is the number worth printing
    // beside each size, because it is the one an operator can feel.
    caption(
      str(mm-of(dash)) + " mm dashes · "
        + str(mm-of(dash * (2 * count + 1))) + " × "
        + str(mm-of(height + 6mm)) + " mm sticker · "
        + str(count) + " dashes · opens after "
        + str(mm-of(dash * 7)) + " mm of drawer"
    )
    v(1.5mm, weak: true)
    dash-row(count, dash, height)
    v(block-gap)
  }
}
