import SwiftUI
import SwiftData

struct ContentView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Chat Tab
            NavigationStack {
                ChatSessionsView()
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.fill")
            }
            .tag(0)
            
            // Models Tab
            NavigationStack {
                ModelsView()
            }
            .tabItem {
                Label("Models", systemImage: "cube.fill")
            }
            .tag(1)
            
            // Server Tab
            NavigationStack {
                ServerView()
            }
            .tabItem {
                Label("Server", systemImage: "network")
            }
            .tag(2)

            // Automations Tab
            NavigationStack {
                AutomationsView()
            }
            .tabItem {
                Label("Automate", systemImage: "wand.and.stars")
            }
            .tag(3)

            // Settings Tab
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(4)
        }
        .tint(Color.accentColor)
        .preferredColorScheme(settings.darkMode ? .dark : .light)
    }
}

// MARK: - Liquid Glass Modifier

struct LiquidGlassModifier: ViewModifier {
    var intensity: Double = 0.15
    var radius: CGFloat = 20
    
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(
                                MeshGradient(
                                    width: 3,
                                    height: 3,
                                    points: [
                                        .init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 0),
                                        .init(x: 0, y: 0.5), .init(x: 0.5, y: 0.5), .init(x: 1, y: 0.5),
                                        .init(x: 0, y: 1), .init(x: 0.5, y: 1), .init(x: 1, y: 1)
                                    ],
                                    colors: [
                                        Color.accentColor.opacity(0.1),
                                        Color.accentColor.opacity(0.05),
                                        Color.accentColor.opacity(0.1),
                                        Color.accentColor.opacity(0.05),
                                        Color.accentColor.opacity(0.02),
                                        Color.accentColor.opacity(0.05),
                                        Color.accentColor.opacity(0.1),
                                        Color.accentColor.opacity(0.05),
                                        Color.accentColor.opacity(0.1)
                                    ]
                                )
                            )
                            .opacity(intensity)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: radius)
                                    .fill(Color.accentColor.opacity(intensity * 0.5))
                            )
                    )
            } else {
                content
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: radius)
                                .fill(.ultraThinMaterial)

                            RoundedRectangle(cornerRadius: radius)
                                .fill(
                                    MeshGradient(
                                        width: 3,
                                        height: 3,
                                        points: [
                                            .init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 0),
                                            .init(x: 0, y: 0.5), .init(x: 0.5, y: 0.5), .init(x: 1, y: 0.5),
                                            .init(x: 0, y: 1), .init(x: 0.5, y: 1), .init(x: 1, y: 1)
                                        ],
                                        colors: [
                                            Color.accentColor.opacity(0.1),
                                            Color.accentColor.opacity(0.05),
                                            Color.accentColor.opacity(0.1),
                                            Color.accentColor.opacity(0.05),
                                            Color.accentColor.opacity(0.02),
                                            Color.accentColor.opacity(0.05),
                                            Color.accentColor.opacity(0.1),
                                            Color.accentColor.opacity(0.05),
                                            Color.accentColor.opacity(0.1)
                                        ]
                                    )
                                )
                                .opacity(intensity)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    )
            }
        }
    }
}

extension View {
    func liquidGlass(intensity: Double = 0.15, radius: CGFloat = 20) -> some View {
        modifier(LiquidGlassModifier(intensity: intensity, radius: radius))
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    let content: Content
    var intensity: Double = 0.15
    var radius: CGFloat = 20
    var padding: CGFloat = 16
    
    init(intensity: Double = 0.15, radius: CGFloat = 20, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.intensity = intensity
        self.radius = radius
        self.padding = padding
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(padding)
            .liquidGlass(intensity: intensity, radius: radius)
    }
}

// MARK: - Animated Background

public struct AnimatedMeshBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0
    
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Color.black

                backgroundBlob(
                    color: Color.cyan.opacity(0.22),
                    size: CGSize(width: size.width * 1.15, height: size.height * 0.48),
                    offset: CGSize(
                        width: sin(phase * 0.8) * 28,
                        height: -size.height * 0.24 + cos(phase * 0.6) * 22
                    )
                )

                backgroundBlob(
                    color: Color.blue.opacity(0.20),
                    size: CGSize(width: size.width * 1.25, height: size.height * 0.68),
                    offset: CGSize(
                        width: size.width * 0.16 + cos(phase * 0.5) * 24,
                        height: sin(phase * 0.7) * 20
                    )
                )

                backgroundBlob(
                    color: Color.purple.opacity(0.18),
                    size: CGSize(width: size.width * 1.05, height: size.height * 0.54),
                    offset: CGSize(
                        width: -size.width * 0.2 + sin(phase * 0.65) * 26,
                        height: size.height * 0.27 + cos(phase * 0.5) * 20
                    )
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.05),
                        Color.black.opacity(0.2),
                        Color.black.opacity(0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !reduceMotion else {
                phase = .pi * 0.35
                return
            }

            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                phase = .pi * 2
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func backgroundBlob(color: Color, size: CGSize, offset: CGSize) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        color,
                        color.opacity(0.55),
                        color.opacity(0.18),
                        .clear
                    ],
                    center: .center,
                    startRadius: 24,
                    endRadius: max(size.width, size.height) * 0.5
                )
            )
            .frame(width: size.width, height: size.height)
            .offset(offset)
            .blur(radius: 72)
            .blendMode(.screen)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ChatSession.self, ChatMessage.self, DownloadedModel.self, FileSource.self, IndexedFile.self], inMemory: true)
}
