import CoreLocation
import Foundation

/// 常去的地方的地理围栏（10-01 待办）：进 / 出某个存过的地方，就报给服务器（/places/{id}/event），对得上的待办由 Lumi 来提醒。
/// 只报「进了 / 出了哪个地方」，不报位置、不记轨迹。iOS 最多同时盯 20 个；App 被杀掉也会被系统叫醒报进出（要「始终允许」定位）。
/// App 一启动就建好（SessionStore 里），这样被系统在后台叫醒时，进出事件有人接。
@MainActor
final class PlaceMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PlaceMonitor()
    static let prefix = "place-"

    var api: APIClient?
    @Published private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()
    private var hereWaiters: [CheckedContinuation<CLLocation?, Never>] = []

    private override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var always: Bool { status == .authorizedAlways }

    /// 要「始终允许」：没问过先问「使用期间」，拿到了再升级（iOS 只允许这样两步问）
    func askAlways() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// 按服务器上的地方重新盯一遍（多的停掉、缺的补上、挪了位置的换掉）
    func sync(_ places: [PlaceDTO]) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let want = Dictionary(uniqueKeysWithValues: places.prefix(20).map { ("\(Self.prefix)\($0.id)", $0) })
        for r in manager.monitoredRegions where r.identifier.hasPrefix(Self.prefix) {
            guard let p = want[r.identifier], let c = r as? CLCircularRegion,
                  c.center.latitude == p.lat, c.center.longitude == p.lon, c.radius == Double(p.radius) else {
                manager.stopMonitoring(for: r); continue
            }
        }
        let have = Set(manager.monitoredRegions.map(\.identifier))
        for (id, p) in want where !have.contains(id) {
            let r = CLCircularRegion(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                                     radius: min(Double(p.radius), manager.maximumRegionMonitoringDistance), identifier: id)
            r.notifyOnEntry = true
            r.notifyOnExit = true
            manager.startMonitoring(for: r)
        }
    }

    /// 「就是这里」：拿一次现在的位置
    func here() async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        return await withCheckedContinuation { c in
            hereWaiters.append(c)
            manager.requestLocation()
        }
    }

    /// sync = 只是对一下现在在不在（不算进出，服务器不提醒）
    private func report(_ region: CLRegion, inside: Bool, sync: Bool = false) {
        guard region.identifier.hasPrefix(Self.prefix), let id = Int(region.identifier.dropFirst(Self.prefix.count)),
              let api else { return }
        Task { try? await api.send("POST", "places/\(id)/event", json: ["inside": inside, "sync": sync]) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in self.report(region, inside: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.report(region, inside: false) }
    }

    /// 刚开始盯的时候问一次「现在在不在里面」，服务器才知道到点时人在不在那儿
    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        manager.requestState(for: region)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state != .unknown else { return }
        Task { @MainActor in self.report(region, inside: state == .inside, sync: true) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.status = s
            if s == .authorizedWhenInUse && UserDefaults.standard.bool(forKey: "placesWantAlways") {
                manager.requestAlwaysAuthorization()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in
            let w = self.hereWaiters; self.hereWaiters = []
            w.forEach { $0.resume(returning: last) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let w = self.hereWaiters; self.hereWaiters = []
            w.forEach { $0.resume(returning: nil) }
        }
    }
}
