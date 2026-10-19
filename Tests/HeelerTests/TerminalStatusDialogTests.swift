import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The dialog's whole job is to be legible over a live terminal. Its first
/// version was a bare `ContentUnavailableView`, which draws no background at
/// all, so the copy sat directly on top of whatever glyphs happened to be
/// underneath. That is invisible to every kind of test except one that looks
/// at the pixels, so this suite looks at the pixels.
@MainActor
@Suite("Terminal status dialog")
struct TerminalStatusDialogTests {
    @Test func theDialogCoversWhateverTheTerminalWasShowing() async throws {
        let image = try await Self.render(
            TerminalStatusDialog(
                glyph: .symbol("cable.connector.slash"),
                title: "Session Ended",
                message: "The session ended."
            ) {
                Button("Reattach") {}
                    .buttonStyle(.borderedProminent)
            })

        let behind = try #require(Self.color(in: image, atUnit: CGPoint(x: 0.5, y: 0.5)))
        #expect(behind != Self.backdrop, "the dialog let the terminal through")
    }

    @Test func theDimOnlyAppliesWhereItIsAskedFor() async throws {
        // A corner is outside the card but inside the scrim.
        let corner = CGPoint(x: 0.03, y: 0.06)

        let dimmed = try await Self.render(
            TerminalStatusDialog(
                glyph: .symbol("cable.connector.slash"), title: "Session Ended"))
        let undimmed = try await Self.render(
            TerminalStatusDialog(glyph: .progress, title: "Connecting…", dimsBackground: false))

        #expect(try #require(Self.color(in: dimmed, atUnit: corner)) != Self.backdrop)
        // Transient states leave the terminal alone; dimming on every reconnect
        // would flash the screen.
        #expect(try #require(Self.color(in: undimmed, atUnit: corner)) == Self.backdrop)
    }

    @Test func theCardWearsTheTerminalThemeRatherThanTheSystem() async throws {
        // The theme owns the whole screen; a system material card over a
        // Solarized grid reads as a piece of some other app.
        let palette = TerminalThemeOption.solarized.palette(for: .dark)
        let image = try await Self.render(
            TerminalStatusDialog(
                glyph: .symbol("cable.connector.slash"), title: "Session Ended",
                palette: palette, dimsBackground: false))

        // Inside the card, clear of the centred glyph and copy.
        let inside = try #require(Self.color(in: image, atUnit: CGPoint(x: 0.15, y: 0.5)))
        let expected = Self.packed(palette.background.mix(with: palette.foreground, by: 0.08))
        #expect(
            Self.channelDistance(inside, expected) <= 8,
            "card drew \(String(inside, radix: 16)), expected ~\(String(expected, radix: 16))")
    }

    @Test func aLoaderDrawsNoCard() async throws {
        // Loading waits on nothing from the reader: a spinner and a line, with
        // the terminal's ground showing all around them.
        let image = try await Self.render(
            TerminalStatusDialog(glyph: .progress, title: "Connecting…", dimsBackground: false))
        #expect(try #require(Self.color(in: image, atUnit: CGPoint(x: 0.15, y: 0.5))) == Self.backdrop)
    }

    @Test func thePrimaryButtonIsFilledWithTheThemeForegroundNotItsAccent() async throws {
        // Vesper's ANSI blue is a light lavender; the system's white label on
        // it was barely legible. The fill is now the theme foreground.
        let palette = TerminalThemeOption.vesper.palette(for: .dark)
        let image = try await Self.render(
            TerminalStatusDialog(
                glyph: .symbol("exclamationmark.triangle"),
                title: "Couldn't Open Terminal",
                palette: palette,
                dimsBackground: false
            ) {
                Button("Try Again") {}
                    .buttonStyle(.terminalStatusPrimary)
            })

        // Only the button fill is a wide solid run; title glyphs are not.
        let width = try #require(image.cgImage?.width)
        let foregroundRun = try #require(
            Self.longestRun(of: Self.packed(palette.foreground), in: image))
        let accentRun = try #require(Self.longestRun(of: Self.packed(palette.accent), in: image))
        #expect(foregroundRun > width / 5, "no foreground-filled button (longest run \(foregroundRun)px)")
        #expect(accentRun < width / 20, "the accent still fills something (run \(accentRun)px)")
    }

    /// Pure red, so anything drawn over it is unmistakable.
    private static let backdrop: UInt32 = 0xFF00_0000 >> 8

    private static func packed(_ color: Color) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].reduce(0) { packed, channel in
            packed << 8 | UInt32((channel * 255).rounded())
        }
    }

    private static func channelDistance(_ lhs: UInt32, _ rhs: UInt32) -> Int {
        (0..<3).reduce(0) { worst, shift in
            let left = Int((lhs >> (shift * 8)) & 0xFF)
            let right = Int((rhs >> (shift * 8)) & 0xFF)
            return max(worst, abs(left - right))
        }
    }

    private static func render(_ dialog: some View) async throws -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIHostingController(
            rootView: ZStack {
                Color(red: 1, green: 0, blue: 0).ignoresSafeArea()
                dialog
            })
        controller.view.frame = bounds

        let window = try await makeTestWindow(
            frame: bounds,
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    private static func color(in image: UIImage, atUnit point: CGPoint) -> UInt32? {
        guard let (pixels, width, height) = rgb(of: image) else { return nil }
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        return pixels[y * width + x]
    }

    /// The longest horizontal run of pixels within a few levels of `color`.
    private static func longestRun(of color: UInt32, in image: UIImage) -> Int? {
        guard let (pixels, width, height) = rgb(of: image) else { return nil }
        var longest = 0
        for y in 0..<height {
            var run = 0
            for x in 0..<width {
                run = channelDistance(pixels[y * width + x], color) <= 8 ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return longest
    }

    private static func rgb(of image: UIImage) -> ([UInt32], Int, Int)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = (0..<(width * height)).map { p in
            let i = p * 4
            return UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
        }
        return (pixels, width, height)
    }
}
