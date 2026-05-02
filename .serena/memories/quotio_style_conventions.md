# Quotio style and conventions

- Swift 6, SwiftUI, macOS 15+, Xcode 16+
- UI-bound classes are commonly `@MainActor @Observable final class`
- Thread-safe async code uses `actor`
- Model and request types often conform to `Codable` and `Sendable`
- Prefer small computed properties for display text/formatting on models
- Provider display names come from `AIProvider.displayName`
- View structure typically uses `@Environment(QuotaViewModel.self)` and `@State` with `// MARK: -` sections
- Many API payload structs use snake_case coding keys
