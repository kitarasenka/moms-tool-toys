// Быстрый замер радио раз в секунду: system_profiler тратит на это ~6 с.
// Строка: <ms> <rssi dBm> <noise dBm> <rate Мбит/с> <channel>, или "<ms> -" если Wi-Fi нет.
import CoreWLAN
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let client = CWWiFiClient.shared()
while true {
  let ms = Int(Date().timeIntervalSince1970 * 1000)
  if let i = client.interface(), i.rssiValue() != 0 {
    print("\(ms) \(i.rssiValue()) \(i.noiseMeasurement()) \(Int(i.transmitRate())) \(i.wlanChannel()?.channelNumber ?? 0)")
  } else {
    print("\(ms) -")
  }
  Thread.sleep(forTimeInterval: 1)
}
