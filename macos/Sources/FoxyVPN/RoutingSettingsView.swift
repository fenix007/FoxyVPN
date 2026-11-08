import SwiftUI
import Combine
import FoxyCore

private final class RoutingDraft: ObservableObject {
    @Published var bypassRussianDomains: Bool
    @Published var entries: String
    @Published var error: String?
    @Published var loading = false

    init(_ settings: RoutingSettings) {
        bypassRussianDomains = settings.bypassRussianDomains
        entries = settings.entriesText
    }
}

struct RoutingSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: RoutingDraft

    init(model: AppModel) {
        self.model = model
        _draft = StateObject(wrappedValue: RoutingDraft(model.routing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Сайты без VPN").font(.title2.bold())
            Text("Эти сайты открываются через обычное подключение. Остальной трафик идёт через VPN. Локальная сеть всегда доступна напрямую.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Открывать .ru, .su и .рф без VPN", isOn: $draft.bypassRussianDomains)
            Text("Это правило действует и для заблокированных сайтов в этих зонах.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Свои исключения").font(.headline)
                Text("По одному домену, IP или подсети CIDR на строке. Домен включает все его поддомены.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $draft.entries)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 180)
                    .border(.separator)
                    .accessibilityLabel("Домены, IP и подсети без VPN")
                Text("Например: example.com, 203.0.113.5, 2001:db8::/32. Без https:// и путей.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(draft.loading ? "Загрузка…" : "Добавить список UnRKN") {
                        Task { await importUnRKN() }
                    }.disabled(draft.loading)
                    Link("Посмотреть список ↗", destination: URL(string: "https://github.com/UnRKN/ru-blocklist")!)
                }
                Text("Список российских сервисов, которым нужен прямой доступ. Добавится в поле выше; изменения вступят в силу после сохранения.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = draft.error {
                Text(error).foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("routingError")
            }
            Text(model.phase == .idle ? "Настройки применятся при подключении VPN." : "Сохрани настройки, затем отключи VPN и подключись снова.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    do {
                        let settings = try RoutingSettings.parse(draft.entries, bypassRussianDomains: draft.bypassRussianDomains)
                        try model.saveRouting(settings)
                        dismiss()
                    } catch { draft.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut(.defaultAction).disabled(draft.loading)
            }
        }.padding(24).frame(width: 510)
    }

    @MainActor
    private func importUnRKN() async {
        draft.loading = true
        draft.error = nil
        defer { draft.loading = false }
        do {
            let url = URL(string: "https://raw.githubusercontent.com/UnRKN/ru-blocklist/refs/heads/main/ru-blocklist.txt")!
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty, data.count <= 32 * 1024,
                  let text = String(data: data, encoding: .utf8) else {
                throw RoutingSettingsError("Не удалось загрузить список UnRKN. Попробуй позже или добавь домены вручную.")
            }
            // Parse the downloaded list separately: a comment-only/empty response
            // must not be reported as a successful import.
            let imported = try RoutingSettings.parse(text, bypassRussianDomains: false)
            guard !imported.directDomains.isEmpty, imported.directIPCIDRs.isEmpty else {
                throw RoutingSettingsError("UnRKN вернул некорректный список доменов.")
            }
            let merged = try RoutingSettings.parse(draft.entries + "\n" + imported.entriesText,
                bypassRussianDomains: draft.bypassRussianDomains)
            draft.entries = merged.entriesText
        } catch { draft.error = error.localizedDescription }
    }
}
