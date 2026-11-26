import SwiftUI

struct InspectorScrollContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct InspectorCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var cardStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.085)
            : Color.black.opacity(0.08)
    }

    private var headerColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.62)
            : Color(nsColor: .secondaryLabelColor)
    }

    private var defaultForeground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.90)
            : Color(nsColor: .labelColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(headerColor)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .foregroundStyle(defaultForeground)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: 0.75)
            )
        }
    }
}

struct InspectorRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.90) : Color(nsColor: .labelColor))
                .lineLimit(2)

            Spacer(minLength: 8)

            content
                .font(.system(size: 12.5))
        }
    }
}

struct InspectorToggleRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.90) : Color(nsColor: .labelColor))
                .lineLimit(2)

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct InspectorMenuLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String

    var body: some View {
        Text(title)
            .lineLimit(1)
            .truncationMode(.middle)
            .font(.system(size: 12))
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.90) : Color(nsColor: .labelColor))
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 3.5)
    }
}

struct InspectorRowDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06))
            .frame(height: 0.5)
    }
}

struct InspectorInputWellModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.28) : Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14),
                        lineWidth: 0.75
                    )
            )
    }
}

struct InspectorPillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity = colorScheme == .dark
            ? (configuration.isPressed ? 0.18 : 0.10)
            : (configuration.isPressed ? 0.14 : 0.07)
        let strokeColor = colorScheme == .dark
            ? Color.white.opacity(0.11)
            : Color.black.opacity(0.09)
        let labelColor: Color = if !isEnabled {
            colorScheme == .dark ? Color.white.opacity(0.32) : Color(nsColor: .tertiaryLabelColor)
        } else {
            colorScheme == .dark ? Color.white.opacity(0.90) : Color(nsColor: .labelColor)
        }

        configuration.label
            .font(.system(size: compact ? 11.5 : 12, weight: .medium))
            .foregroundStyle(labelColor)
            .padding(.horizontal, compact ? 10 : 8)
            .padding(.vertical, compact ? 3.5 : 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(fillOpacity) : Color.black.opacity(fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
