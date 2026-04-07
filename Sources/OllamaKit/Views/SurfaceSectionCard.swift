import SwiftUI

struct SurfaceSectionCard<Content: View>: View {
    let title: String?
    let icon: String?
    let footer: String?
    let content: Content

    init(
        title: String? = nil,
        icon: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                .padding(.horizontal, 4)
            }

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .fill(.white.opacity(0.09))
                            .frame(width: 90, height: 90)
                            .blur(radius: 20)
                            .offset(x: -25, y: -35)
                    }
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}
