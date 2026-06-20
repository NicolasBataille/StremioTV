import SwiftUI

/// Panneau de sélection des pistes, façon Stremio : colonnes
/// Langue → Variante → Réglages (sous-titres), et liste des doublages (audio).
struct TrackSelectionView: View {
    @Bindable var controller: TrackController
    var onClose: () -> Void

    @State private var tab = 0
    @State private var selectedLanguage = "OFF"

    var body: some View {
        VStack(spacing: 36) {
            Picker("", selection: $tab) {
                Text("Sous-titres").tag(0)
                Text("Audio (doublage)").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 700)

            if tab == 0 { subtitleColumns } else { audioColumn }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.92))
        .onExitCommand(perform: onClose)
        .onAppear {
            selectedLanguage = controller.subtitleOptions
                .first { $0.id == controller.currentSubtitleId }?.language ?? "OFF"
        }
    }

    // MARK: - Sous-titres

    private var subtitleColumns: some View {
        HStack(alignment: .top, spacing: 48) {
            // Clic sur une langue = applique directement le meilleur sous-titre
            // (embarqué prioritaire). La colonne Variante ne sert qu'à affiner.
            column("Langue") {
                ForEach(controller.subtitleLanguages, id: \.self) { language in
                    row(title: language, selected: language == currentLanguage) {
                        selectedLanguage = language
                        applyBestVariant(for: language)
                    }
                }
            }
            .focusSection()

            column("Variante") {
                let variants = controller.variants(for: selectedLanguage)
                if variants.count > 1 {
                    ForEach(Array(variants.enumerated()), id: \.element.id) { index, option in
                        row(title: variantTitle(option, index: index),
                            selected: option.id == controller.currentSubtitleId) {
                            controller.currentSubtitleId = option.id
                            controller.selectSubtitle(option)
                        }
                    }
                } else {
                    Text("—").foregroundStyle(.secondary).padding(.vertical, 10)
                }
            }
            .focusSection()

            column("Réglages") { delayControl }
                .focusSection()
        }
    }

    private var currentLanguage: String {
        controller.subtitleOptions.first { $0.id == controller.currentSubtitleId }?.language ?? "OFF"
    }

    private func applyBestVariant(for language: String) {
        guard let best = controller.variants(for: language).first else { return }
        controller.currentSubtitleId = best.id
        controller.selectSubtitle(best)
    }

    private func variantTitle(_ option: SubtitleOption, index: Int) -> String {
        switch option.kind {
        case .off: return "OFF"
        case .embedded: return option.source.isEmpty ? "Intégré" : option.source
        case .external: return "\(option.source) \(index + 1)"
        }
    }

    private var delayControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Délai").font(.headline).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button {
                    controller.subtitleDelayMs -= 250
                    controller.setDelay(controller.subtitleDelayMs)
                } label: { Image(systemName: "minus") }
                Text("\(controller.subtitleDelayMs) ms").monospacedDigit().frame(width: 140)
                Button {
                    controller.subtitleDelayMs += 250
                    controller.setDelay(controller.subtitleDelayMs)
                } label: { Image(systemName: "plus") }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(white: 0.3))
        }
    }

    // MARK: - Audio

    private var audioColumn: some View {
        column("Doublage") {
            if controller.audioOptions.isEmpty {
                Text("Aucune piste audio détectée.").foregroundStyle(.secondary)
            }
            ForEach(controller.audioOptions) { option in
                row(title: option.label, selected: option.id == controller.currentAudioId) {
                    controller.currentAudioId = option.id
                    controller.selectAudio(option.id)
                }
            }
        }
    }

    // MARK: - Building blocks

    private func column<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.bold())
            ScrollView { VStack(alignment: .leading, spacing: 10) { content() } }
        }
        .frame(width: 440, alignment: .leading)
    }

    private func row(title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Circle().fill(.green).frame(width: 14, height: 14)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.card)
    }
}
