#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

struct OrbitBrandAssetGenerator {
    let projectRoot: URL

    private var appIconSetURL: URL {
        projectRoot
            .appendingPathComponent("Orbit")
            .appendingPathComponent("Assets.xcassets")
            .appendingPathComponent("AppIcon.appiconset")
    }

    private var dmgBackgroundURL: URL {
        projectRoot.appendingPathComponent("dmg-background.png")
    }

    private let iconSizes = [16, 32, 64, 128, 256, 512, 1024]
    private let appIconMarkRotationDegrees: CGFloat = -90

    func run() throws {
        try FileManager.default.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)

        for size in iconSizes {
            let image = makeIcon(size: size)
            let destination = appIconSetURL.appendingPathComponent("\(size)-mac.png")
            try writePNG(image: image, to: destination)
        }

        let dmgBackground = makeDMGBackground(size: NSSize(width: 660, height: 400))
        try writePNG(image: dmgBackground, to: dmgBackgroundURL)
    }

    private func makeIcon(size: Int) -> NSImage {
        renderImage(pixelSize: NSSize(width: size, height: size)) { context, rect in
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.interpolationQuality = .high

            let radius = CGFloat(size) * 0.22
            let inset = CGFloat(size) * 0.015
            let backgroundRect = rect.insetBy(dx: inset, dy: inset)
            let borderRect = backgroundRect.insetBy(dx: CGFloat(size) * 0.012, dy: CGFloat(size) * 0.012)
            let backgroundPath = CGPath(
                roundedRect: backgroundRect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            let borderPath = CGPath(
                roundedRect: borderRect,
                cornerWidth: radius * 0.94,
                cornerHeight: radius * 0.94,
                transform: nil
            )

            context.saveGState()
            context.addPath(backgroundPath)
            context.clip()
            drawRadialBackground(in: backgroundRect, context: context)
            context.restoreGState()

            context.addPath(borderPath)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
            context.setLineWidth(max(1, CGFloat(size) * 0.015))
            context.strokePath()

            let markSize = CGFloat(size) * 0.58
            let markRect = CGRect(
                x: (CGFloat(size) - markSize) / 2,
                y: (CGFloat(size) - markSize) / 2,
                width: markSize,
                height: markSize
            )
            let markPath = orbitMarkPath(in: markRect, rotationDegrees: appIconMarkRotationDegrees)

            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -CGFloat(size) * 0.018),
                blur: CGFloat(size) * 0.05,
                color: NSColor.black.withAlphaComponent(0.32).cgColor
            )
            context.addPath(markPath)
            context.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
            context.drawPath(using: .eoFill)
            context.restoreGState()

            context.addPath(markPath)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.98).cgColor)
            context.setLineWidth(max(1.1, CGFloat(size) * 0.012))
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    private func makeDMGBackground(size: NSSize) -> NSImage {
        // create-dmg places Orbit.app at (160, 195) and /Applications at (500, 195)
        // in Finder window coordinates (y from top). CG coordinates flip y:
        // iconCenterCG.y = windowHeight(400) - finderY(195) = 205
        let iconCenter  = CGPoint(x: 160, y: 205)
        let appsCenter  = CGPoint(x: 500, y: 205)
        let midX        = (iconCenter.x + appsCenter.x) / 2   // 330

        return renderImage(pixelSize: size) { context, rect in

            // ── 1. Background: deep charcoal, slightly lighter at top ──────
            let bgGrad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.11, alpha: 1).cgColor,
                    NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.04, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 1]
            )!
            context.drawLinearGradient(bgGrad,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end:   CGPoint(x: rect.midX, y: rect.minY),
                options: [])

            // ── 2. OrbitMark watermark — ambient, barely visible ───────────
            let wmSize: CGFloat = 200
            let wmRect = CGRect(
                x: rect.midX - wmSize / 2,
                y: rect.midY - wmSize / 2,
                width: wmSize, height: wmSize)
            let wmPath = orbitMarkPath(in: wmRect, rotationDegrees: -45)
            context.addPath(wmPath)
            context.setFillColor(NSColor.white.withAlphaComponent(0.015).cgColor)
            context.drawPath(using: .eoFill)
            context.addPath(wmPath)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.025).cgColor)
            context.setLineWidth(1.0)
            context.setLineJoin(.round)
            context.strokePath()

            // ── 3. Spotlight behind app icon ───────────────────────────────
            let spotGrad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    NSColor.white.withAlphaComponent(0.09).cgColor,
                    NSColor.clear.cgColor
                ] as CFArray,
                locations: [0, 1]
            )!
            context.drawRadialGradient(spotGrad,
                startCenter: iconCenter, startRadius: 0,
                endCenter:   iconCenter, endRadius: 175,
                options: .drawsAfterEndLocation)

            // ── 4. Sonar rings (echo of OrbitIdleCursor breathing aura) ────
            context.setLineWidth(0.75)
            for (radius, alpha) in [(CGFloat(88), 0.10), (CGFloat(116), 0.055)] {
                context.beginPath()
                context.addArc(center: iconCenter, radius: radius,
                               startAngle: 0, endAngle: .pi * 2, clockwise: false)
                context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
                context.strokePath()
            }

            // ── 5. Arrow (icon → Applications) ────────────────────────────
            let arrowStartX: CGFloat = iconCenter.x + 100
            let arrowEndX:   CGFloat = appsCenter.x - 72
            let arrowY = iconCenter.y
            let headLen: CGFloat = 16
            let headAngle: CGFloat = .pi / 5.5

            context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            context.move(to: CGPoint(x: arrowStartX, y: arrowY))
            context.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
            context.strokePath()

            context.move(to: CGPoint(x: arrowEndX - headLen * cos(headAngle),
                                     y: arrowY  + headLen * sin(headAngle)))
            context.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
            context.addLine(to: CGPoint(x: arrowEndX - headLen * cos(headAngle),
                                        y: arrowY  - headLen * sin(headAngle)))
            context.strokePath()

            // ── 6. Typography ──────────────────────────────────────────────
            let instrAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.50),
            ]
            let instr = NSAttributedString(string: "Drag Orbit to Applications", attributes: instrAttrs)
            let instrW = instr.size().width
            instr.draw(at: CGPoint(x: midX - instrW / 2, y: 148))

            let tagAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.18),
                .kern: 1.8,
            ]
            let tag = NSAttributedString(string: "ORBIT  ·  MACOS", attributes: tagAttrs)
            let tagW = tag.size().width
            tag.draw(at: CGPoint(x: midX - tagW / 2, y: 128))
        }
    }

    private func drawRadialBackground(in rect: CGRect, context: CGContext) {
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.06, alpha: 1).cgColor
            ] as CFArray,
            locations: [0, 1]
        )!

        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.08),
            startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.midY),
            endRadius: rect.width * 0.62,
            options: .drawsAfterEndLocation
        )
    }

    private func orbitMarkPath(in rect: CGRect, rotationDegrees: CGFloat = 0) -> CGPath {
        let normalizedPoints = [
            CGPoint(x: 0.214, y: 0.929),
            CGPoint(x: 0.429, y: 1.000),
            CGPoint(x: 0.000, y: 0.000),
            CGPoint(x: 1.000, y: 0.429),
            CGPoint(x: 0.929, y: 0.214),
            CGPoint(x: 0.429, y: 0.429)
        ]

        let path = CGMutablePath()
        let resolved = normalizedPoints.map { point in
            CGPoint(
                x: rect.minX + rect.width * point.x,
                y: rect.minY + rect.height * point.y
            )
        }
        path.addLines(between: resolved)
        path.closeSubpath()

        guard rotationDegrees != 0 else { return path }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radians = rotationDegrees * (.pi / 180)
        var transform = CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)

        return path.copy(using: &transform) ?? path
    }

    private func writePNG(image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "OrbitBrandAssetGenerator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode PNG for \(url.lastPathComponent)"
            ])
        }

        try pngData.write(to: url, options: .atomic)
    }

    private func renderImage(pixelSize: NSSize, draw: (CGContext, CGRect) -> Void) -> NSImage {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            return NSImage(size: pixelSize)
        }

        bitmap.size = pixelSize

        NSGraphicsContext.saveGraphicsState()
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: pixelSize)
            image.addRepresentation(bitmap)
            return image
        }

        NSGraphicsContext.current = graphicsContext
        let rect = CGRect(origin: .zero, size: pixelSize)
        draw(graphicsContext.cgContext, rect)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pixelSize)
        image.addRepresentation(bitmap)
        return image
    }
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath)
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
try OrbitBrandAssetGenerator(projectRoot: projectRoot).run()
