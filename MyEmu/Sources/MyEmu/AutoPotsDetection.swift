// HP detection for AutoPots, ported line for line from autopotsCO (HpDetector.kt, SimpleHp.kt,
// github.com/nanotechs001/autopots-co) so its measured constants and tests carry over unchanged.
// Pure functions over a frame of RGB pixels; no screen capture or input here.

/// A read-only frame of packed 0xRRGGBB pixels. The caller keeps (x, y) in bounds.
protocol PixelFrame {
    var width: Int { get }
    var height: Int { get }
    func rgb(_ x: Int, _ y: Int) -> Int
}

/// RGBA8888 pixels in memory, as the engine's screenshot call delivers them.
struct RGBAFrame: PixelFrame {
    let width: Int
    let height: Int
    let pixels: UnsafeRawBufferPointer

    func rgb(_ x: Int, _ y: Int) -> Int {
        let i = (y * width + x) * 4
        return Int(pixels[i]) << 16 | Int(pixels[i + 1]) << 8 | Int(pixels[i + 2])
    }
}

private func red(_ c: Int) -> Int { (c >> 16) & 0xFF }
private func green(_ c: Int) -> Int { (c >> 8) & 0xFF }
private func blue(_ c: Int) -> Int { c & 0xFF }

/// The default view's HP orb: HP drains from the top, leaving a near-black band; remaining HP is
/// 1 − the drained share of rows.
enum HpDetector {
    /// A row counts as drained when more than this share of it is empty.
    static let rowFill: Float = 0.4
    /// Default max channel brightness for a pixel to count as drained.
    static let darkMax = 130
    /// A drained pixel's red may not exceed green/blue by this much (neutral, not shaded red).
    static let emptyRedDominance = 22

    // The sampled inner rectangle of the red-half box: off the curved left third, the divider,
    // the rim glow at the top and the bottom tip.
    static let insetLeft: Float = 0.35
    static let insetRight: Float = 0.08
    static let insetTop: Float = 0.08
    static let insetBottom: Float = 0.04

    static func isEmpty(_ rgb: Int, darkMax: Int = darkMax) -> Bool {
        let r = red(rgb), g = green(rgb), b = blue(rgb)
        return max(r, g, b) < darkMax && (r - max(g, b)) < emptyRedDominance
    }

    /// Remaining-HP fraction 0…1 in the rectangle, or −1 if it's degenerate.
    static func emptyFraction<F: PixelFrame>(_ frame: F, left: Int, top: Int, width: Int, height: Int,
                                             darkMax: Int = darkMax) -> Float {
        let l = max(left, 0), t = max(top, 0)
        let r = min(left + width, frame.width), b = min(top + height, frame.height)
        guard r - l >= 2, b - t >= 2 else { return -1 }
        var emptyRows = 0
        for y in t..<b {
            var drained = 0
            for x in l..<r where isEmpty(frame.rgb(x, y), darkMax: darkMax) { drained += 1 }
            if Float(drained) / Float(r - l) > rowFill { emptyRows += 1 }
        }
        return 1 - Float(emptyRows) / Float(b - t)
    }

    /// Remaining HP for the red-half box [left, top, width, height] (applies the inner inset).
    static func hpFractionArc<F: PixelFrame>(_ frame: F, _ left: Int, _ top: Int, _ width: Int, _ height: Int,
                                             darkMax: Int = darkMax) -> Float {
        let sl = left + Int(insetLeft * Float(width))
        let sr = left + width - Int(insetRight * Float(width))
        let st = top + Int(insetTop * Float(height))
        let sb = top + height - Int(insetBottom * Float(height))
        return emptyFraction(frame, left: sl, top: st, width: sr - sl, height: sb - st, darkMax: darkMax)
    }

    /// Share of the sampled rectangle that is HP-red (~0.8 on the orb at full HP, ≤ ~0.2 off it),
    /// or −1 if degenerate. Sanity check for a hand-placed box.
    static func hpRedFraction<F: PixelFrame>(_ frame: F, _ left: Int, _ top: Int, _ width: Int, _ height: Int) -> Float {
        let sl = max(left + Int(insetLeft * Float(width)), 0)
        let sr = min(left + width - Int(insetRight * Float(width)), frame.width)
        let st = max(top + Int(insetTop * Float(height)), 0)
        let sb = min(top + height - Int(insetBottom * Float(height)), frame.height)
        guard sr - sl >= 2, sb - st >= 2 else { return -1 }
        var redCount = 0
        for y in st..<sb {
            for x in sl..<sr {
                let c = orbClass(frame.rgb(x, y))
                if c == .red || c == .darkRed { redCount += 1 }
            }
        }
        return Float(redCount) / Float((sr - sl) * (sb - st))
    }

    // MARK: Automatic orb location

    private static let orbMinHeightPerWidth: Float = 1.75
    private static let orbMaxHeightPerWidth: Float = 2.15
    private static let orbTopMarginPerHeight: Float = 0.13
    private static let orbHeightPerWidth: Float = 2.25
    private static let orbMinBlue: Float = 0.20
    private static let orbDividerMin: Float = 0.42
    private static let orbDividerMax: Float = 0.58
    private static let searchTop: Float = 0.40
    private static let searchLeft: Float = 0.30
    private static let searchRight: Float = 0.70
    private static let minChordPerU: Float = 0.012
    private static let maxGapPerH: Float = 0.04
    private static let gapRowsPerU: Float = 0.03
    private static let maxCandidates = 6
    private static let minRadiusPerU: Float = 0.025
    private static let maxRadiusPerH: Float = 0.12
    private static let minRowsPerRadius: Float = 0.6
    private static let maxSpanPerRadius: Float = 3.0
    private static let minRunPerRadius: Float = 0.33
    private static let minWidthPerRadius: Float = 0.7
    private static let maxWidthPerRadius: Float = 1.45
    private static let minPeakPerRadius: Float = 0.9

    /// The HP potion sits beside the orb: its tap point relative to the red-half box.
    static let potionXPerWidth: Float = -0.80
    static let potionYPerHeight: Float = 0.65

    private enum OrbClass { case other, red, darkRed, blue }

    private static func orbClass(_ rgb: Int) -> OrbClass {
        let r = red(rgb), g = green(rgb), b = blue(rgb)
        let gb = max(g, b)
        if r >= 120 && r - gb >= 50 { return .red }
        if b >= 110 && b - max(r, g) >= 35 { return .blue }
        if r >= 80 && r - gb >= 40 { return .darkRed }
        return .other
    }

    /// The red half of the HP orb as [left, top, width, height], or nil when no orb is visible
    /// (e.g. the game is in simple view). Finds the straight red|blue divider, then measures the half.
    static func autoMapOrb<F: PixelFrame>(_ frame: F) -> [Int]? {
        let w = frame.width, h = frame.height
        guard w >= 32, h >= 32 else { return nil }
        let u = min(Float(h), Float(w) * 9 / 16)
        var best: [Int]?
        var bestRows = -1
        for c in orbCandidates(frame, u: u) {
            let (xr, yA, yB, rows, r) = (c[0], c[1], c[2], c[3], c[4])
            let divider = Float(xr) / Float(w)
            if divider < orbDividerMin || divider > orbDividerMax { continue }
            if Float(r) < minRadiusPerU * u || Float(r) > maxRadiusPerH * Float(h) { continue }
            if Float(rows) < minRowsPerRadius * Float(r) { continue }
            if Float(yB - yA) > maxSpanPerRadius * Float(r) { continue }
            guard let box = measureOrb(frame, xr: xr, yA: yA, yB: yB, radius: r) else { continue }
            if rows > bestRows { bestRows = rows; best = box }
        }
        return best
    }

    /// Stage 1: rows where a red run ends and a blue run starts across the divider bar, grouped by
    /// divider x into vertical chains: [dividerX, firstRow, lastRow, rowCount, radius], strongest first.
    private static func orbCandidates<F: PixelFrame>(_ frame: F, u: Float) -> [[Int]] {
        let w = frame.width, h = frame.height
        let y0 = Int(Float(h) * searchTop)
        let x0 = Int(Float(w) * searchLeft), x1 = Int(Float(w) * searchRight)
        let bw = x1 - x0
        let minChord = max(3, Int(u * minChordPerU))
        let maxGap = max(4, Int(Float(h) * maxGapPerH))

        var rowCls = [OrbClass](repeating: .other, count: bw)
        var hits: [[Int]] = [] // [y, dividerX (last red), redLength, blueLength]
        for y in y0..<h {
            for x in x0..<x1 { rowCls[x - x0] = orbClass(frame.rgb(x, y)) }
            var run = 0
            for i in 0...bw {
                if i < bw && rowCls[i] == .red { run += 1; continue }
                if run >= minChord {
                    // The blue half must start within the divider-bar gap (red resuming means it wasn't one).
                    var xb = -1
                    var g = i
                    let gEnd = min(bw - 1, i + maxGap)
                    while g <= gEnd {
                        if rowCls[g] == .blue { xb = g; break }
                        if rowCls[g] == .red { break }
                        g += 1
                    }
                    if xb >= 0 {
                        var k = xb
                        while k < bw && rowCls[k] == .blue { k += 1 }
                        if k - xb >= minChord { hits.append([y, x0 + i - 1, run, k - xb]) }
                    }
                }
                run = 0
            }
        }

        let gapRows = max(3, Int(u * gapRowsPerU))
        var out: [[Int]] = []
        var pool = hits
        var count = [Int](repeating: 0, count: w)
        while !pool.isEmpty && out.count < maxCandidates {
            // The divider x with the most rows (±2 px: the orb's is straight).
            for i in count.indices { count[i] = 0 }
            for hit in pool { count[hit[1]] += 1 }
            var bestX = -1, bestN = 0
            for x in x0..<x1 where count[x] != 0 {
                var n = 0
                for d in -2...2 { let k = x + d; if k >= 0 && k < w { n += count[k] } }
                if n > bestN { bestN = n; bestX = x }
            }
            if bestN < 4 { break }
            let group = pool.filter { abs($0[1] - bestX) <= 2 }.sorted { $0[0] < $1[0] }
            pool.removeAll { abs($0[1] - bestX) <= 2 }
            // Longest vertical chain of those rows.
            var bs = 0, bl = 0, s = 0
            for i in 1...group.count where i == group.count || group[i][0] - group[i - 1][0] > gapRows {
                if i - s > bl { bl = i - s; bs = s }
                s = i
            }
            let chain = Array(group[bs..<(bs + bl)])
            // The radius is the longest chord (highlights cut many short), capped against an outlier.
            let reds = chain.map { $0[2] }.sorted()
            let p75 = reds[Int(0.75 * Float(reds.count - 1))]
            let radius = min(reds.last!, Int(1.35 * Float(p75)) + 1)
            let xr = chain.map { $0[1] }.sorted()[chain.count / 2]
            out.append([xr, chain.first![0], chain.last![0], chain.count, radius])
        }
        return out
    }

    /// Stage 2: measure the red-half box around a stage-1 candidate.
    private static func measureOrb<F: PixelFrame>(_ frame: F, xr: Int, yA: Int, yB: Int, radius: Int) -> [Int]? {
        let w = frame.width, h = frame.height
        let wx0 = max(0, xr - Int(1.8 * Float(radius))), wx1 = min(w, xr + 3)
        let wy0 = max(0, yA - radius), wy1 = min(h, yB + radius + 1)
        let n = wx1 - wx0
        guard n > 0, wy1 > wy0 else { return nil }
        let minRun = max(3, Int(minRunPerRadius * Float(radius)))

        // Per column: strong-red count and the top/bottom of its longest strong-red run (shaded red
        // bridges a run; stray sparks don't join it).
        var colCount = [Int](repeating: 0, count: n)
        var colBottom = [Int](repeating: -1, count: n)
        var colTop = [Int](repeating: -1, count: n)
        for i in 0..<n {
            let x = wx0 + i
            var cnt = 0, best = 0, bottom = -1, top = -1
            var inRun = false, runTop = 0, runBottom = 0
            for y in wy0..<wy1 {
                let c = orbClass(frame.rgb(x, y))
                if c == .red {
                    cnt += 1
                    if !inRun { inRun = true; runTop = y }
                    runBottom = y
                    if runBottom - runTop + 1 > best { best = runBottom - runTop + 1; bottom = runBottom; top = runTop }
                } else if !(inRun && c == .darkRed) {
                    inRun = false
                }
            }
            colCount[i] = cnt; colBottom[i] = bottom; colTop[i] = top
        }

        // Contiguous column runs (gap ≤ 3) with enough red.
        var runs: [[Int]] = []
        var previous = -10
        for i in 0..<n where colCount[i] >= minRun {
            if runs.isEmpty || i - previous > 3 { runs.append([i, i]) } else { runs[runs.count - 1][1] = i }
            previous = i
        }

        // The red half: the run ending at the divider, about the candidate's radius wide, with tall
        // red columns and the blue half beside it.
        var pick: (left: Int, right: Int)?
        var pickBottom = 0
        var pickDistance = Int.max
        let edgeTolerance = max(3, Int(0.2 * Float(radius)))
        for run in runs {
            let left = wx0 + run[0], right = wx0 + run[1]
            let rw = right - left + 1
            let d = abs(right - xr)
            if d > edgeTolerance { continue }
            if Float(rw) < minWidthPerRadius * Float(radius) || Float(rw) > maxWidthPerRadius * Float(radius) { continue }
            let peak = colCount[run[0]...run[1]].max() ?? 0
            if Float(peak) < minPeakPerRadius * Float(radius) { continue }
            // Bottom edge: median of the last columns' run bottoms (divider side).
            let bottoms = (max(run[0], run[1] - 3)...run[1]).map { colBottom[$0] }.filter { $0 >= 0 }.sorted()
            if bottoms.isEmpty { continue }
            let bottom = bottoms[bottoms.count / 2]
            if blueFraction(frame, right: right, runWidth: rw, bottom: bottom) < orbMinBlue { continue }
            if d < pickDistance { pickDistance = d; pick = (wx0 + run[0], wx0 + run[1]); pickBottom = bottom }
        }
        guard let run = pick else { return nil }
        let bottom = pickBottom
        let rw = run.right - run.left + 1

        // Top edge: the strong-red apex (3rd-smallest column top rides over spark-polluted columns),
        // trusted only when the height matches a full orb; otherwise the proportions decide.
        let tops = (run.left...run.right).map { colTop[$0 - wx0] }.filter { $0 >= 0 }.sorted()
        if tops.isEmpty { return nil }
        let apex = tops[min(2, tops.count - 1)]
        let measuredH = bottom - apex
        var boxW = rw + 2
        var left = run.left
        var top: Int
        var boxH: Int
        if Float(measuredH) >= orbMinHeightPerWidth * Float(rw) && Float(measuredH) <= orbMaxHeightPerWidth * Float(rw) {
            top = apex - Int(orbTopMarginPerHeight * Float(measuredH))
            boxH = bottom + 3 - top
        } else {
            boxH = Int(orbHeightPerWidth * Float(boxW))
            top = bottom + 3 - boxH
        }
        // Grow the box 2.5% per side horizontally and 4.5% vertically: the dim rim and curved tips
        // sit just outside the strong red, and the drain band at the top registers earlier.
        let padX = max(Int(Float(boxW) * 0.025), 1)
        let padY = max(Int(Float(boxH) * 0.045), 2)
        left -= padX; boxW += 2 * padX
        top -= padY; boxH += 2 * padY
        if top < 0 { return nil }
        return [left, top, boxW, boxH]
    }

    /// Share of MP-blue pixels right of the red run at the orb's height.
    private static func blueFraction<F: PixelFrame>(_ frame: F, right: Int, runWidth rw: Int, bottom: Int) -> Float {
        let by0 = max(Int(Float(bottom) - 1.6 * Float(rw)), 0)
        let by1 = min(Int(Float(bottom) - 0.2 * Float(rw)), frame.height)
        let bx0 = min(right + 4, frame.width - 1)
        let bx1 = min(right + 4 + rw, frame.width)
        guard by1 > by0, bx1 > bx0 else { return 0 }
        var blueCount = 0
        for y in by0..<by1 {
            for x in bx0..<bx1 where orbClass(frame.rgb(x, y)) == .blue { blueCount += 1 }
        }
        return Float(blueCount) / Float((by1 - by0) * (bx1 - bx0))
    }
}

/// The game's simple view: "HP: 100%" text at the top left. A template of the "100%" glyphs taken
/// at full HP stops matching as soon as the value changes.
enum SimpleHp {
    static let bright = 200

    static func isTextBright(_ rgb: Int) -> Bool { min(red(rgb), green(rgb), blue(rgb)) >= bright }

    struct MapResult: Equatable {
        let left: Int, top: Int, width: Int, height: Int
        let potionX: Float, potionY: Float
        let fromFallback: Bool
        var potionFound = false
    }

    // Reference positions (1280×860): digits box x92…140 y7…20, red potion at (139, 83). The game
    // anchors its UI to screen height, so everything scales by height.
    private static let refHeight: Float = 860
    private static let boxX: Float = 92, boxY: Float = 7, boxW: Float = 49, boxH: Float = 14
    private static let potX: Float = 139, potY: Float = 83

    private static func fallback(width: Int, height: Int) -> MapResult {
        let s = Float(height) / refHeight
        return MapResult(left: Int(boxX * s), top: Int(boxY * s), width: max(Int(boxW * s), 12),
                         height: max(Int(boxH * s), 8), potionX: potX * s, potionY: potY * s, fromFallback: true)
    }

    /// Finds the "100%" digits and the red potion on a full-resolution frame; falls back to
    /// reference-scaled positions when the text can't be segmented.
    static func autoMap<F: PixelFrame>(_ frame: F) -> MapResult {
        let w = frame.width, h = frame.height
        let winX = w / 4
        let winY = min(max(Int(Float(h) * 0.045), 24), h)

        // The text band is the longest run of strong bright rows.
        var rowCount = [Int](repeating: 0, count: winY)
        for y in 0..<winY {
            var c = 0
            for x in 0..<winX where isTextBright(frame.rgb(x, y)) { c += 1 }
            rowCount[y] = c
        }
        let maxRow = rowCount.max() ?? 0
        if maxRow < 4 { return fallback(width: w, height: h) }
        let cut = max(2, maxRow / 4)
        var bestS = -1, bestE = -1, s = -1
        for y in 0..<winY {
            if rowCount[y] >= cut {
                if s < 0 { s = y }
            } else if s >= 0 {
                if bestS < 0 || y - s > bestE - bestS { bestS = s; bestE = y }
                s = -1
            }
        }
        if s >= 0 && (bestS < 0 || winY - s > bestE - bestS) { bestS = s; bestE = winY }
        if bestS < 0 { return fallback(width: w, height: h) }
        let top = bestS
        let textH = bestE - bestS
        if textH < 6 { return fallback(width: w, height: h) }

        // Glyph clusters inside the band (a gap is ≥ 2 empty columns).
        var clusters: [[Int]] = []
        var lastBright = -3
        for x in 0..<winX {
            var has = false
            for y in top..<bestE where isTextBright(frame.rgb(x, y)) { has = true; break }
            if has {
                if clusters.isEmpty || x - lastBright >= 2 { clusters.append([x, x]) } else { clusters[clusters.count - 1][1] = x }
                lastBright = x
            }
        }
        if clusters.count < 4 { return fallback(width: w, height: h) }

        // Only the first group ("HP: 100%"): cut at the big gap before "MP:".
        let groupGap = Int(2.5 * Float(textH))
        var lastIndex = clusters.count - 1
        for i in 1..<clusters.count where clusters[i][0] - clusters[i - 1][1] > groupGap {
            lastIndex = i - 1
            break
        }
        if lastIndex < 3 { return fallback(width: w, height: h) }

        // The widest gap in the group follows "HP:"; everything right of it is "100%".
        var gapIndex = -1, widest = 0
        for i in 1...lastIndex {
            let gap = clusters[i][0] - clusters[i - 1][1]
            if gap > widest { widest = gap; gapIndex = i }
        }
        var right: Int, left: Int
        let minSelection = Int(1.5 * Float(textH))
        if gapIndex > 0 && widest >= max(4, textH / 3) && clusters[lastIndex][1] - clusters[gapIndex][0] >= minSelection {
            left = clusters[gapIndex][0]
            right = clusters[lastIndex][1]
        } else {
            // No clear space: merge digits right to left, leaving out the last cluster ('%').
            let digitGap = max(3, textH / 2)
            right = clusters[lastIndex - 1][1]
            left = clusters[lastIndex - 1][0]
            if lastIndex >= 2 {
                for i in stride(from: lastIndex - 2, through: 0, by: -1) {
                    if left - clusters[i][1] <= digitGap { left = clusters[i][0] } else { break }
                }
            }
        }
        if right - left < 8 { return fallback(width: w, height: h) }

        let boxL = max(left - 1, 0), boxT = max(top - 1, 0)
        let boxWidth = min(right - left + 3, w - boxL)
        let boxHeight = min(textH + 2, h - boxT)

        // The red potion: strong-red centroid below the text (dominance > 90 keeps the MP potion out).
        var sx = 0, sy = 0, cnt = 0
        let py0 = bestE + 4, py1 = min(Int(Float(h) * 0.18), h), px1 = Int(Float(w) * 0.2)
        if py1 > py0 {
            for y in py0..<py1 {
                for x in 0..<px1 {
                    let c = frame.rgb(x, y)
                    let r = red(c)
                    if r > 150 && r - max(green(c), blue(c)) > 90 { sx += x; sy += y; cnt += 1 }
                }
            }
        }
        let potionFound = cnt >= 60
        let scale = Float(h) / refHeight
        return MapResult(left: boxL, top: boxT, width: boxWidth, height: boxHeight,
                         potionX: potionFound ? Float(sx) / Float(cnt) : potX * scale,
                         potionY: potionFound ? Float(sy) / Float(cnt) : potY * scale,
                         fromFallback: false, potionFound: potionFound)
    }

    // MARK: Adaptive template

    static let cellDark: UInt8 = 0, cellText: UInt8 = 1, cellEdge: UInt8 = 2
    /// Below this the text is hidden or covered and the frame is unreadable.
    static let minTextLevel = 160
    /// Required gap between the dark and bright means for there to be text at all.
    static let minContrast: Float = 48
    /// Neutral band around the split (anti-aliased glyph edges), never scored.
    static let edgeMargin: Float = 24
    private static let signaturePrefix = "2:"

    private static func minChannel(_ c: Int) -> Int { min(red(c), green(c), blue(c)) }

    /// Two-means glyph/background split of the box, or nil when there's no text to split.
    private static func threshold(_ values: [Int]) -> Float? {
        guard let lo = values.min(), let hi = values.max(), hi >= minTextLevel else { return nil }
        func means(_ t: Float) -> (low: Float, high: Float)? {
            var sumL = 0, cntL = 0, sumH = 0, cntH = 0
            for v in values {
                if Float(v) < t { sumL += v; cntL += 1 } else { sumH += v; cntH += 1 }
            }
            guard cntL > 0, cntH > 0 else { return nil }
            return (Float(sumL) / Float(cntL), Float(sumH) / Float(cntH))
        }
        var t = Float(lo + hi) / 2
        for _ in 0..<8 {
            guard let m = means(t) else { return nil }
            let next = (m.low + m.high) / 2
            let settled = abs(next - t) < 0.5
            t = next
            if settled { break }
        }
        guard let m = means(t), m.high - m.low >= minContrast else { return nil }
        return t
    }

    private static func boxValues<F: PixelFrame>(_ frame: F, _ left: Int, _ top: Int, _ width: Int, _ height: Int,
                                                 scale: Int) -> [Int]? {
        let sl = left / scale, st = top / scale, sw = width / scale, sh = height / scale
        guard sw >= 2, sh >= 2, sl >= 0, st >= 0, sl + sw <= frame.width, st + sh <= frame.height else { return nil }
        var out: [Int] = []
        out.reserveCapacity(sw * sh)
        for y in st..<(st + sh) { for x in sl..<(sl + sw) { out.append(minChannel(frame.rgb(x, y))) } }
        return out
    }

    /// The tri-state template of the box (screen coordinates, frame captured at 1/`scale`), taken
    /// while HP shows "100%". Nil when the box has no readable text.
    static func buildSignature<F: PixelFrame>(_ frame: F, _ left: Int, _ top: Int, _ width: Int, _ height: Int,
                                              scale: Int) -> [UInt8]? {
        guard let values = boxValues(frame, left, top, width, height, scale: scale),
              let t = threshold(values) else { return nil }
        return values.map { v in
            let d = Float(v) - t
            return abs(d) <= edgeMargin ? cellEdge : (d > 0 ? cellText : cellDark)
        }
    }

    /// How well the box still shows the calibrated "100%": 1 = exactly, 0 = no readable text,
    /// −1 = the template doesn't fit this capture (recalibrate).
    static func match<F: PixelFrame>(_ frame: F, _ left: Int, _ top: Int, _ width: Int, _ height: Int, scale: Int,
                                     signature: [UInt8], signatureWidth: Int, signatureHeight: Int) -> Float {
        let sw = width / scale, sh = height / scale
        guard sw == signatureWidth, sh == signatureHeight, signature.count == sw * sh,
              let values = boxValues(frame, left, top, width, height, scale: scale) else { return -1 }
        guard let t = threshold(values) else { return 0 }
        var agree = 0, counted = 0
        for (i, v) in values.enumerated() where signature[i] != cellEdge {
            let d = Float(v) - t
            if abs(d) <= edgeMargin { continue } // a glyph edge in this frame
            counted += 1
            if (d > 0) == (signature[i] == cellText) { agree += 1 }
        }
        if counted < signature.count / 4 { return 0 } // nothing recognizable left in the box
        return Float(agree) / Float(counted)
    }

    /// "2:" + one digit per cell; older strings decode to nil (recalibrate once).
    static func encode(_ signature: [UInt8]) -> String {
        signaturePrefix + String(signature.map { Character(String($0)) })
    }

    static func decode(_ s: String) -> [UInt8]? {
        guard s.hasPrefix(signaturePrefix), s.count > signaturePrefix.count else { return nil }
        var out: [UInt8] = []
        for ch in s.dropFirst(signaturePrefix.count) {
            guard let v = ch.wholeNumberValue, (0...2).contains(v) else { return nil }
            out.append(UInt8(v))
        }
        return out
    }
}
