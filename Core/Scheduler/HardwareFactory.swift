import Foundation

/// Builds real readers, leaving out whatever this Mac lacks: no SMC in a VM, no battery on a desktop, no fans on an Air.
public enum HardwareFactory {
    public static func makeReaders() -> HardwareReaders {
        let smc: (any SMCReading)? = try? SMCConnection()
        let hid: (any HIDSensorReading)? = HIDSensorClient()
        let fans = smc.map { FanReader(smc: $0) }
        let battery = BatteryReader(smc: smc)
        let hasBattery = battery?.isPresent == true
        var readers = HardwareReaders(
            cpu: CPUReader(),
            memory: MemoryReader(),
            gpu: GPUReader(),
            sensors: SensorSampler(smc: smc, hid: hid),
            fans: (fans?.fanCount ?? 0) > 0 ? fans : nil,
            battery: hasBattery ? battery : nil,
            frequency: FrequencyReader()
        )
        readers.power = hasBattery ? smc.flatMap { LivePowerReader(smc: $0) } : nil
        readers.network = NetworkReader()
        readers.disk = DiskReader()
        readers.processes = ProcessReader()
        return readers
    }
}
