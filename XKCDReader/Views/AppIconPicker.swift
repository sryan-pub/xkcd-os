import SwiftUI
import UIKit

/// The home-screen icons the reader can choose from. Each has a light and a dark version,
/// and iOS switches between them with the system appearance.
struct AppIconOption: Identifiable, Hashable {
    let title: String
    /// The alternate icon's asset name, or `nil` for the default icon.
    let iconName: String?
    let preview: String

    var id: String { preview }

    static let all: [AppIconOption] = [
        AppIconOption(title: "Mosaic", iconName: nil, preview: "IconPreview-Mosaic"),
        AppIconOption(title: "Classic", iconName: "AppIcon-Classic", preview: "IconPreview-Classic"),
        AppIconOption(title: "Stick Figure", iconName: "AppIcon-Figure", preview: "IconPreview-Figure"),
        AppIconOption(title: "Favorite", iconName: "AppIcon-Heart", preview: "IconPreview-Heart"),
        AppIconOption(title: "Alt Text", iconName: "AppIcon-Bubble", preview: "IconPreview-Bubble"),
    ]
}

struct AppIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current = UIApplication.shared.alternateIconName
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(AppIconOption.all) { option in
                        Button {
                            choose(option)
                        } label: {
                            iconCell(option, isSelected: option.iconName == current)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)

                Text("Each icon has a light and a dark version and follows your Home Screen appearance.")
                    .font(.xkcd(size: 16, relativeTo: .footnote))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("App Icon")
                        .font(.xkcd(size: 22, relativeTo: .headline))
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done").font(.xkcd(size: 19, relativeTo: .body))
                    }
                }
            }
            .alert("Couldn't Change the Icon", isPresented: Binding(get: { errorMessage != nil },
                                                                   set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func iconCell(_ option: AppIconOption, isSelected: Bool) -> some View {
        VStack(spacing: 10) {
            Image(option.preview)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(isSelected ? Color.xkcdSlate : Color.primary.opacity(0.15),
                                      lineWidth: isSelected ? 4 : 1)
                }
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.xkcdSlate)
                }
                Text(option.title)
            }
            .font(.xkcd(size: 18, relativeTo: .subheadline))
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.title) icon")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func choose(_ option: AppIconOption) {
        guard option.iconName != current else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "This device doesn't support changing the app icon."
            return
        }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(option.iconName)
                current = option.iconName
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
