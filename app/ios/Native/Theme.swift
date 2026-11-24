import SwiftUI
import UIKit

enum HyStyle {
  static let canvas = adaptive(light: 0xF3F5F3, dark: 0x111312)
  static let surface = adaptive(light: 0xFAFAFA, dark: 0x171918)
  static let inset = adaptive(light: 0xE8ECE9, dark: 0x222624)
  static let stroke = adaptive(light: 0xD9DEDB, dark: 0x343937)
  static let ink = adaptive(light: 0x1B1E1D, dark: 0xEEEFEE)
  static let muted = adaptive(light: 0x515A55, dark: 0xA5ABA8)
  static let accent = adaptive(light: 0x2D605D, dark: 0xA8CECA)
  static let fill = adaptive(light: 0x1B1E1D, dark: 0xEEEFEE)
  static let onFill = adaptive(light: 0xFAFAFA, dark: 0x171918)
  static let success = adaptive(light: 0x29604F, dark: 0x9DCCB8)
  static let failure = adaptive(light: 0xA12D38, dark: 0xFFA3AA)

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { rgb($0.userInterfaceStyle == .dark ? dark : light) })
  }

  private static func rgb(_ value: UInt32) -> UIColor {
    UIColor(red: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
  }
}

struct HyIcon: View {
  let symbol: String
  var size: CGFloat = 36

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.46, weight: .semibold))
      .foregroundStyle(HyStyle.accent)
      .frame(width: size, height: size)
      .background(HyStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
      .accessibilityHidden(true)
  }
}

struct HyButton: ButtonStyle {
  var prominent = true
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.semibold))
      .foregroundStyle(prominent ? HyStyle.onFill : HyStyle.ink)
      .frame(maxWidth: .infinity, minHeight: 48)
      .padding(.horizontal, 12)
      .background(prominent ? HyStyle.fill : HyStyle.inset, in: RoundedRectangle(cornerRadius: 8))
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.48)
  }
}

struct HyRow: View {
  let title: String
  let symbol: String
  var detail: String?
  var disclosure = true

  var body: some View {
    HStack(spacing: 12) {
      HyIcon(symbol: symbol)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.body.weight(.semibold)).foregroundStyle(HyStyle.ink)
        if let detail {
          Text(detail).font(.subheadline).foregroundStyle(HyStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if disclosure {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold)).foregroundStyle(HyStyle.muted)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 4)
    .frame(minHeight: 44)
    .contentShape(Rectangle())
  }
}

struct HyHeading: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.headline.weight(.semibold))
      .foregroundStyle(HyStyle.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}

extension View {
  func hyCard(padding: CGFloat = 14) -> some View {
    self.padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HyStyle.surface, in: RoundedRectangle(cornerRadius: 16))
      .overlay {
        RoundedRectangle(cornerRadius: 16).strokeBorder(HyStyle.stroke, lineWidth: 1)
          .allowsHitTesting(false)
      }
  }

  func hyScreen() -> some View {
    self.background(HyStyle.canvas.ignoresSafeArea())
      .toolbarBackground(HyStyle.canvas, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .tint(HyStyle.accent)
  }

  func hyList() -> some View {
    self.scrollContentBackground(.hidden).hyScreen()
  }
}
