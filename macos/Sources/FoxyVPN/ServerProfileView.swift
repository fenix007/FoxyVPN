import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ServerProfileView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.serverSummary).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("customServerSummary")
            Button("Импортировать профиль сервера…") { importServer() }
                .disabled(model.phase != .idle)
                .accessibilityIdentifier("importServerProfile")
            Text("Ключ подключения хранится в Связке ключей. Профиль также задаёт начальные правила маршрутизации; их можно изменить ниже.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func importServer() {
        let panel = NSOpenPanel()
        panel.title = "Профиль своего VPN-сервера"
        panel.message = "Выбери JSON-профиль подключения FoxyVPN, полученный с твоего сервера."
        panel.prompt = "Импортировать"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.importServerProfile(from: url) }
        catch { model.errorMessage = "Не удалось импортировать сервер: " + error.localizedDescription }
    }
}
