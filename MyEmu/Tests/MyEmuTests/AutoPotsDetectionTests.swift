import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MyEmu

// Ports of autopotsCO's HpDetectorTest and SimpleHpTest: same screenshots, same expected ranges.

/// Pixels in an array (decoded screenshots and synthetic frames).
private struct ArrayFrame: PixelFrame {
    let width: Int
    let height: Int
    let px: [Int]
    func rgb(_ x: Int, _ y: Int) -> Int { px[y * width + x] }
}

private func load(_ name: String) throws -> ArrayFrame {
    let url = try #require(Bundle.module.url(forResource: "Resources/autopots/\(name)", withExtension: nil))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let context = try #require(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = (0..<(w * h)).map { Int(bytes[$0 * 4]) << 16 | Int(bytes[$0 * 4 + 1]) << 8 | Int(bytes[$0 * 4 + 2]) }
    return ArrayFrame(width: w, height: h, px: px)
}

/// 2×2-averaged half-scale view (the downscaled capture AutoPots reads).
private func half(_ src: ArrayFrame) -> ArrayFrame {
    let w = src.width / 2, h = src.height / 2
    var px = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            var r = 0, g = 0, b = 0
            for dy in 0...1 {
                for dx in 0...1 {
                    let c = src.rgb(x * 2 + dx, y * 2 + dy)
                    r += (c >> 16) & 0xFF; g += (c >> 8) & 0xFF; b += c & 0xFF
                }
            }
            px[y * w + x] = (r / 4) << 16 | (g / 4) << 8 | (b / 4)
        }
    }
    return ArrayFrame(width: w, height: h, px: px)
}

/// Red and blue swapped (a BGRA capture read as RGBA).
private func swapped(_ src: ArrayFrame) -> ArrayFrame {
    ArrayFrame(width: src.width, height: src.height,
               px: src.px.map { ($0 & 0xFF) << 16 | ($0 & 0xFF00) | (($0 >> 16) & 0xFF) })
}

private let orbShots = ["full_exp.png", "full_no_exp.png", "reduced_exp.png", "reduced_no_exp.png"]

@Test func orbDefaultBoxSeparatesFullFromReducedHP() throws {
    // The default box: centre (609, 645), 44×92.
    func hp(_ name: String) throws -> Float { HpDetector.hpFractionArc(try load(name), 609 - 22, 645 - 46, 44, 92) }
    let fulls = [try hp("full_no_exp.png"), try hp("full_exp.png")]
    let reduced = [try hp("reduced_no_exp.png"), try hp("reduced_exp.png")]
    for f in fulls { #expect(f >= 0.90, "full HP read \(f)") }
    for r in reduced { #expect(r < 0.90, "reduced HP read \(r)") }
    #expect(fulls.min()! - reduced.max()! > 0.05)
}

@Test(arguments: orbShots)
func autoMapFindsTheOrbAndItsPotion(name: String) throws {
    let frame = try load(name)
    let box = try #require(HpDetector.autoMapOrb(frame), "\(name): orb must be found")
    // Measured red half x588…631, y599…691; the top must be at or above 599.
    #expect((583...593).contains(box[0]), "left \(box[0])")
    #expect((580...599).contains(box[1]), "top \(box[1])")
    #expect((38...50).contains(box[2]), "width \(box[2])")
    #expect((688...702).contains(box[1] + box[3]), "bottom \(box[1] + box[3])")
    let f = HpDetector.hpFractionArc(frame, box[0], box[1], box[2], box[3])
    if name.hasPrefix("full") { #expect(f >= 0.95, "full read \(f)") } else { #expect(f < 0.90, "reduced read \(f)") }
    // The derived potion point lands on the bottle (x542…565, y625…683).
    let px = Float(box[0]) + HpDetector.potionXPerWidth * Float(box[2])
    let py = Float(box[1]) + HpDetector.potionYPerHeight * Float(box[3])
    #expect((542...566).contains(px) && (630...685).contains(py), "potion (\(px), \(py))")
}

@Test func autoMapFindsNoOrbInSimpleView() throws {
    #expect(HpDetector.autoMapOrb(try load("simple_view.png")) == nil)
    // Its red-brown temple woodwork forms a plausible red run; only the blue-half check rejects it.
    #expect(HpDetector.autoMapOrb(try load("simple_poco.jpg")) == nil)
}

@Test func autoMapFindsTheOrbOnAWideScreenAndAtHalfScale() throws {
    let wide = try load("poco_wide.jpg") // 20:9
    let box = try #require(HpDetector.autoMapOrb(wide))
    #expect((1113...1133).contains(box[0]) && (55...75).contains(box[2]), "box \(box)")
    #expect(HpDetector.hpFractionArc(wide, box[0], box[1], box[2], box[3]) >= 0.9)

    let halfFrame = half(wide)
    let halfBox = try #require(HpDetector.autoMapOrb(halfFrame), "orb at half scale")
    #expect((555...567).contains(halfBox[0]) && (27...38).contains(halfBox[2]), "half box \(halfBox)")
    #expect(HpDetector.hpFractionArc(halfFrame, halfBox[0], halfBox[1], halfBox[2], halfBox[3]) >= 0.97)
    #expect(HpDetector.autoMapOrb(half(try load("simple_poco.jpg"))) == nil)
}

/// The fast path reads HP inside every frame callback, so it has to stay far below a frame's time.
@Test func perFrameHPReadIsFarUnderAFrame() throws {
    let halfFrame = half(try load("reduced_exp.png"))
    var settings = AutoPotsSettings()
    settings.orbBox = PixelRect(x: 587, y: 599, width: 44, height: 92) // screen px; read at half scale
    settings.orbPotion = PixelPoint(x: 553, y: 668)
    let runs = 2000
    let start = ContinuousClock.now
    var value: Float?
    for _ in 0..<runs { value = AutoPotsRunner.read(halfFrame, settings, scale: 2) }
    let perRead = (ContinuousClock.now - start) / runs
    print("AutoPots orb read at half scale: \(perRead) per frame, value \(value ?? -1)")
    #expect(try #require(value) < AutoPotsRules.triggerLevel) // reduced HP still detected at half scale
    #expect(perRead < .milliseconds(1), "a 180 Hz frame is 5.6 ms")
}

@Test func swappedColorChannelsFindNoOrb() throws {
    let frame = try load("poco_wide.jpg")
    #expect(HpDetector.autoMapOrb(swapped(frame)) == nil)
    #expect(HpDetector.autoMapOrb(swapped(swapped(frame))) != nil)
}

@Test func hpRednessRejectsAMisplacedBox() throws {
    for name in ["full_exp.png", "full_no_exp.png", "poco_wide.jpg"] {
        let img = try load(name)
        let b = try #require(HpDetector.autoMapOrb(img))
        #expect(HpDetector.hpRedFraction(img, b[0], b[1], b[2], b[3]) >= 0.6, "\(name) on the orb")
        #expect(HpDetector.hpRedFraction(img, b[0] + Int(1.4 * Float(b[2])), b[1], b[2], b[3]) < 0.3, "\(name) on blue")
        #expect(HpDetector.hpRedFraction(img, b[0], b[1] - b[3], b[2], b[3]) < 0.3, "\(name) above")
        #expect(HpDetector.hpRedFraction(img, b[0] - Int(1.2 * Float(b[2])), b[1], b[2], b[3]) < 0.3, "\(name) on potion")
    }
}

@Test func drainedPixelClassification() {
    #expect(HpDetector.isEmpty(0x202020))   // dark neutral: drained
    #expect(HpDetector.isEmpty(0x686A6B))   // mid grey: drained
    #expect(!HpDetector.isEmpty(0xC83020))  // bright red: HP
    #expect(!HpDetector.isEmpty(0x802C2C))  // dark red: HP
    #expect(!HpDetector.isEmpty(0xFFF9D9))  // highlight
}

@Test func simpleViewAutoMapFindsDigitsAndPotion() throws {
    let res = SimpleHp.autoMap(try load("simple_view.png"))
    #expect(!res.fromFallback)
    #expect((85...95).contains(res.left) && (3...9).contains(res.top) && (12...20).contains(res.height), "box \(res)")
    #expect(res.left + res.width >= 139, "box must cover the % ending at 139")
    #expect((125...155).contains(res.potionX) && (65...100).contains(res.potionY), "potion \(res)")

    let wide = SimpleHp.autoMap(try load("simple_poco.jpg"))
    #expect(!wide.fromFallback)
    #expect((132...145).contains(wide.left) && (5...12).contains(wide.top) && (18...28).contains(wide.height), "box \(wide)")
    #expect((50...85).contains(wide.potionX) && (105...145).contains(wide.potionY), "potion \(wide)")
    #expect(wide.potionFound)
}

@Test func simpleViewTemplateMatchesFullHPAndBreaksOnChange() throws {
    let frame = try load("simple_view.png")
    let res = SimpleHp.autoMap(frame)
    let sig = try #require(SimpleHp.buildSignature(frame, res.left, res.top, res.width, res.height, scale: 1))
    func match(_ f: some PixelFrame, dx: Int = 0) -> Float {
        SimpleHp.match(f, res.left + dx, res.top, res.width, res.height, scale: 1,
                       signature: sig, signatureWidth: res.width, signatureHeight: res.height)
    }
    #expect(match(frame) >= 0.99)
    #expect(match(frame, dx: 8) < 0.90) // different glyphs under the box
    // A dimmer scene still reads full HP; the template adapts to brightness.
    for factor in [0.85, 0.7] {
        let dim = ArrayFrame(width: frame.width, height: frame.height, px: frame.px.map { c in
            Int(Double((c >> 16) & 0xFF) * factor) << 16 | Int(Double((c >> 8) & 0xFF) * factor) << 8 | Int(Double(c & 0xFF) * factor)
        })
        #expect(match(dim) >= 0.97, "full HP at brightness ×\(factor)")
    }
    // No text in the box at all: unreadable (0).
    #expect(SimpleHp.match(frame, 150, res.top, res.width, res.height, scale: 1,
                           signature: sig, signatureWidth: res.width, signatureHeight: res.height) == 0)
    #expect(SimpleHp.decode(SimpleHp.encode(sig)) == sig)
    #expect(SimpleHp.decode("0101") == nil) // pre-adaptive strings recalibrate
}
