import SwiftUI

/// The notch outline: square top edge with small outward flares, rounded bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                          control: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                          control: CGPoint(x: rect.minX + t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                          control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Alert

struct NotchAlertView: View {
    @ObservedObject var state: AlertState

    var body: some View {
        let size = Metrics.size(for: state.alert, expanded: state.isExpanded,
                                notchWidth: state.notchWidth, notchHeight: state.notchHeight,
                                collapsedWidth: state.collapsedWidth)
        let card = state.isExpanded && state.alert.isCard

        ZStack(alignment: .top) {
            Rectangle().fill(Color.black)
            AlertContent(alert: state.alert, notchWidth: state.notchWidth, notchHeight: state.notchHeight)
                .fixedSize()
                .opacity(state.isExpanded ? 1 : 0)
                // Own timing: fade in once the shape has started growing, fade out fast.
                .animation(state.isExpanded ? Anim.contentIn : Anim.contentOut, value: state.isExpanded)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(topRadius: card ? Metrics.cardTopRadius : Metrics.topRadius,
                              bottomRadius: card ? Metrics.cardBottomRadius : Metrics.bottomRadius))
        .contentShape(NotchShape(topRadius: card ? Metrics.cardTopRadius : Metrics.topRadius,
                                 bottomRadius: card ? Metrics.cardBottomRadius : Metrics.bottomRadius))
        .onTapGesture { state.onTap?() }
        // Hovering a clickable alert grows it slightly, like a button.
        .scaleEffect(state.isHovered ? 1.04 : 1, anchor: .top)
        // Hidden between alerts. On screens without a real notch the collapsed pill is hidden too.
        .opacity(state.isShown && (state.hasNotch || state.isExpanded) ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

struct AlertContent: View {
    let alert: NotchAlert
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        switch alert.layout {
        case let .compact(text, symbol, tint, value, battery):
            let wing = alert.compactWing
            HStack(spacing: 0) {
                SwapText(text: text)
                    .frame(width: wing, alignment: .leading)
                Color.clear
                    .frame(width: Metrics.gap(notchWidth))
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint.color)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    if let value {
                        Text(value)
                            .font(.system(size: Metrics.fontSize, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(tint.color)
                    }
                    if let battery {
                        BatteryGlyph(level: CGFloat(battery), tint: tint)
                    }
                }
                .frame(width: wing, alignment: .trailing)
            }
            .padding(.horizontal, Metrics.compactInset)
            .frame(height: notchHeight)

        case let .card(symbol, tint, title, subtitle, subtitleTint, levels):
            VStack(spacing: 0) {
                Color.clear.frame(height: notchHeight)
                HStack(spacing: 12) {
                    if let thumbnail = alert.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 24))
                            .foregroundStyle(tint.color)
                            .frame(width: 34, height: 34)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(subtitleTint.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    ForEach(levels, id: \.label) { level in
                        BatteryRing(level: level)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
                .frame(width: notchWidth + 2 * Metrics.cardWing, height: Metrics.cardRowHeight)
            }
        }
    }
}

/// Cross-fades when the text changes (e.g. "Locked" → "Unlocked").
struct SwapText: View {
    let text: String

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(.system(size: Metrics.fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .id(text)
                .transition(.opacity)
        }
    }
}

struct BatteryGlyph: View {
    let level: CGFloat
    let tint: Tint

    var body: some View {
        let clamped = min(max(level, 0), 1)
        let fill = max(2.5, (Metrics.batteryWidth - 7) * clamped)
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint.color)
                    .frame(width: fill, height: 8)
                    .padding(.leading, 2)
            }
            .frame(width: Metrics.batteryWidth - 3, height: 12)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
    }
}

struct BatteryRing: View {
    let level: BatteryLevel

    var body: some View {
        let color = level.percent <= 20 ? Tint.red.color : Tint.green.color
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(level.percent) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(level.percent)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            Text(level.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Tint.gray.color)
        }
    }
}

// MARK: - Camera / microphone dots

struct PrivacyIndicatorView: View {
    @ObservedObject var state: IndicatorState

    var body: some View {
        let dots = (state.camera ? 1 : 0) + (state.microphone ? 1 : 0)
        // Tucks under the rounded corner of the notch (or boringNotch's music wings)
        // so the two read as one shape, without covering the album art or bars.
        let overlap = Metrics.bottomRadius
        let width: CGFloat = state.isExpanded ? overlap + CGFloat(14 + dots * 10) : 0

        ZStack(alignment: .trailing) {
            Rectangle().fill(Color.black)
            HStack(spacing: 4) {
                if state.camera {
                    Circle().fill(Tint.green.color).frame(width: 6, height: 6)
                }
                if state.microphone {
                    Circle().fill(Tint.orange.color).frame(width: 6, height: 6)
                }
            }
            .padding(.trailing, Metrics.topRadius + 8)
            .opacity(state.isExpanded ? 1 : 0)
        }
        .frame(width: width, height: state.notchHeight)
        .clipShape(WingShape(topRadius: Metrics.topRadius, bottomRadius: Metrics.bottomRadius))
        // Left edge stays pinned just inside the right edge of the current notch shape.
        .offset(x: state.collapsedWidth / 2 - overlap + width / 2)
        .opacity(state.isShown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// The right-hand end of a notch: square left side, flared top, rounded bottom.
struct WingShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 2))
        let b = max(0, min(bottomRadius, rect.width - t, rect.height - t))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.minY + t),
                          control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
