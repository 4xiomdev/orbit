//
//  OrbitMark.swift
//  Orbit
//
//  Shared Orbit mark geometry used across the menu bar icon, overlay cursor,
//  HUD accents, and small branded UI moments.
//

import AppKit
import CoreGraphics
import SwiftUI

enum OrbitBranding {
    static let defaultMarkRotationDegrees: CGFloat = 0
    static let defaultMarkHeadingDegrees: CGFloat = -135
    static let menuBarVerticalFlip = true
    static let normalizedMarkPoints: [CGPoint] = [
        CGPoint(x: 0.214, y: 0.929),
        CGPoint(x: 0.429, y: 1.000),
        CGPoint(x: 0.000, y: 0.000),
        CGPoint(x: 1.000, y: 0.429),
        CGPoint(x: 0.929, y: 0.214),
        CGPoint(x: 0.429, y: 0.429)
    ]

    static func markPath(
        in rect: CGRect,
        rotationDegrees: CGFloat = defaultMarkRotationDegrees
    ) -> CGPath {
        let path = CGMutablePath()

        // Exact mathematically rotated Orbit cursor geometry from the locked
        // browser preview. The self-intersection is intentional and must use
        // even-odd filling to preserve the center notch.
        let resolved = normalizedMarkPoints.map { point in
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

    static func markPerimeter(in size: CGSize) -> CGFloat {
        let scaledPoints = normalizedMarkPoints.map { point in
            CGPoint(x: point.x * size.width, y: point.y * size.height)
        }

        guard scaledPoints.count > 1 else { return 0 }

        var length: CGFloat = 0
        for index in scaledPoints.indices {
            let start = scaledPoints[index]
            let end = scaledPoints[(index + 1) % scaledPoints.count]
            length += hypot(end.x - start.x, end.y - start.y)
        }
        return length
    }

    static func makeTemplateMenuBarIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let insetRect = CGRect(x: 1.75, y: 1.75, width: size - 3.5, height: size - 3.5)
        context.setFillColor(NSColor.black.cgColor)
        let basePath = markPath(in: insetRect)
        if menuBarVerticalFlip {
            var transform = CGAffineTransform.identity
                .translatedBy(x: 0, y: insetRect.midY * 2)
                .scaledBy(x: 1, y: -1)
            context.addPath(basePath.copy(using: &transform) ?? basePath)
        } else {
            context.addPath(basePath)
        }
        context.drawPath(using: .eoFill)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

struct OrbitMarkShape: Shape {
    var rotationDegrees: CGFloat = OrbitBranding.defaultMarkRotationDegrees

    func path(in rect: CGRect) -> Path {
        Path(OrbitBranding.markPath(in: rect, rotationDegrees: rotationDegrees))
    }
}

struct OrbitMarkView: View {
    var size: CGFloat = 20
    var rotationDegrees: CGFloat = OrbitBranding.defaultMarkRotationDegrees
    var fillColor: Color = Color.black.opacity(0.82)
    var strokeColor: Color = Color.white.opacity(0.96)
    var lineWidth: CGFloat = 1.2

    var body: some View {
        OrbitMarkShape(rotationDegrees: rotationDegrees)
            .fill(fillColor, style: FillStyle(eoFill: true, antialiased: true))
            .overlay(
                OrbitMarkShape(rotationDegrees: rotationDegrees)
                    .stroke(strokeColor, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            )
            .frame(width: size, height: size)
            .shadow(color: Color.black.opacity(0.25), radius: size * 0.06, x: 0, y: size * 0.02)
    }
}
