import SwiftUI
import UIKit

struct NinebotVehiclePairingView: View {
    @ObservedObject var connection: NinebotVehicleConnection
    let locked: Bool
    @State private var vehicleToForget: NinebotVehicle?
    @State private var confirmsRemoval = false
    @State private var copiedLogs = false

    var body: some View {
        Form {
            Section {
                Text(connection.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                vehicleRow(CWL("不自动连接"), selected: connection.garage.selected == nil) {
                    connection.selectVehicle(nil)
                }
                ForEach(connection.garage.vehicles) { vehicle in
                    vehicleRow(vehicle.name, selected: vehicle.id == connection.garage.selected?.id) {
                        connection.selectVehicle(vehicle.id)
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button(CWL("删除"), role: .destructive) {
                            vehicleToForget = vehicle
                            confirmsRemoval = true
                        }
                    }
                }
            } header: {
                Text(CWL("已配对车辆"))
            } footer: {
                if locked { Text(CWL("停止投屏后可添加或更换车辆。")) }
            }
            .disabled(locked || !connection.canChooseVehicle)

            if !locked {
                Section {
                    if connection.canBeginPairing {
                        Button(CWL("建立本机配对")) { connection.beginPairing() }
                    }
                    if connection.canClearStaleKey {
                        Button(CWL("清除残留配对密钥并重配"), role: .destructive) {
                            connection.clearStaleKey()
                        }
                    }
                    if connection.isPairing {
                        Button(connection.isScanning ? CWL("停止扫描") : CWL("取消配对")) { connection.cancelPairing() }
                    } else {
                        Button(CWL("扫描附近车辆")) { connection.startScan() }
                            .disabled(!connection.canScan)
                    }
                    if connection.canScan {
                        ForEach(connection.devices) { device in
                            Button {
                                connection.connectForPairing(device)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                    Text(device.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!device.isConnectable)
                        }
                    }
                } header: {
                    Text(CWL("添加车辆"))
                } footer: {
                    Text(CWL("通电后扫描并选择自己的车辆。建立本机配对时，按车上的 P 键确认。"))
                }
            }

            if !connection.debugLogs.isEmpty {
                Section {
                    Button(copiedLogs ? CWL("已复制蓝牙日志") : CWL("复制蓝牙日志")) {
                        UIPasteboard.general.string = connection.debugLogs.joined(separator: "\n")
                        copiedLogs = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLogs = false }
                    }
                    Text(connection.debugLogs.suffix(12).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text(CWL("蓝牙诊断日志"))
                }
            }
        }
        .onDisappear { if !locked { connection.cancelPairing() } }
        .confirmationDialog(CWL("删除本机配对记录？"), isPresented: $confirmsRemoval, titleVisibility: .visible,
                            presenting: vehicleToForget) { vehicle in
            Button(CWL("删除 {1}", [vehicle.name]), role: .destructive) { connection.forgetVehicle(vehicle.id) }
        }
    }

    private func vehicleRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
