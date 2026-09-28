import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - Engine (uses RouteSim's existing tunnel + keep-alive; nothing else is touched)

@MainActor
final class SpoofEngine: ObservableObject {
    @Published var latitude = 37.7749
    @Published var longitude = -122.4194
    @Published var isActive = false
    @Published var speed: Double = 2.0 // meters per second
    @Published var errorText: String?
    @Published var realCoordinate: CLLocationCoordinate2D?

    var joystickAngle = 0.0
    var joystickMagnitude = 0.0

    private var hasMoved = false
    private var frozen = false
    private var timer: Timer?
    private var tick = 0
    private var lease: DebugKeepAliveLease?
    private var cancellables = Set<AnyCancellable>()

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init() {
        DeviceLocationManager.shared.$coordinate
            .sink { [weak self] c in
                Task { @MainActor in self?.handleReal(c) }
            }
            .store(in: &cancellables)
    }

    // While spoofing, iOS reports the FAKE location to every app. So we stop
    // updating the "real" marker while active and keep the last true fix.
    private func handleReal(_ c: CLLocationCoordinate2D?) {
        guard !frozen, let c else { return }
        realCoordinate = c
        if !hasMoved && !isActive {
            latitude = c.latitude
            longitude = c.longitude
        }
    }

    func start() {
        guard timer == nil else { return }
        frozen = true
        errorText = nil
        lease = DebugKeepAliveLease() // silent audio + background task + location keep-alive
        isActive = true
        tick = 0
        push()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isActive = false
        joystickMagnitude = 0
        LocationSimulator.shared.clear() // gives real GPS back to iOS
        lease?.invalidate()
        lease = nil
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            frozen = false
        }
    }

    func teleport(to c: CLLocationCoordinate2D) {
        hasMoved = true
        latitude = c.latitude
        longitude = c.longitude
        if isActive { push() }
    }

    private func step() {
        guard isActive else { return }
        tick += 1
        let dt = 0.1
        if joystickMagnitude > 0.05 {
            hasMoved = true
            let v = speed * joystickMagnitude
            let mPerDegLat = 111_320.0
            let mPerDegLng = 111_320.0 * cos(latitude * .pi / 180)
            latitude  += sin(joystickAngle) * v * dt / mPerDegLat
            longitude += cos(joystickAngle) * v * dt / mPerDegLng
        }
        if tick % 30 == 0 { // tiny GPS-like wobble every 3s
            let mag = Double.random(in: 0.00001...0.00003)
            let ang = Double.random(in: 0...(2 * .pi))
            latitude  += cos(ang) * mag
            longitude += sin(ang) * mag
        }
        if tick % 10 == 0 { push() } // 1 update per second, like RouteSim
    }

    private func push() {
        let c = coordinate
        Task {
            let result = await LocationSimulator.shared.setLocation(c)
            switch result {
            case .success: errorText = nil
            case .failure(let e): errorText = e.errorDescription
            }
        }
    }
}

// MARK: - Screen

struct SpooferView: View {
    @StateObject private var engine = SpoofEngine()
    @StateObject private var tunnel = TunnelManager.shared

    var body: some View {
        ZStack {
            SpooferMap(engine: engine).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer()
                controls
            }
        }
        .onAppear {
            DeviceLocationManager.shared.startUpdating()
            if !tunnel.isConnected { startTunnelInBackground(showErrorUI: false) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("SPOOFER").font(.headline)
            Spacer()
            Circle().fill(tunnel.isConnected ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(tunnel.isConnected ? "Tunnel connected" : "Tunnel offline")
                .font(.caption).foregroundStyle(.secondary)
            if !tunnel.isConnected {
                Button("Connect") { startTunnelInBackground() }
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12).padding(.top, 4)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    coordRow("SPOOF", engine.latitude, engine.longitude, .blue)
                    if let r = engine.realCoordinate {
                        coordRow("REAL", r.latitude, r.longitude, .green)
                    } else {
                        Text("Locating...").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(spacing: 4) {
                    Toggle("", isOn: Binding(
                        get: { engine.isActive },
                        set: { on in
                            if on {
                                if tunnel.isConnected { engine.start() }
                                else { engine.errorText = "Tunnel offline. Turn on LocalDevVPN, then tap Connect." }
                            } else {
                                engine.stop()
                            }
                        }
                    )).labelsHidden()
                    Text(engine.isActive ? "ACTIVE" : "OFF")
                        .font(.caption2.bold())
                        .foregroundStyle(engine.isActive ? Color.green : Color.secondary)
                }
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SPEED").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $engine.speed, in: 0.5...25)
                    Text(String(format: "%.1f m/s", engine.speed)).font(.caption)
                    Text("Tap the map to teleport").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 180)
                Spacer()
                SpoofJoystick(engine: engine)
            }

            if let err = engine.errorText {
                Text(err).font(.caption2).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func coordRow(_ label: String, _ lat: Double, _ lng: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Text(String(format: "%.6f, %.6f", lat, lng))
                .font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - Map

struct SpooferMap: View {
    @ObservedObject var engine: SpoofEngine
    @State private var position: MapCameraPosition = .automatic

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(radius: 4)
    }

    private func center(on c: CLLocationCoordinate2D) {
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: c, span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)))
        }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let r = engine.realCoordinate {
                    Annotation("You", coordinate: r) { dot(.green) }
                }
                Annotation("Spoof", coordinate: engine.coordinate) { dot(.blue) }
            }
            .mapStyle(.standard(elevation: .flat))
            .onTapGesture { point in
                if let c = proxy.convert(point, from: .local) { engine.teleport(to: c) }
            }
        }
        .overlay(alignment: .trailing) {
            VStack(spacing: 10) {
                mapButton("scope", .blue) { center(on: engine.coordinate) }
                mapButton("location.fill", .green) {
                    if let r = engine.realCoordinate { center(on: r) }
                }
            }
            .padding(.trailing, 12)
        }
    }

    private func mapButton(_ symbol: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

// MARK: - Joystick

struct SpoofJoystick: View {
    @ObservedObject var engine: SpoofEngine
    @State private var thumb = CGSize.zero
    private let radius: CGFloat = 60

    var body: some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.25))
            Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1)
            Circle().fill(Color.blue).frame(width: 44, height: 44).offset(thumb)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.location.x - radius
                    let dy = v.location.y - radius
                    let dist = min(sqrt(dx * dx + dy * dy), radius)
                    let angle = atan2(dy, dx)
                    thumb = CGSize(width: cos(angle) * dist, height: sin(angle) * dist)
                    engine.joystickAngle = Double(-angle) // flip Y so up = north
                    engine.joystickMagnitude = Double(dist / radius)
                }
                .onEnded { _ in
                    thumb = .zero
                    engine.joystickMagnitude = 0
                }
        )
    }
}
