import SwiftUI

/// A graphical light/dark/system switcher, styled like macOS System Settings:
/// three tiles, each a small window rendered in that appearance, with a radio and
/// label beneath and an accent ring on the selection.
struct AppearanceModePicker: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: 20) {
            ForEach(AppearanceMode.allCases) { mode in
                Tile(mode: mode, isSelected: mode == selection) {
                    selection = mode
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private struct Tile: View {
        let mode: AppearanceMode
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            VStack(spacing: 8) {
                Button(action: action) {
                    WindowMock(mode: mode)
                        .frame(width: 116, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: isSelected ? 3 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                Label {
                    Text(mode.displayName).font(.system(size: 12))
                } icon: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// A miniature window drawn in a fixed light or dark appearance for the
/// `AppearanceModePicker` tiles. `.system` shows both, divided by a diagonal, the
/// way the macOS "Auto" swatch does.
private struct WindowMock: View {
    let mode: AppearanceMode

    var body: some View {
        switch mode {
        case .light:
            pane(dark: false)
        case .dark:
            pane(dark: true)
        case .system:
            ZStack {
                pane(dark: false)
                pane(dark: true).clipShape(DiagonalSplit())
            }
        }
    }

    private func pane(dark: Bool) -> some View {
        let body = dark ? Color(white: 0.13) : Color.white
        let bar = dark ? Color(white: 0.22) : Color(white: 0.93)
        let line = dark ? Color(white: 0.32) : Color(white: 0.82)
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.24, green: 0.79, blue: 0.33)).frame(width: 5, height: 5)
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 17)
            .frame(maxWidth: .infinity)
            .background(bar)
            ZStack(alignment: .topLeading) {
                body
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 54, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 38, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 46, height: 5)
                }
                .padding(9)
            }
        }
    }
}

/// The trailing region of the "Auto" swatch: a slightly slanted vertical split so
/// the dark pane occupies the right side over the light pane.
private struct DiagonalSplit: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
