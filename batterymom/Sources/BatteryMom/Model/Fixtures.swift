import Foundation

// Заготовленные выводы утилит для `--selftest` (сняты с настоящего Mac и сокращены).

enum Fixtures {
    static let top = """
    Processes: 936 total, 4 running, 932 sleeping, 4677 threads
    2026/11/26 16:26:09
    Load Avg: 3.66, 3.78, 4.03

    PID    COMMAND          POWER
    462    WindowServer     0.0
    10441  Google Chrome    0.0
    Processes: 936 total, 4 running, 932 sleeping, 4677 threads
    2026/11/26 16:26:10
    Load Avg: 3.66, 3.78, 4.03
    CPU usage: 11.54% user, 4.60% sys, 83.84% idle
    Networks: packets: 9934420/11G in, 6356403/1196M out.

    PID    COMMAND          POWER
    462    WindowServer     45.6
    10441  Google Chrome    8.9
    9940   Яндекс М\u{FFFD} 8.6
    12609  Google Chrome He 0.6
    389    logd             0.4
    573    com.apple.Stream 0.0

    """

    static let ioreg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <array>
        <dict>
            <key>BatteryPercent</key><integer>81</integer>
            <key>BatteryStatusFlags</key><integer>3</integer>
            <key>DeviceAddress</key><string>f0-b3-ec-11-22-33</string>
            <key>IOClass</key><string>AppleDeviceManagementHIDEventService</string>
            <key>Product</key><string>Magic Keyboard</string>
            <key>Transport</key><string>Bluetooth</string>
        </dict>
        <dict>
            <key>BatteryPercent</key><integer>81</integer>
            <key>BatteryStatusFlags</key><integer>3</integer>
            <key>DeviceAddress</key><string>f0-b3-ec-11-22-33</string>
            <key>IOClass</key><string>AppleDeviceManagementHIDEventService</string>
            <key>Product</key><string>Magic Keyboard</string>
        </dict>
        <dict>
            <key>BatteryPercent</key><integer>9</integer>
            <key>BatteryStatusFlags</key><integer>0</integer>
            <key>DeviceAddress</key><string>a4-83-e7-44-55-66</string>
            <key>Product</key><string>Magic Mouse</string>
        </dict>
    </array>
    </plist>
    """

    static let profiler = """
    {
      "SPBluetoothDataType" : [
        {
          "controller_properties" : { "controller_state" : "attrib_on" },
          "device_connected" : [
            { "AirPods" : {
                "device_address" : "88:10:32:0E:A8:29",
                "device_batteryLevelCase" : "68 %",
                "device_batteryLevelLeft" : "7 %",
                "device_batteryLevelRight" : "10 %",
                "device_minorType" : "Headphones" } },
            { "Magic Keyboard" : {
                "device_address" : "F0:B3:EC:11:22:33",
                "device_batteryLevelMain" : "81 %",
                "device_minorType" : "Keyboard" } }
          ],
          "device_not_connected" : [
            { "Max AP" : {
                "device_address" : "08:FF:44:11:F4:14",
                "device_batteryLevelMain" : "40 %",
                "device_minorType" : "Headphones" } },
            { "JBL Flip 5" : { "device_address" : "D8:37:3B:7D:34:FD", "device_minorType" : "Speaker" } }
          ]
        }
      ]
    }
    """
}
