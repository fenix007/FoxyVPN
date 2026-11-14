import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import FoxyCore

private enum UnRKNSource {
    // Reviewed snapshot; upstream changes must not broaden routing silently.
    static let revision = "155441a59bbe913f9ef494cc67e909c3d88ad326"
    static let url = URL(string: "https://raw.githubusercontent.com/UnRKN/ru-blocklist/\(revision)/ru-blocklist.txt")!
}

private final class RoutingDraft: ObservableObject {
    @Published var mode: RoutingMode
    @Published var bypassRussianDomains: Bool
    @Published var entries: String
    @Published var vpnEntries: String
    @Published var routeCodingClients: Bool
    @Published var error: String?
    @Published var loading = false

    init(_ settings: RoutingSettings) {
        mode = settings.mode
        bypassRussianDomains = settings.bypassRussianDomains
        entries = settings.entriesText
        vpnEntries = settings.vpnEntriesText
        routeCodingClients = settings.routeCodingClients
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
            Text("Маршрутизация").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Через VPN", selection: $draft.mode) {
                        Text("Весь трафик").tag(RoutingMode.allTraffic)
                        Text("Выбранные сайты и клиенты").tag(RoutingMode.selectedSites)
                    }
                    .accessibilityIdentifier("routingMode")
                    Button("Импортировать профиль…") { importProfile() }
                        .disabled(draft.loading)
                        .accessibilityIdentifier("importRoutingProfile")
                    Text("Импорт заменит поля в этом окне. Проверь их и нажми «Сохранить», чтобы применить профиль.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(draft.mode == .allTraffic
                        ? "Весь трафик идёт через VPN, кроме исключений ниже. Локальная сеть доступна напрямую."
                        : "Через VPN идут выбранные домены и включённые клиенты. Остальной трафик и локальная сеть доступны напрямую.")
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.mode == .selectedSites {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Сайты через VPN").font(.headline)
                            Text("По одному домену на строке, без https:// и путей. Домен включает его поддомены.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            TextEditor(text: $draft.vpnEntries)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 120)
                                .border(.separator)
                                .accessibilityLabel("Домены через VPN")
                            Button("Добавить Claude, Codex и Codotok") { addCodingServices() }
                                .accessibilityIdentifier("addCodingServices")
                            Toggle("Направлять клиенты Claude и Codex через VPN", isOn: $draft.routeCodingClients)
                                .accessibilityIdentifier("routeCodingClients")
                            Text("Кнопка добавляет домены сервисов и включает маршрутизацию клиентов. Список можно отредактировать перед сохранением.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                    }
                    Toggle("Открывать .ru, .su и .рф без VPN", isOn: $draft.bypassRussianDomains)
                    Text("Это правило действует и для заблокированных сайтов в этих зонах.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Сайты без VPN").font(.headline)
                        Text("По одному домену, IP или подсети CIDR на строке. Эти исключения имеют приоритет над сайтами и клиентами через VPN.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: $draft.entries)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 150)
                            .border(.separator)
                            .accessibilityLabel("Домены, IP и подсети без VPN")
                        Text("Например: example.com, 203.0.113.5, 2001:db8::/32. Без https:// и путей.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(draft.loading ? "Загрузка…" : "Добавить список UnRKN") {
                                Task { await importUnRKN() }
                            }.disabled(draft.loading)
                            Link("Посмотреть список ↗", destination: UnRKNSource.url)
                        }
                        Text("Снимок списка российских сервисов для прямого доступа. Добавится в поле выше; изменения вступят в силу после сохранения.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(maxHeight: 500)
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
                        let settings = try RoutingSettings.parse(draft.entries,
                            bypassRussianDomains: draft.bypassRussianDomains, mode: draft.mode,
                            vpnDomainsText: draft.vpnEntries, routeCodingClients: draft.routeCodingClients)
                        try model.saveRouting(settings)
                        dismiss()
                    } catch { draft.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut(.defaultAction).disabled(draft.loading)
            }
        }.padding(24).frame(width: 550)
    }

    @MainActor
    private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Импорт профиля маршрутизации"
        panel.message = "Выбери JSON-профиль FoxyVPN. Он заменит поля в окне настроек; сохранение выполняется отдельно."
        panel.prompt = "Импортировать"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard metadata.isRegularFile == true, let size = metadata.fileSize,
                  size > 0, size <= 40 * 1024 else {
                throw RoutingSettingsError("Нужен непустой JSON-файл профиля размером не более 40 КБ.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Bound the read even if the selected file changes after the size check.
            let data = try handle.read(upToCount: 40 * 1024 + 1) ?? Data()
            guard !data.isEmpty, data.count <= 40 * 1024 else {
                throw RoutingSettingsError("Нужен непустой JSON-файл профиля размером не более 40 КБ.")
            }
            let imported = try JSONDecoder().decode(RoutingSettings.self, from: data).validated()
            draft.mode = imported.mode
            draft.bypassRussianDomains = imported.bypassRussianDomains
            draft.entries = imported.entriesText
            draft.vpnEntries = imported.vpnEntriesText
            draft.routeCodingClients = imported.routeCodingClients
            draft.error = nil
        } catch is DecodingError {
            draft.error = "Не удалось импортировать профиль: файл не соответствует формату JSON-профиля FoxyVPN."
        } catch {
            draft.error = "Не удалось импортировать профиль: " + error.localizedDescription
        }
    }

    private func addCodingServices() {
        do {
            let merged = try RoutingSettings.parse(draft.entries,
                bypassRussianDomains: draft.bypassRussianDomains, mode: draft.mode,
                vpnDomainsText: draft.vpnEntries + "\n" + RoutingSettings.codingDomains.joined(separator: "\n"),
                routeCodingClients: true)
            draft.vpnEntries = merged.vpnEntriesText
            draft.routeCodingClients = true
            draft.error = nil
        } catch { draft.error = error.localizedDescription }
    }

    @MainActor
    private func importUnRKN() async {
        draft.loading = true
        draft.error = nil
        defer { draft.loading = false }
        do {
            let request = URLRequest(url: UnRKNSource.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
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
                bypassRussianDomains: draft.bypassRussianDomains, mode: draft.mode,
                vpnDomainsText: draft.vpnEntries, routeCodingClients: draft.routeCodingClients)
            draft.entries = merged.entriesText
        } catch { draft.error = error.localizedDescription }
    }
}
