import Foundation
import CoreLocation
import Combine

/// GPS位置情報とコンパス方位をリアルタイムに取得するマネージャー
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var location: CLLocation?
    /// コンパス方位角（度, 0=北, 時計回り）。trueHeadingが取れない場合はmagneticHeadingを使用
    @Published var heading: Double = 0

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 2        // 2m以上移動したら更新
        manager.headingFilter = 2         // 2度以上変化したら更新
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        location = loc
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // trueHeading は磁気偏差補正済み（GPS有効時のみ正確）
        if newHeading.trueHeading >= 0 {
            heading = newHeading.trueHeading
        } else {
            heading = newHeading.magneticHeading
        }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return true
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("⚠️ LocationManager error: \(error.localizedDescription)")
    }
}

// MARK: - CLLocation bearing extension

extension CLLocation {
    /// 自分から destination への方位角（度, 0=北, 時計回り 0〜360）
    func bearing(to destination: CLLocation) -> Double {
        let lat1 = coordinate.latitude  * .pi / 180
        let lat2 = destination.coordinate.latitude  * .pi / 180
        let dLon = (destination.coordinate.longitude - coordinate.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }
}
