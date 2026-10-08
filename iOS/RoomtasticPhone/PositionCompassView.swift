// SPDX-License-Identifier: MIT
import SwiftUI
import RoomtasticShared

struct PositionCompassView: View {
    let grid: MeasurementGrid?
    let pointIndex: Int
    let microphonePosition: Point3?

    static func pointName(_ index: Int) -> String {
        guard let offset = MeasurementGrid.localOffset(pointIndex: index) else { return "Position" }
        if offset.x == 0 && offset.z == 0 { return "Center" }
        let depth = offset.z < 0 ? "Forward" : offset.z > 0 ? "Back" : ""
        let side = offset.x < 0 ? "Left" : offset.x > 0 ? "Right" : ""
        return [depth, side].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var target: Point3? { MeasurementGrid.localOffset(pointIndex: pointIndex) }
    private var microphone: Point3? {
        guard let grid, let microphonePosition else { return nil }
        let local = grid.localPosition(worldPosition: microphonePosition)
        guard local.x.isFinite, local.y.isFinite, local.z.isFinite else { return nil }
        return local
    }
    private func fitsDiagram(_ position: Point3) -> Bool {
        let projectedHeight = 91 + position.z / 0.27 * 60 - position.y * 230
        return abs(position.x) <= 0.24 && abs(position.z) <= 0.27 && abs(position.y) <= 0.12
            && (38...168).contains(projectedHeight)
    }
    private var instruction: String {
        guard let target else { return "All positions are relative to the original Center." }
        if target.x == 0 && target.z == 0 {
            return grid == nil ? "Hold the bottom microphone at ear height. This capture fixes Center." : "Return the bottom microphone to the original Center."
        }
        var directions: [String] = []
        if target.z != 0 { directions.append("\(centimeters(target.z)) cm \(target.z < 0 ? "forward" : "back")") }
        if target.x != 0 { directions.append("\(centimeters(target.x)) cm \(target.x < 0 ? "left" : "right")") }
        return directions.joined(separator: " + ") + " of Center."
    }
    private func centimeters(_ value: Double) -> String {
        (abs(value) * 100).formatted(.number.precision(.fractionLength(0)))
    }
    private var microphoneDescription: String {
        guard grid != nil else { return "Target map only · Center is set by the first capture." }
        guard let microphone else { return "Microphone position unavailable · follow the target map." }
        guard let target else { return "Microphone position is approximate." }
        let distance = sqrt(pow(target.x - microphone.x, 2) + pow(target.y - microphone.y, 2) + pow(target.z - microphone.z, 2))
        let prefix = fitsDiagram(microphone) ? "Approx. \(centimeters(distance)) cm to target" : "Microphone outside diagram · approx. \(centimeters(distance)) cm to target"
        if abs(microphone.y) > 0.03 {
            return prefix + " · \(centimeters(microphone.y)) cm \(microphone.y > 0 ? "above" : "below") Center height."
        }
        return prefix + " · keep the bottom microphone at Center’s ear height."
    }
    private var accessibleMicrophonePosition: String {
        guard let microphone else { return "" }
        return "Microphone approximately \(centimeters(microphone.x)) centimeters \(microphone.x < 0 ? "left" : "right"), \(centimeters(microphone.z)) centimeters \(microphone.z < 0 ? "forward" : "back"), and \(centimeters(microphone.y)) centimeters \(microphone.y < 0 ? "below" : "above") the original Center."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FROM CENTER · NOT THE LAST POSITION")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(instruction).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Canvas { context, size in
                drawCompass(context: &context, size: size)
            }
            .frame(height: 205)
            .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend }
                VStack(alignment: .leading, spacing: 6) { legend }
            }
            .font(.caption)
            Label(microphoneDescription, systemImage: grid != nil && microphone == nil ? "viewfinder" : "ear")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibleMicrophonePosition)
    }

    @ViewBuilder private var legend: some View {
        Label("Target", systemImage: "circle.inset.filled").foregroundStyle(Color.accentColor)
        if microphone != nil {
            Label("Mic · approximate", systemImage: "scope").foregroundStyle(Color.orange)
        }
    }

    private func drawCompass(context: inout GraphicsContext, size: CGSize) {
        let origin = CGPoint(x: size.width / 2, y: 91)
        // A shallow perspective plane at the original microphone height, with a lower shadow plane.
        func project(_ position: Point3) -> CGPoint {
            let perspective = 1 + position.z * 0.5
            return CGPoint(x: origin.x + CGFloat(position.x / 0.27 * perspective) * size.width * 0.31,
                           y: origin.y + CGFloat(position.z / 0.27) * 60 - CGFloat(position.y) * 230)
        }
        func line(_ start: CGPoint, _ end: CGPoint) -> Path {
            Path { path in path.move(to: start); path.addLine(to: end) }
        }
        func circle(_ center: CGPoint, radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        let corners = [Point3(x: -0.27, y: 0, z: -0.27), Point3(x: 0.27, y: 0, z: -0.27),
                       Point3(x: 0.27, y: 0, z: 0.27), Point3(x: -0.27, y: 0, z: 0.27)]
        let plane = Path { path in
            path.addLines(corners.map(project))
            path.closeSubpath()
        }
        let shadow = plane.applying(CGAffineTransform(translationX: 0, y: 30))
        context.fill(shadow, with: .color(.secondary.opacity(0.05)))
        context.stroke(shadow, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
        for corner in corners {
            let point = project(corner)
            context.stroke(line(point, CGPoint(x: point.x, y: point.y + 30)), with: .color(.secondary.opacity(0.15)), lineWidth: 1)
        }
        context.fill(plane, with: .color(Color(uiColor: .secondarySystemGroupedBackground)))
        context.stroke(plane, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
        context.stroke(line(origin, CGPoint(x: origin.x, y: origin.y + 30)), with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        for endpoints in [(Point3(x: -0.27, y: 0, z: 0), Point3(x: 0.27, y: 0, z: 0)),
                          (Point3(x: 0, y: 0, z: -0.27), Point3(x: 0, y: 0, z: 0.27))] {
            context.stroke(line(project(endpoints.0), project(endpoints.1)), with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        }
        if let target {
            let point = project(target)
            context.stroke(line(origin, point), with: .color(.accentColor.opacity(0.6)), lineWidth: 2)
            context.fill(circle(point, radius: 15), with: .color(.accentColor.opacity(0.12)))
            context.stroke(circle(point, radius: 12), with: .color(.accentColor), lineWidth: 2)
        }
        for index in 0..<9 {
            guard let offset = MeasurementGrid.localOffset(pointIndex: index) else { continue }
            let point = project(offset)
            context.fill(circle(point, radius: index == pointIndex ? 5 : 3.5),
                         with: .color(index == pointIndex ? .accentColor : .secondary.opacity(0.6)))
        }
        if let microphone, fitsDiagram(microphone) {
            let point = project(microphone)
            if let target {
                context.stroke(line(point, project(target)), with: .color(.orange.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            if abs(microphone.y) > 0.015 {
                let foot = project(Point3(x: microphone.x, y: 0, z: microphone.z))
                context.stroke(line(foot, point), with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                context.stroke(circle(foot, radius: 3), with: .color(.orange.opacity(0.6)), lineWidth: 1)
            }
            context.stroke(circle(point, radius: 8), with: .color(.orange), lineWidth: 2)
            context.stroke(line(CGPoint(x: point.x - 11, y: point.y), CGPoint(x: point.x + 11, y: point.y)), with: .color(.orange), lineWidth: 1)
            context.stroke(line(CGPoint(x: point.x, y: point.y - 11), CGPoint(x: point.x, y: point.y + 11)), with: .color(.orange), lineWidth: 1)
        }
        // Center is always labeled, including when the microphone sits over it.
        context.fill(circle(origin, radius: 3), with: .color(.primary))
        let centerLabel = CGRect(x: origin.x - 24, y: origin.y + 9, width: 48, height: 17)
        context.fill(Path(roundedRect: centerLabel, cornerRadius: 4), with: .color(Color(uiColor: .secondarySystemGroupedBackground)))
        context.draw(Text("Center").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary), at: CGPoint(x: origin.x, y: centerLabel.midY))
        context.draw(Text("Forward").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary), at: CGPoint(x: origin.x, y: 20))
        context.draw(Text("Back").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary), at: CGPoint(x: origin.x, y: 193))
        context.draw(Text("Left").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary), at: CGPoint(x: 0, y: origin.y), anchor: .leading)
        context.draw(Text("Right").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary), at: CGPoint(x: size.width, y: origin.y), anchor: .trailing)
    }
}
