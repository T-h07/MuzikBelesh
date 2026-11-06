import SwiftUI

struct ResourceDiagnosticsView: View {
    @ObservedObject var monitor: ResourceMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power and Thermal State").font(.headline)
            LabeledContent("Thermal state", value: monitor.policy.thermalLabel)
            LabeledContent("Low Power Mode", value: monitor.policy.lowPower ? "On" : "Off")
            if monitor.policy.defersNewWork {
                Text("New download work waits until the device cools.").font(.caption)
            }
        }.foregroundStyle(.white)
    }
}
