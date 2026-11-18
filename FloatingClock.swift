// FloatingClock.swift
// Analog always-on-top clock for macOS 12+ (native on Apple silicon and Intel).
//
// Build:   swiftc -O FloatingClock.swift -o FloatingClock
// Run:     ./FloatingClock
//
// Universal binary:
//   swiftc -O -target arm64-apple-macos12   FloatingClock.swift -o clock-arm64
//   swiftc -O -target x86_64-apple-macos12  FloatingClock.swift -o clock-x86
//   lipo -create clock-arm64 clock-x86 -output FloatingClock

import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Stored colors

/// An sRGB color that can live in UserDefaults (via @AppStorage) as "r,g,b".
struct StoredColor: RawRepresentable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        self.init(red: Double(ns.redComponent),
                  green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent))
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        self.init(red: parts[0], green: parts[1], blue: parts[2])
    }

    var rawValue: String { "\(red),\(green),\(blue)" }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    static let white = StoredColor(red: 1, green: 1, blue: 1)
    static let black = StoredColor(red: 0, green: 0, blue: 0)
    static let red = StoredColor(red: 0.9, green: 0.1, blue: 0.1)
}

// MARK: - Face image cache

/// Loads the chosen face image once instead of on every redraw.
enum FaceImageCache {
    private static var cachedPath: String?
    private static var cachedImage: NSImage?

    static func image(for path: String) -> NSImage? {
        if path != cachedPath {
            cachedPath = path
            cachedImage = NSImage(contentsOfFile: path)
        }
        return cachedImage
    }
}

// MARK: - Clock drawing

struct ClockFace: View {
    @AppStorage("showSeconds") private var showSeconds = true
    @AppStorage("faceColor") private var faceColor = StoredColor.white
    @AppStorage("faceOpacity") private var faceOpacity = 1.0
    @AppStorage("useFaceImage") private var useFaceImage = false
    @AppStorage("faceImagePath") private var faceImagePath = ""
    @AppStorage("handColor") private var handColor = StoredColor.black
    @AppStorage("handOpacity") private var handOpacity = 1.0
    @AppStorage("secondColor") private var secondColor = StoredColor.black
    @AppStorage("markColor") private var markColor = StoredColor.black
    @AppStorage("textColor") private var textColor = StoredColor.black
    @AppStorage("textFont") private var textFont = "rounded"
    @AppStorage("secondZone") private var secondZone = ""   // time zone identifier; "" = off
    @AppStorage("zoneColor") private var zoneColor = StoredColor.red
    @AppStorage("hourMarks") private var hourMarks = "lines"   // "lines", "dots", "numbers"
    @AppStorage("showMinuteMarks") private var showMinuteMarks = true
    @AppStorage("showBorder") private var showBorder = true
    @AppStorage("showDay") private var showDay = false
    @AppStorage("showDate") private var showDate = false
    @AppStorage("dateDayOnly") private var dateDayOnly = false
    @AppStorage("showAMPM") private var showAMPM = false
    @AppStorage("showTimeZone") private var showTimeZone = false
    @AppStorage("clockStyle") private var clockStyle = "analog"   // "analog" or "digital"
    @AppStorage("use24Hour") private var use24Hour = false
    @AppStorage("digitalBold") private var digitalBold = false
    @Environment(\.displayScale) private var displayScale

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let dayOfMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    var body: some View {
        // Redraw once per second, aligned to whole-second boundaries
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { timeline in
            Canvas { ctx, size in
                draw(&ctx, size: size, date: timeline.date)
            }
        }
    }

    private func point(_ c: CGPoint, _ angle: Double, _ length: CGFloat) -> CGPoint {
        // angle 0 = 12 o'clock, increasing clockwise
        CGPoint(x: c.x + CGFloat(sin(angle)) * length,
                y: c.y - CGFloat(cos(angle)) * length)
    }

    /// "rounded", "default", "serif" and "monospaced" are system designs;
    /// anything else is the name of an installed font family.
    private func labelFont(size: CGFloat, bold: Bool = false) -> Font {
        let weight: Font.Weight = bold ? .bold : .medium
        switch textFont {
        case "rounded":    return .system(size: size, weight: weight, design: .rounded)
        case "default":    return .system(size: size, weight: weight, design: .default)
        case "serif":      return .system(size: size, weight: weight, design: .serif)
        case "monospaced": return .system(size: size, weight: weight, design: .monospaced)
        default:
            let font = Font.custom(textFont, size: size)
            return bold ? font.bold() : font
        }
    }

    private func drawLabel(_ ctx: inout GraphicsContext, _ string: String, at pt: CGPoint,
                           side: CGFloat, color: Color, size: CGFloat? = nil) {
        let label = Text(string)
            .font(labelFont(size: size ?? side * 0.065))
            .foregroundColor(color)
        ctx.draw(label, at: pt, anchor: .center)
    }

    /// Day of week and/or date on one line, then the time zone abbreviation on another.
    private func lowerLines(for date: Date) -> [String] {
        var lines: [String] = []
        let dayDate = [showDay ? Self.dayFormatter.string(from: date).uppercased() : nil,
                       showDate ? (dateDayOnly ? Self.dayOfMonthFormatter : Self.dateFormatter)
                                    .string(from: date).uppercased() : nil]
            .compactMap { $0 }
            .joined(separator: " ")
        if !dayDate.isEmpty { lines.append(dayDate) }
        if showTimeZone {
            lines.append(TimeZone.current.abbreviation(for: date) ?? TimeZone.current.identifier)
        }
        return lines
    }

    /// "9:05", "09:05" (24-hour) and optionally ":30" seconds.
    private static func digitalString(hour: Int, minute: Int, second: Int?, use24: Bool) -> String {
        let h = use24 ? String(format: "%02d", hour)
                      : String(hour % 12 == 0 ? 12 : hour % 12)
        var result = h + String(format: ":%02d", minute)
        if let second = second { result += String(format: ":%02d", second) }
        return result
    }

    /// One hour mark in the chosen style. `label` is nil for the odd hours of a
    /// 24-hour dial in Numbers mode, which get a small dot instead.
    private func drawHourMark(_ ctx: inout GraphicsContext, c: CGPoint, r: CGFloat, side: CGFloat,
                              angle a: Double, label: String?, color: Color) {
        switch hourMarks {
        case "dots":
            let dot = side * 0.014
            let pt = point(c, a, r * 0.86)
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - dot, y: pt.y - dot,
                                            width: dot * 2, height: dot * 2)),
                     with: .color(color))
        case "numbers":
            if let label = label {
                let text = Text(label)
                    .font(.system(size: side * 0.115, weight: .semibold, design: .rounded))
                    .foregroundColor(color)
                ctx.draw(text, at: point(c, a, r * 0.76), anchor: .center)
            } else {
                let dot = side * 0.008
                let pt = point(c, a, r * 0.86)
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - dot, y: pt.y - dot,
                                                width: dot * 2, height: dot * 2)),
                         with: .color(color))
            }
        default: // "lines"
            var p = Path()
            p.move(to: point(c, a, r * 0.82))
            p.addLine(to: point(c, a, r * 0.95))
            ctx.stroke(p, with: .color(color),
                       style: StrokeStyle(lineWidth: side * 0.018, lineCap: .round))
        }
    }

    private func drawDigital(_ ctx: inout GraphicsContext, c: CGPoint, r: CGFloat, side: CGFloat, date: Date) {
        let textCol = textColor.color
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = comps.hour ?? 0

        // The time itself, centered
        let timeString = Self.digitalString(hour: hour, minute: comps.minute ?? 0,
                                            second: showSeconds ? (comps.second ?? 0) : nil,
                                            use24: use24Hour)
        let timeSize = side * (showSeconds ? 0.14 : 0.21)
        let timeText = Text(timeString)
            .font(labelFont(size: timeSize, bold: digitalBold).monospacedDigit())
            .foregroundColor(textCol)
        ctx.draw(timeText, at: CGPoint(x: c.x, y: c.y - r * 0.05), anchor: .center)

        // AM/PM above the time (12-hour only)
        if showAMPM && !use24Hour {
            drawLabel(&ctx, hour < 12 ? "AM" : "PM",
                      at: CGPoint(x: c.x, y: c.y - r * 0.45), side: side, color: textCol)
        }

        // Second time zone as a smaller line of time in the dot's color
        var zoneShown = false
        if !secondZone.isEmpty, let zone = TimeZone(identifier: secondZone) {
            var zoneCalendar = Calendar(identifier: .gregorian)
            zoneCalendar.timeZone = zone
            let zc = zoneCalendar.dateComponents([.hour, .minute], from: date)
            let zoneString = Self.digitalString(hour: zc.hour ?? 0, minute: zc.minute ?? 0,
                                                second: nil, use24: use24Hour)
            drawLabel(&ctx, zoneString, at: CGPoint(x: c.x, y: c.y + r * 0.30),
                      side: side, color: zoneColor.color, size: side * 0.08)
            zoneShown = true
        }

        // Day, date and time zone below
        for (index, line) in lowerLines(for: date).enumerated() {
            let y = c.y + r * (zoneShown ? 0.52 : 0.38) + CGFloat(index) * side * 0.085
            drawLabel(&ctx, line, at: CGPoint(x: c.x, y: y), side: side, color: textCol)
        }
    }

    /// A hand that tapers from `width` at the center to `tipWidth` at `length`.
    private func fillTaperedHand(_ ctx: inout GraphicsContext, center c: CGPoint, angle: Double,
                                 length: CGFloat, width: CGFloat, tipWidth: CGFloat, color: Color) {
        let dx = CGFloat(sin(angle))
        let dy = -CGFloat(cos(angle))
        let px = -dy          // perpendicular to the hand
        let py = dx

        let tip = CGPoint(x: c.x + dx * length, y: c.y + dy * length)
        let baseLeft  = CGPoint(x: c.x + px * width / 2, y: c.y + py * width / 2)
        let baseRight = CGPoint(x: c.x - px * width / 2, y: c.y - py * width / 2)
        let tipLeft   = CGPoint(x: tip.x + px * tipWidth / 2, y: tip.y + py * tipWidth / 2)
        let tipRight  = CGPoint(x: tip.x - px * tipWidth / 2, y: tip.y - py * tipWidth / 2)

        var p = Path()
        p.move(to: baseLeft)
        p.addLine(to: tipLeft)
        p.addLine(to: tipRight)
        p.addLine(to: baseRight)
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, date: Date) {
        let side = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let border: CGFloat = 1 / max(displayScale, 1)   // exactly one device pixel
        let r = side / 2 - border / 2 - 2

        // Face: chosen color at the chosen opacity, with an optional fully opaque black border
        let face = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        // Face: the chosen image (scaled to fill the circle) or, if none, the chosen color
        let faceImage = (useFaceImage && !faceImagePath.isEmpty)
            ? FaceImageCache.image(for: faceImagePath) : nil
        if let image = faceImage, image.size.width > 0, image.size.height > 0 {
            let scale = max(r * 2 / image.size.width, r * 2 / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            ctx.drawLayer { layer in
                layer.clip(to: face)
                layer.opacity = faceOpacity
                layer.draw(Image(nsImage: image), in: rect)
            }
        } else {
            ctx.fill(face, with: .color(faceColor.color.opacity(faceOpacity)))
        }
        if showBorder {
            ctx.stroke(face, with: .color(.black), lineWidth: border)
        }

        if clockStyle == "digital" {
            drawDigital(&ctx, c: c, r: r, side: side, date: date)
        } else {
            drawAnalog(&ctx, c: c, r: r, side: side, date: date)
        }
    }

    private func drawAnalog(_ ctx: inout GraphicsContext, c: CGPoint, r: CGFloat, side: CGFloat, date: Date) {
        let markCol = markColor.color

        // Minute ticks and hour marks (12 hour marks, or 24 on a 24-hour dial)
        for i in 0..<60 {
            let a = Double(i) / 60 * 2 * Double.pi
            if i % 5 != 0 {
                if showMinuteMarks {
                    var p = Path()
                    p.move(to: point(c, a, r * 0.90))
                    p.addLine(to: point(c, a, r * 0.95))
                    ctx.stroke(p, with: .color(markCol),
                               style: StrokeStyle(lineWidth: side * 0.006, lineCap: .round))
                }
                continue
            }

            if use24Hour { continue }   // the 24-hour marks are drawn after this loop
            let hour = i == 0 ? 12 : i / 5
            drawHourMark(&ctx, c: c, r: r, side: side, angle: a, label: "\(hour)", color: markCol)
        }

        if use24Hour {
            // 24-hour dial: midnight (24) at the top, a mark every hour, numbers every two hours
            for i in 0..<24 {
                let a = Double(i) / 24 * 2 * Double.pi
                let label: String? = (i % 2 == 0) ? "\(i == 0 ? 24 : i)" : nil
                drawHourMark(&ctx, c: c, r: r, side: side, angle: a, label: label, color: markCol)
            }
        }

        // Second time zone: a larger dot on the hour ring at that zone's hour
        // (moves continuously, like an hour hand)
        if !secondZone.isEmpty, let zone = TimeZone(identifier: secondZone) {
            var zoneCalendar = Calendar(identifier: .gregorian)
            zoneCalendar.timeZone = zone
            let zc = zoneCalendar.dateComponents([.hour, .minute], from: date)
            let zoneHour = Double(use24Hour ? (zc.hour ?? 0) : (zc.hour ?? 0) % 12) + Double(zc.minute ?? 0) / 60
            let pt = point(c, zoneHour / (use24Hour ? 24 : 12) * 2 * Double.pi, r * 0.88)
            let dot = side * 0.026
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - dot, y: pt.y - dot,
                                            width: dot * 2, height: dot * 2)),
                     with: .color(zoneColor.color))
        }

        // Optional text: AM/PM above the center; day, date and time zone stacked below it.
        // Drawn before the hands so the hands pass over it.
        if showAMPM && !use24Hour {
            let isAM = Calendar.current.component(.hour, from: date) < 12
            drawLabel(&ctx, isAM ? "AM" : "PM",
                      at: CGPoint(x: c.x, y: c.y - r * 0.30), side: side, color: textColor.color)
        }

        for (index, line) in lowerLines(for: date).enumerated() {
            let y = c.y + r * 0.30 + CGFloat(index) * side * 0.085
            drawLabel(&ctx, line, at: CGPoint(x: c.x, y: y), side: side, color: textColor.color)
        }

        // Time (whole seconds, so the second hand ticks)
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let s = Double(comps.second ?? 0)
        let m = Double(comps.minute ?? 0) + s / 60
        let h = Double(use24Hour ? (comps.hour ?? 0) : (comps.hour ?? 0) % 12) + m / 60

        // Hands taper down to the second hand's width at their tips
        let secondWidth = side * 0.007

        // Tapered hour and minute hands (one shared color and opacity)
        let handCol = handColor.color.opacity(handOpacity)
        fillTaperedHand(&ctx, center: c, angle: h / (use24Hour ? 24 : 12) * 2 * Double.pi,
                        length: r * 0.50, width: side * 0.030, tipWidth: secondWidth, color: handCol)
        fillTaperedHand(&ctx, center: c, angle: m / 60 * 2 * Double.pi,
                        length: r * 0.78, width: side * 0.025, tipWidth: secondWidth, color: handCol)

        // Second hand with a short tail
        let secondCol = secondColor.color
        if showSeconds {
            let a = s / 60 * 2 * Double.pi
            var p = Path()
            p.move(to: point(c, a + Double.pi, r * 0.15))
            p.addLine(to: point(c, a, r * 0.88))
            ctx.stroke(p, with: .color(secondCol),
                       style: StrokeStyle(lineWidth: secondWidth, lineCap: .round))
        }

        // Center cap (matches the second hand)
        let cap = Path(ellipseIn: CGRect(x: c.x - side * 0.02, y: c.y - side * 0.02,
                                         width: side * 0.04, height: side * 0.04))
        ctx.fill(cap, with: .color(secondCol))
    }
}

// MARK: - Color settings (color pickers + opacity sliders)

struct ColorRow: View {
    let title: String
    @Binding var color: StoredColor

    var body: some View {
        // The picker edits color only; opacity (where offered) has its own slider
        let binding = Binding<Color>(
            get: { color.color },
            set: { color = StoredColor($0) })

        HStack {
            Text(title)
            Spacer()
            ColorPicker(title, selection: binding, supportsOpacity: false)
                .labelsHidden()
        }
    }
}

struct OpacityRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

struct ColorSettingsView: View {
    @AppStorage("faceColor") private var faceColor = StoredColor.white
    @AppStorage("faceOpacity") private var faceOpacity = 1.0
    @AppStorage("useFaceImage") private var useFaceImage = false
    @AppStorage("faceImagePath") private var faceImagePath = ""
    @AppStorage("handColor") private var handColor = StoredColor.black
    @AppStorage("handOpacity") private var handOpacity = 1.0
    @AppStorage("secondColor") private var secondColor = StoredColor.black
    @AppStorage("markColor") private var markColor = StoredColor.black
    @AppStorage("textColor") private var textColor = StoredColor.black
    @AppStorage("zoneColor") private var zoneColor = StoredColor.red

    private func chooseFaceImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a face image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            faceImagePath = url.path
            useFaceImage = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Face").font(.headline)
            ColorRow(title: "Color", color: $faceColor)
            OpacityRow(title: "Opacity", value: $faceOpacity)

            Toggle("Use image instead of color", isOn: $useFaceImage)
                .disabled(faceImagePath.isEmpty)
            HStack {
                Text(faceImagePath.isEmpty ? "No image chosen"
                                           : (faceImagePath as NSString).lastPathComponent)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFaceImage() }
            }

            Divider()

            Text("Hour & Minute Hands").font(.headline)
            ColorRow(title: "Color", color: $handColor)
            OpacityRow(title: "Opacity", value: $handOpacity)

            Divider()

            Text("Second Hand").font(.headline)
            ColorRow(title: "Color", color: $secondColor)

            Divider()

            Text("Hour & Minute Marks").font(.headline)
            ColorRow(title: "Color", color: $markColor)

            Divider()

            Text("Text (Day, Date, AM/PM, Time Zone)").font(.headline)
            ColorRow(title: "Color", color: $textColor)

            Divider()

            Text("Second Time Zone Dot").font(.headline)
            ColorRow(title: "Color", color: $zoneColor)

            HStack {
                Spacer()
                Button("Reset All") {
                    faceColor = .white
                    faceOpacity = 1
                    useFaceImage = false
                    faceImagePath = ""
                    handColor = .black
                    handOpacity = 1
                    secondColor = .black
                    markColor = .black
                    textColor = .black
                    zoneColor = .red
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Floating window

/// Hosting view that shows the app menu on right-click (or control-click).
/// NSHostingView doesn't show a plain `menu` on its own, so this does it explicitly.
final class ClockHostingView: NSHostingView<ClockFace> {
    var contextMenu: NSMenu?

    override func rightMouseDown(with event: NSEvent) {
        if let contextMenu = contextMenu {
            NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let contextMenu = contextMenu {
            NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }
}

final class ClockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: ClockPanel!
    var clockView: ClockHostingView!
    var statusItem: NSStatusItem!
    var clickThroughItem: NSMenuItem!
    var showMenu: NSMenu!
    var fontMenu: NSMenu!
    var zoneMenu: NSMenu!
    var styleMenu: NSMenu!
    var layerMenu: NSMenu!
    var spacesItem: NSMenuItem!
    var hideIconItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var marksMenu: NSMenu!
    var sizeMenu: NSMenu!
    var settingsWindow: NSWindow?

    let markStyles = ["lines", "dots", "numbers"]

    /// Items in the "Show" submenu: (title, UserDefaults key)
    let showToggles: [(title: String, key: String)] = [
        ("Seconds (Second Hand)", "showSeconds"),
        ("Minute Marks", "showMinuteMarks"),
        ("Border", "showBorder"),
        ("Day of Week", "showDay"),
        ("Date", "showDate"),
        ("Date: Day of Month Only", "dateDayOnly"),
        ("AM/PM", "showAMPM"),
        ("Time Zone", "showTimeZone"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon

        let defaults = UserDefaults.standard
        defaults.register(defaults: ["clockSize": 180,
                                     "showSeconds": true,
                                     "faceOpacity": 1.0,
                                     "handOpacity": 1.0,
                                     "hourMarks": "lines",
                                     "textFont": "rounded",
                                     "secondZone": "",
                                     "clockStyle": "analog",
                                     "use24Hour": false,
                                     "digitalBold": false,
                                     "windowLayer": "floating",
                                     "allSpaces": true,
                                     "hideMenuBarIcon": false,
                                     "showMinuteMarks": true,
                                     "showBorder": true,
                                     "showDay": false,
                                     "showDate": false,
                                     "dateDayOnly": false,
                                     "showAMPM": false,
                                     "showTimeZone": false])

        // One-time carry-over of the face color saved by the previous version
        if defaults.object(forKey: "faceColor") == nil, defaults.object(forKey: "faceRed") != nil {
            let old = StoredColor(red: defaults.double(forKey: "faceRed"),
                                  green: defaults.double(forKey: "faceGreen"),
                                  blue: defaults.double(forKey: "faceBlue"))
            defaults.set(old.rawValue, forKey: "faceColor")
        }

        // The text used to follow the marks color; keep that look until a text color is chosen
        if defaults.object(forKey: "textColor") == nil, let marks = defaults.string(forKey: "markColor") {
            defaults.set(marks, forKey: "textColor")
        }

        panel = ClockPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        applyLayer(defaults.string(forKey: "windowLayer") ?? "floating")
        applySpaces(defaults.bool(forKey: "allSpaces"))
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        clockView = ClockHostingView(rootView: ClockFace())
        panel.contentView = clockView

        // Restore position, then apply the saved size around the same center
        if !panel.setFrameUsingName("FloatingClock") { panel.center() }
        resizePanel(to: CGFloat(UserDefaults.standard.integer(forKey: "clockSize")))
        panel.setFrameAutosaveName("FloatingClock")
        panel.orderFrontRegardless()

        buildMenu()
    }

    // MARK: Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Floating Clock")

        let menu = NSMenu()

        // Size
        sizeMenu = NSMenu()
        let currentSize = UserDefaults.standard.integer(forKey: "clockSize")
        for (title, side) in [("Small", 120), ("Medium", 180), ("Large", 280), ("Huge", 400)] {
            let item = NSMenuItem(title: title, action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = side
            item.state = (side == currentSize) ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeParent = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeMenu
        menu.addItem(sizeParent)

        // Colors and opacity (opens a small settings window)
        let colorsItem = NSMenuItem(title: "Colors…", action: #selector(showColorSettings), keyEquivalent: "")
        colorsItem.target = self
        menu.addItem(colorsItem)

        // Clock style: analog or digital
        styleMenu = NSMenu()
        for (title, key) in [("Analog", "analog"), ("Digital", "digital")] {
            let item = NSMenuItem(title: title, action: #selector(setClockStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            styleMenu.addItem(item)
        }
        refreshChecks(in: styleMenu, selected: UserDefaults.standard.string(forKey: "clockStyle") ?? "analog")
        let styleParent = NSMenuItem(title: "Clock Style", action: nil, keyEquivalent: "")
        styleParent.submenu = styleMenu
        menu.addItem(styleParent)

        // Time format options
        let timeMenu = NSMenu()
        for (title, key) in [("24-Hour Format", "use24Hour"), ("Bold Digital Time", "digitalBold")] {
            let item = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
            timeMenu.addItem(item)
        }
        let timeParent = NSMenuItem(title: "Time Format", action: nil, keyEquivalent: "")
        timeParent.submenu = timeMenu
        menu.addItem(timeParent)

        // Hour marks
        marksMenu = NSMenu()
        let currentMarks = UserDefaults.standard.string(forKey: "hourMarks") ?? "lines"
        for (index, title) in ["Lines", "Dots", "Numbers"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setHourMarks(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (markStyles[index] == currentMarks) ? .on : .off
            marksMenu.addItem(item)
        }
        let marksParent = NSMenuItem(title: "Hour Marks", action: nil, keyEquivalent: "")
        marksParent.submenu = marksMenu
        menu.addItem(marksParent)

        // Text font: a few system styles, then every installed family under "All Fonts"
        fontMenu = NSMenu()
        for (title, key) in [("Rounded", "rounded"), ("System", "default"),
                             ("Serif", "serif"), ("Monospaced", "monospaced")] {
            let item = NSMenuItem(title: title, action: #selector(setTextFont(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            fontMenu.addItem(item)
        }
        fontMenu.addItem(.separator())
        let allFontsMenu = NSMenu()
        for family in NSFontManager.shared.availableFontFamilies.sorted() {
            let item = NSMenuItem(title: family, action: #selector(setTextFont(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = family
            allFontsMenu.addItem(item)
        }
        let allFontsParent = NSMenuItem(title: "All Fonts", action: nil, keyEquivalent: "")
        allFontsParent.submenu = allFontsMenu
        fontMenu.addItem(allFontsParent)
        refreshChecks(in: fontMenu, selected: UserDefaults.standard.string(forKey: "textFont") ?? "rounded")

        let fontParent = NSMenuItem(title: "Text Font", action: nil, keyEquivalent: "")
        fontParent.submenu = fontMenu
        menu.addItem(fontParent)

        // Second time zone: off, a few common cities, then every zone grouped by region
        zoneMenu = NSMenu()
        func addZoneItem(_ title: String, id: String, to target: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(setSecondZone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            target.addItem(item)
        }
        addZoneItem("None", id: "", to: zoneMenu)
        zoneMenu.addItem(.separator())
        for (title, id) in [("UTC", "UTC"), ("New York", "America/New_York"),
                            ("Chicago", "America/Chicago"), ("Denver", "America/Denver"),
                            ("Los Angeles", "America/Los_Angeles"), ("London", "Europe/London"),
                            ("Paris", "Europe/Paris"), ("Berlin", "Europe/Berlin"),
                            ("Dubai", "Asia/Dubai"), ("Kolkata", "Asia/Kolkata"),
                            ("Singapore", "Asia/Singapore"), ("Tokyo", "Asia/Tokyo"),
                            ("Sydney", "Australia/Sydney"), ("Auckland", "Pacific/Auckland")] {
            addZoneItem(title, id: id, to: zoneMenu)
        }
        zoneMenu.addItem(.separator())
        let allZonesMenu = NSMenu()
        var regionMenus: [String: NSMenu] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers.sorted() {
            guard let slash = id.firstIndex(of: "/") else { continue }
            let region = String(id[..<slash])
            let place = String(id[id.index(after: slash)...]).replacingOccurrences(of: "_", with: " ")
            let regionMenu: NSMenu
            if let existing = regionMenus[region] {
                regionMenu = existing
            } else {
                regionMenu = NSMenu()
                regionMenus[region] = regionMenu
                let parent = NSMenuItem(title: region, action: nil, keyEquivalent: "")
                parent.submenu = regionMenu
                allZonesMenu.addItem(parent)
            }
            addZoneItem(place, id: id, to: regionMenu)
        }
        let allZonesParent = NSMenuItem(title: "All Time Zones", action: nil, keyEquivalent: "")
        allZonesParent.submenu = allZonesMenu
        zoneMenu.addItem(allZonesParent)
        refreshChecks(in: zoneMenu, selected: UserDefaults.standard.string(forKey: "secondZone") ?? "")

        let zoneParent = NSMenuItem(title: "Second Time Zone", action: nil, keyEquivalent: "")
        zoneParent.submenu = zoneMenu
        menu.addItem(zoneParent)

        // Window layer: floating (above windows), normal, or desktop (behind all windows)
        layerMenu = NSMenu()
        for (title, key) in [("Floating (above other windows)", "floating"),
                             ("Normal", "normal"),
                             ("Desktop (behind all windows)", "desktop")] {
            let item = NSMenuItem(title: title, action: #selector(setWindowLayer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            layerMenu.addItem(item)
        }
        refreshChecks(in: layerMenu, selected: UserDefaults.standard.string(forKey: "windowLayer") ?? "floating")
        let layerParent = NSMenuItem(title: "Window Layer", action: nil, keyEquivalent: "")
        layerParent.submenu = layerMenu
        menu.addItem(layerParent)

        spacesItem = NSMenuItem(title: "Show on All Spaces", action: #selector(toggleAllSpaces), keyEquivalent: "")
        spacesItem.target = self
        spacesItem.state = UserDefaults.standard.bool(forKey: "allSpaces") ? .on : .off
        menu.addItem(spacesItem)

        // Show: checkable on/off options for each element
        showMenu = NSMenu()
        for toggle in showToggles {
            let item = NSMenuItem(title: toggle.title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = toggle.key
            item.state = UserDefaults.standard.bool(forKey: toggle.key) ? .on : .off
            showMenu.addItem(item)
        }
        let showParent = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        showParent.submenu = showMenu
        menu.addItem(showParent)

        clickThroughItem = NSMenuItem(title: "Click-Through", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThroughItem.target = self
        menu.addItem(clickThroughItem)

        hideIconItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(toggleHideIcon), keyEquivalent: "")
        hideIconItem.target = self
        hideIconItem.state = UserDefaults.standard.bool(forKey: "hideMenuBarIcon") ? .on : .off
        menu.addItem(hideIconItem)

        // Launch at login: needs macOS 13+ and running from an .app bundle
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.autoenablesItems = false   // so the login item can be disabled when unavailable
        menu.delegate = self            // refresh its state each time the menu opens
        refreshLoginItem()

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.isVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")

        // The same menu is available by right-clicking the clock, so it stays
        // reachable when the menu bar icon is hidden.
        clockView.contextMenu = menu
    }

    /// Resize the clock to a square of `side` points, keeping its center in place.
    private func resizePanel(to side: CGFloat, animate: Bool = false) {
        var f = panel.frame
        let center = NSPoint(x: f.midX, y: f.midY)
        f.size = NSSize(width: side, height: side)
        f.origin = NSPoint(x: center.x - side / 2, y: center.y - side / 2)
        panel.setFrame(f, display: true, animate: animate)
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        resizePanel(to: CGFloat(sender.tag), animate: true)
        UserDefaults.standard.set(sender.tag, forKey: "clockSize")
        for item in sizeMenu.items {
            item.state = (item.tag == sender.tag) ? .on : .off
        }
    }

    @objc private func showColorSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: ColorSettingsView())
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                             styleMask: [.titled, .closable],
                             backing: .buffered,
                             defer: false)
            w.title = "Clock Colors"
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.level = .floating     // stay above the floating clock
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func setHourMarks(_ sender: NSMenuItem) {
        UserDefaults.standard.set(markStyles[sender.tag], forKey: "hourMarks")
        for item in marksMenu.items {
            item.state = (item.tag == sender.tag) ? .on : .off
        }
    }

    /// Put a checkmark on the item whose represented string equals `selected`,
    /// searching submenus too.
    private func refreshChecks(in menu: NSMenu, selected: String) {
        for item in menu.items {
            if let key = item.representedObject as? String {
                item.state = (key == selected) ? .on : .off
            }
            if let sub = item.submenu {
                refreshChecks(in: sub, selected: selected)
            }
        }
    }

    @objc private func setTextFont(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: "textFont")
        refreshChecks(in: fontMenu, selected: key)
    }

    @objc private func setClockStyle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: "clockStyle")
        refreshChecks(in: styleMenu, selected: key)
    }

    @objc private func setSecondZone(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "secondZone")
        refreshChecks(in: zoneMenu, selected: id)
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let new = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(new, forKey: key)
        sender.state = new ? .on : .off
    }

    // MARK: Launch at login

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLoginItem()   // the user may have changed it in System Settings
    }

    private func refreshLoginItem() {
        guard #available(macOS 13.0, *) else {
            loginItem.title = "Launch at Login (needs macOS 13+)"
            loginItem.state = .off
            loginItem.isEnabled = false
            return
        }
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            loginItem.title = "Launch at Login (needs the .app bundle)"
            loginItem.state = .off
            loginItem.isEnabled = false
            return
        }
        loginItem.title = "Launch at Login"
        loginItem.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:           loginItem.state = .on
        case .requiresApproval:  loginItem.state = .mixed
        default:                 loginItem.state = .off
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()   // the user must approve it there
            return
        }
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshLoginItem()
    }

    private func applyLayer(_ key: String) {
        switch key {
        case "normal":
            panel.level = .normal
        case "desktop":
            // Just above the desktop icons, below every normal window
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        default:
            panel.level = .floating
        }
    }

    private func applySpaces(_ allSpaces: Bool) {
        panel.collectionBehavior = allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.fullScreenAuxiliary]
    }

    @objc private func setWindowLayer(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: "windowLayer")
        applyLayer(key)
        refreshChecks(in: layerMenu, selected: key)
    }

    @objc private func toggleAllSpaces() {
        let new = !UserDefaults.standard.bool(forKey: "allSpaces")
        UserDefaults.standard.set(new, forKey: "allSpaces")
        spacesItem.state = new ? .on : .off
        applySpaces(new)
    }

    @objc private func toggleHideIcon() {
        let hide = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        if hide && panel.ignoresMouseEvents {
            // Click-through would leave no way to reach the menu
            panel.ignoresMouseEvents = false
            clickThroughItem.state = .off
        }
        UserDefaults.standard.set(hide, forKey: "hideMenuBarIcon")
        hideIconItem.state = hide ? .on : .off
        statusItem.isVisible = !hide
    }

    @objc private func toggleClickThrough() {
        if !panel.ignoresMouseEvents && UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            NSSound.beep()   // with the icon hidden, click-through would lock the menu away
            return
        }
        panel.ignoresMouseEvents.toggle()
        clickThroughItem.state = panel.ignoresMouseEvents ? .on : .off
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
