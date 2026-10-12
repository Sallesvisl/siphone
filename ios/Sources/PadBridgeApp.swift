import SwiftUI
import AVFoundation
import AudioToolbox
import CoreAudioKit
import Network
import UIKit

@main
struct PadBridgeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

// Experimental transport. One outstanding packet bounds application-side
// buffering. Allocation in the tap must be replaced before production use.
final class USBStream {
    private let queue = DispatchQueue(label: "PadBridge.transport", qos: .userInteractive)
    private let slot = DispatchSemaphore(value: 1)
    private var listener: NWListener?
    private var client: NWConnection?
    var report: ((String) -> Void)?

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 24680)
        let server = try NWListener(using: parameters)
        server.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.report?(error.localizedDescription) }
            if case .ready = state { self?.report?("Aguardando receptor pelo cabo") }
        }
        server.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            guard self.client == nil else { connection.cancel(); return }
            self.client = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self, let connection = connection else { return }
                switch state {
                case .ready: self.report?("Receptor conectado")
                case .failed, .cancelled:
                    if self.client === connection { self.client = nil }
                    self.report?("Receptor desconectado")
                default: break
                }
            }
            connection.start(queue: self.queue)
            // Detect a receiver closing even when no audio is being produced.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                connection.cancel()
            }
        }
        listener = server
        server.start(queue: queue)
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        guard slot.wait(timeout: .now()) == .success else { return }
        guard let channels = buffer.floatChannelData,
              !buffer.format.isInterleaved,
              buffer.format.channelCount >= 1,
              buffer.frameLength > 0, buffer.frameLength <= 8192 else {
            slot.signal(); return
        }
        let count = Int(buffer.frameLength)
        var packet = Data("PDB1".utf8)
        var rate = UInt32(buffer.format.sampleRate).littleEndian
        var frames = UInt32(count).littleEndian
        withUnsafeBytes(of: &rate) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &frames) { packet.append(contentsOf: $0) }
        var stereo = [Float](repeating: 0, count: count * 2)
        let right = buffer.format.channelCount > 1 ? 1 : 0
        for i in 0..<count { stereo[i * 2] = channels[0][i]; stereo[i * 2 + 1] = channels[right][i] }
        stereo.withUnsafeBytes { packet.append(contentsOf: $0) }
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let client = self.client, client.state == .ready else {
                self.slot.signal(); return
            }
            client.send(content: packet, completion: .contentProcessed { error in
                if error != nil { client.cancel() }
                self.slot.signal()
            })
        }
    }
}

final class AudioHost: ObservableObject {
    @Published var instruments: [AVAudioUnitComponent] = []
    @Published var status = "Selecione o PadLab instalado neste iPhone"
    @Published var transportStatus = "Inicializando conexão"
    @Published var editor: UIViewController?
    @Published var loading = false
    @Published var discovery = "Buscando extensões…"
    @Published var diagnostics = ""
    private var observers: [NSObjectProtocol] = []
    private let engine = AVAudioEngine()
    private let bridge = AVAudioMixerNode()
    private let stream = USBStream()
    private var unit: AVAudioUnit?
    private var tapped = false

    init() {
        engine.attach(bridge)
        stream.report = { [weak self] message in
            DispatchQueue.main.async { self?.transportStatus = message }
        }
        do { try stream.start() } catch { transportStatus = error.localizedDescription }
        scan()
        for notification in [AVAudioUnitComponentManager.registrationsChangedNotification,
                             UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: notification,
                object: nil, queue: .main) { [weak self] _ in self?.scan() })
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                guard let self = self, self.unit != nil, !self.loading else { return }
                self.engine.stop()
                self.status = "Rota de áudio alterada. Carregue o instrumento novamente."
            }
    }

    func scan() {
        // Wildcards include effects and MIDI processors for diagnostics too.
        // The first build only searched aumu/augn and exposed Apple's AUv2 units.
        let all = AVAudioUnitComponentManager.shared().components(matching:
            AudioComponentDescription(componentType: 0, componentSubType: 0,
                componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let external = all.filter { $0.audioComponentDescription.componentManufacturer != kAudioUnitManufacturer_Apple }
        let playable: Set<OSType> = [kAudioUnitType_MusicDevice, kAudioUnitType_Generator,
                                     kAudioUnitType_MusicEffect, kAudioUnitType_Effect]
        instruments = external.filter { playable.contains($0.audioComponentDescription.componentType) }
        discovery = external.isEmpty
            ? "O iOS não retornou nenhuma extensão de terceiros."
            : "\(external.count) extensões de terceiros • \(instruments.count) com saída de áudio"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        diagnostics = "PadBridge \(version) | iOS \(UIDevice.current.systemVersion)\n"
            + "Permissão no perfil: \(Self.profileAudioPermission())\n"
            + "Busca: todas as categorias\nTotal: \(all.count) | Terceiros: \(external.count)\n\n"
            + all.map { item in
                let d = item.audioComponentDescription
                return "\(item.name) | \(item.manufacturerName) | \(Self.code(d.componentType)) / \(Self.code(d.componentSubType)) | flags \(d.componentFlags)"
            }.joined(separator: "\n")
    }

    private static func code(_ value: OSType) -> String {
        String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                       UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "\(value)"
    }

    // Inspect only this boolean. Never display the profile's account/device IDs.
    // A profile authorizes entitlements; it does not prove the signer kept them.
    private static func profileAudioPermission() -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let dict = plist as? [String: Any],
              let entitlements = dict["Entitlements"] as? [String: Any] else {
            return "não foi possível ler (inconclusivo)"
        }
        return (entitlements["inter-app-audio"] as? Bool == true)
            ? "inter-app-audio autorizado; assinatura final ainda precisa preservar a permissão"
            : "inter-app-audio NÃO autorizado pelo perfil"
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func load(_ component: AVAudioUnitComponent) {
        loading = true
        status = "Carregando \(component.name)…"
        engine.stop()
        if tapped { bridge.removeTap(onBus: 0); tapped = false }
        if let old = unit { engine.detach(old); unit = nil }
        editor = nil
        AVAudioUnit.instantiate(with: component.audioComponentDescription, options: []) { [weak self] au, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                defer { self.loading = false }
                guard let au = au else {
                    self.status = error?.localizedDescription ?? "Não foi possível carregar o AUv3"
                    return
                }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default)
                    try session.setPreferredSampleRate(48000)
                    try session.setPreferredIOBufferDuration(128.0 / 48000.0)
                    try session.setActive(true)
                    self.unit = au
                    self.engine.attach(au)
                    let format = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: 2)!
                    self.engine.connect(au, to: self.bridge, format: format)
                    self.engine.connect(self.bridge, to: self.engine.mainMixerNode, format: format)
                    // Keep the engine rendering, without playing a duplicate on the phone.
                    self.engine.mainMixerNode.outputVolume = 0
                    self.bridge.installTap(onBus: 0, bufferSize: 128, format: format) { [weak self] buffer, _ in
                        self?.stream.submit(buffer)
                    }
                    self.tapped = true
                    self.engine.prepare()
                    try self.engine.start()
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.status = "\(component.name) • \(Int(session.sampleRate)) Hz • buffer solicitado: 128"
                    au.auAudioUnit.requestViewController { controller in
                        DispatchQueue.main.async {
                            guard self.unit === au else { return }
                            self.editor = controller
                            if controller == nil { self.status = "\(component.name) não forneceu uma interface. Veja o diagnóstico." }
                        }
                    }
                } catch { self.status = error.localizedDescription }
            }
        }
    }
}

struct InstrumentEditor: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct ContentView: View {
    @StateObject private var host = AudioHost()
    @State private var showDiagnostics = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PadBridge").font(.largeTitle.bold())
            Text("Protótipo 0.3 • áudio por USB para o REAPER").foregroundStyle(.secondary)
            Text(host.transportStatus).font(.callout)
            HStack {
                Menu("Selecionar instrumento") {
                    ForEach(Array(host.instruments.enumerated()), id: \.offset) { _, item in
                        Button(item.name) { host.load(item) }
                    }
                }.disabled(host.loading || host.instruments.isEmpty)
                Spacer()
                Button("Atualizar") { host.scan() }.disabled(host.loading)
            }
            Text(host.status).font(.caption)
            Text(host.discovery).font(.callout)
            if host.instruments.isEmpty {
                Text("PadLab ausente? Abra o PadLab, volte aqui e atualize. Se continuar ausente, compartilhe o diagnóstico para investigar.")
                    .font(.callout)
            }
            Button("Ver diagnóstico") { showDiagnostics = true }
            if let editor = host.editor { InstrumentEditor(controller: editor).id(ObjectIdentifier(editor)) }
            else { Spacer() }
            Text("Mantenha este app aberto durante o teste. Latência ainda não medida.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                ScrollView {
                    Text(host.diagnostics).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }.navigationTitle("Diagnóstico AUv3")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fechar") { showDiagnostics = false } }
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: host.diagnostics) }
                }
            }
        }
    }
}

