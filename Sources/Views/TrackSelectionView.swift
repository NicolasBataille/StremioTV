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
            column("Langue") {
                ForEach(controller.subtitleLanguages, id: \.self) { language in
                    row(title: language, selected: language == selectedLanguage) {
                        selectedLanguage = language
                    }
                }
            }
            column("Variante") {
                ForEach(controller.variants(for: selectedLanguage)) { option in
                    row(title: option.source.isEmpty ? option.language : option.source,
                        subtitle: option.source.isEmpty ? nil : option.language,
                        selected: option.id == controller.currentSubtitleId) {
                        controller.currentSubtitleId = option.id
                        controller.selectSubtitle(option)
                    }
                }
            }
            column("Réglages") { delayControl }
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
