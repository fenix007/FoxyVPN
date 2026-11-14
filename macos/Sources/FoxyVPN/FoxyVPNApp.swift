import AppKit
import SwiftUI
import FoxyCore

@main
struct Launcher {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do {
                guard let resources = Bundle.main.resourceURL else { throw AppFailure("Нет ресурсов приложения") }
                for name in ["foxyvpn-proxy", "sing-box", "foxyvpn-tunnel", "foxyvpn-relay"] {
                    guard FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent(name).path) else {
                        throw AppFailure("Не найден \(name)")
                    }
                }
                for mode in RoutingMode.allCases {
                    let routing = try RoutingSettings.parse("example.com\n203.0.113.0/24\n2001:db8::/32",
                        bypassRussianDomains: true, mode: mode,
                        vpnDomainsText: RoutingSettings.codingDomains.joined(separator: "\n"),
                        routeCodingClients: true)
                    let configuration = try TunnelConfiguration.data(port: 1088, interface: "en0", routing: routing)
                    let file = FileManager.default.temporaryDirectory
                        .appendingPathComponent("foxyvpn-check-" + UUID().uuidString + ".json")
                    try configuration.write(to: file)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let check = Process()
                    check.executableURL = resources.appendingPathComponent("sing-box")
                    check.arguments = ["check", "-c", file.path]
                    try check.run()
                    check.waitUntilExit()
                    guard check.terminationStatus == 0 else {
                        throw AppFailure("Сетевое ядро отклонило конфигурацию туннеля: \(mode.rawValue)")
                    }
                }
                print("FoxyVPN macOS: app resources and tunnel configuration OK")
                return
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        FoxyVPNApp.main()
    }
}

struct FoxyVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("FoxyVPN", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 540, height: 610)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        MenuBarExtra("FoxyVPN", systemImage: model.phase == .connected ? "network.badge.shield.half.filled" : "network") {
            Text(model.status)
            Text("↓ \(TrafficView.bytes(model.traffic.session.received))   ↑ \(TrafficView.bytes(model.traffic.session.sent))")
            if model.phase == .connected {
                Button("Отключить") { model.disconnect() }
            }
            Button("Открыть FoxyVPN") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil) }
            }
            Divider()
            Button("Выйти") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 34)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FoxyVPN").font(.title.bold())
                    Text("Firefox VPN и свой сервер").foregroundStyle(.secondary)
                }
                Spacer()
                Text("Неофициальный клиент").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                Image(systemName: model.phase == .connected ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 70, weight: .light))
                    .foregroundStyle(model.phase == .connected ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Text(model.status).font(.headline).multilineTextAlignment(.center)
                if !model.exitIP.isEmpty {
                    Text("IP выхода: \(model.exitIP)").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                if model.busy { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, minHeight: 155)

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("VPN-сервер", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                        Text("Firefox VPN").tag(AppModel.Provider.firefox)
                        Text("Свой сервер").tag(AppModel.Provider.custom)
                    }.disabled(model.phase != .idle)
                    if model.provider == .custom {
                        ServerProfileView(model: model)
                    } else {
                        HStack {
                            Label(model.signedIn ? "Firefox Account подключён" : "Вход в Firefox Account", systemImage: "person.crop.circle")
                            Spacer()
                            if model.signedIn {
                                Button("Выйти") { model.signOut() }.disabled(model.phase != .idle)
                            } else {
                                Button("Войти…") { model.showLogin = true }.disabled(model.phase != .idle)
                            }
                        }
                        Divider()
                        HStack {
                            Text("Страна")
                            Spacer()
                            if model.countries.isEmpty {
                                Text("Загрузка списка…").foregroundStyle(.secondary)
                            } else {
                                Picker("Страна", selection: $model.countryCode) {
                                    ForEach(model.countries) { country in
                                        Text("\(country.name) (\(country.code))").tag(country.code)
                                    }
                                }.labelsHidden().frame(maxWidth: 250).disabled(model.phase != .idle)
                            }
                        }
                        if let error = model.directoryError {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("Загрузить страны ещё раз") { Task { await model.loadCountries() } }
                        }
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Маршрутизация")
                            Text(model.routingSummary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Настроить…") { model.showRouting = true }
                    }
                }.padding(10)
            }

            TrafficView(model: model)

            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                if model.phase == .idle { model.connect() } else { model.disconnect() }
            } label: {
                Text(model.phase == .idle ? "Подключить VPN" : model.phase == .starting ? "Отменить" : "Отключить VPN")
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).tint(model.phase == .connected ? .red : .orange)
            .disabled(model.phase == .stopping || (model.phase == .idle && !model.canConnect))
            .keyboardShortcut(.defaultAction)

            Text(model.transportSummary)
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Text("Закрытие окна оставляет VPN в строке меню.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Диагностика") { model.showDiagnostics.toggle() }.buttonStyle(.link)
            }
            if model.showDiagnostics {
                ScrollView {
                    Text(model.logs.isEmpty ? "Диагностика появится при подключении." : model.logs.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 160)
            }
        }
        .padding(28).frame(minWidth: 500, maxWidth: 680)
        .task { await model.loadCountries() }
        .sheet(isPresented: $model.showLogin) {
            FirefoxLoginView(onSession: model.acceptSession, onCancel: { model.showLogin = false })
                .frame(minWidth: 560, minHeight: 680)
        }
        .sheet(isPresented: $model.showRouting) { RoutingSettingsView(model: model) }
    }
}

struct TrafficView: View {
    @ObservedObject var model: AppModel

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func speed(_ value: Double) -> String {
        Self.bytes(UInt64(max(0, value))) + "/с"
    }

    private var subtitle: String {
        if model.phase == .connected {
            return model.trafficAvailable ? "Текущее подключение" : "Счётчики временно недоступны"
        }
        if model.phase == .starting { return "Ожидание туннеля…" }
        return model.traffic.session.total > 0 ? "Последнее подключение" : "Счётчик начнётся после подключения"
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Трафик VPN").font(.headline)
                    Spacer()
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    metric("Получено", icon: "arrow.down", value: model.traffic.session.received,
                        rate: model.receivedPerSecond)
                    Divider()
                    metric("Отправлено", icon: "arrow.up", value: model.traffic.session.sent,
                        rate: model.sentPerSecond)
                }.fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text("Всего с начала учёта").foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.bytes(model.traffic.lifetime.total)).fontWeight(.medium).monospacedDigit()
                }.font(.callout)
            }.padding(10)
        }
    }

    private func metric(_ title: String, icon: String, value: UInt64, rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(Self.bytes(value)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(speed(rate)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
