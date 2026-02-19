import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid
import SwiftUI

private struct RuntimeOptions {
    var requestAccessibility = false
    var debugInput = false
    var showHelp = false

    static func parse(arguments: [String]) -> RuntimeOptions {
        var options = RuntimeOptions()

        for arg in arguments {
            switch arg {
            case "--request-accessibility":
                options.requestAccessibility = true
            case "--debug-input":
                options.debugInput = true
            case "-h", "--help":
                options.showHelp = true
            default:
                break
            }
        }

        return options
    }

    static func printUsage() {
        let text = """
        PowerMateScroll.app

        Options:
          --request-accessibility  Request Accessibility permission prompt and exit
          --debug-input            Log raw HID input values to stderr
          -h, --help               Show this help
        """
        print(text)
    }
}

private struct ScrollConfig: Equatable {
    var sensitivity: Double
    var acceleration: Double
    var velocityReference: Double
    var maxBoost: Double
    var invert: Bool

    static let `default` = ScrollConfig(
        sensitivity: 1.6,
        acceleration: 0.55,
        velocityReference: 24,
        maxBoost: 2.0,
        invert: false
    )
}


@MainActor
private final class SettingsStore: ObservableObject {
    private enum Key {
        static let sensitivity = "sensitivity"
        static let acceleration = "acceleration"
        static let velocityReference = "velocityReference"
        static let maxBoost = "maxBoost"
        static let invert = "invert"
    }

    private let defaults: UserDefaults
    var onChange: ((ScrollConfig) -> Void)?

    @Published var sensitivity: Double {
        didSet {
            let clamped = min(max(sensitivity, 0.2), 8.0)
            if clamped != sensitivity {
                sensitivity = clamped
                return
            }
            defaults.set(clamped, forKey: Key.sensitivity)
            onChange?(config)
        }
    }

    @Published var acceleration: Double {
        didSet {
            let clamped = min(max(acceleration, 0.0), 1.5)
            if clamped != acceleration {
                acceleration = clamped
                return
            }
            defaults.set(clamped, forKey: Key.acceleration)
            onChange?(config)
        }
    }

    @Published var velocityReference: Double {
        didSet {
            let clamped = min(max(velocityReference, 5.0), 60.0)
            if clamped != velocityReference {
                velocityReference = clamped
                return
            }
            defaults.set(clamped, forKey: Key.velocityReference)
            onChange?(config)
        }
    }

    @Published var maxBoost: Double {
        didSet {
            let clamped = min(max(maxBoost, 0.0), 8.0)
            if clamped != maxBoost {
                maxBoost = clamped
                return
            }
            defaults.set(clamped, forKey: Key.maxBoost)
            onChange?(config)
        }
    }

    @Published var invert: Bool {
        didSet {
            defaults.set(invert, forKey: Key.invert)
            onChange?(config)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let fallback = ScrollConfig.default

        sensitivity = defaults.object(forKey: Key.sensitivity) as? Double ?? fallback.sensitivity
        acceleration = defaults.object(forKey: Key.acceleration) as? Double ?? fallback.acceleration
        velocityReference = defaults.object(forKey: Key.velocityReference) as? Double ?? fallback.velocityReference
        maxBoost = defaults.object(forKey: Key.maxBoost) as? Double ?? fallback.maxBoost
        invert = defaults.object(forKey: Key.invert) as? Bool ?? fallback.invert
    }

    var config: ScrollConfig {
        ScrollConfig(
            sensitivity: sensitivity,
            acceleration: acceleration,
            velocityReference: velocityReference,
            maxBoost: maxBoost,
            invert: invert
        )
    }

}

private enum AccessibilityController {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

private enum LaunchAgentController {
    static let label = "io.github.byronhsu.powermate-scroll"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static var domain: String {
        "gui/\(getuid())"
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool, executablePath: String) throws {
        if enabled {
            try writePlist(executablePath: executablePath)
            _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
            let bootstrapResult = runLaunchctl(["bootstrap", domain, plistURL.path])
            guard bootstrapResult.status == 0 else {
                throw NSError(domain: label, code: Int(bootstrapResult.status), userInfo: [
                    NSLocalizedDescriptionKey: bootstrapResult.output.isEmpty ? "launchctl bootstrap failed" : bootstrapResult.output,
                ])
            }
            _ = runLaunchctl(["kickstart", "-k", "\(domain)/\(label)"])
        } else {
            _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func writePlist(executablePath: String) throws {
        let agentDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let home = NSHomeDirectory()
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": "\(home)/Library/Logs/powermate-scroll.out.log",
            "StandardErrorPath": "\(home)/Library/Logs/powermate-scroll.err.log",
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardError = outputPipe
        process.standardOutput = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (1, error.localizedDescription)
        }
    }
}

private final class PowerMateEngine {
    private final class HIDThread: Thread {
        private let readySemaphore: DispatchSemaphore
        private let runLoopReady: (CFRunLoop) -> Void
        private var keepAlivePort: Port?

        init(readySemaphore: DispatchSemaphore, runLoopReady: @escaping (CFRunLoop) -> Void) {
            self.readySemaphore = readySemaphore
            self.runLoopReady = runLoopReady
            super.init()
            qualityOfService = .userInteractive
            name = "PowerMateHIDThread"
        }

        override func main() {
            autoreleasepool {
                _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
                guard let runLoop = CFRunLoopGetCurrent() else {
                    readySemaphore.signal()
                    return
                }
                let port = Port()
                keepAlivePort = port
                RunLoop.current.add(port, forMode: .default)
                runLoopReady(runLoop)
                readySemaphore.signal()

                while !isCancelled {
                    _ = RunLoop.current.run(mode: .default, before: .distantFuture)
                }
            }
        }
    }

    private struct ReportRegistration {
        let buffer: UnsafeMutablePointer<UInt8>
        let length: CFIndex
    }

    private let debugInput: Bool
    private let configLock = NSLock()
    private let lifecycleLock = NSLock()
    private var currentConfig: ScrollConfig
    private var hidThread: HIDThread?
    private var hidRunLoop: CFRunLoop?
    private var manager: IOHIDManager?
    private var source: CGEventSource?
    private var reportRegistrations: [UInt: ReportRegistration] = [:]
    private var lastEventTimeByDevice: [UInt: UInt64] = [:]

    init(initialConfig: ScrollConfig, debugInput: Bool) {
        self.debugInput = debugInput
        self.currentConfig = initialConfig
        self.source = CGEventSource(stateID: .hidSystemState)
        self.source?.localEventsSuppressionInterval = 0
    }

    deinit {
        stop()
    }

    func updateConfig(_ config: ScrollConfig) {
        configLock.lock()
        currentConfig = config
        configLock.unlock()
    }

    private func configSnapshot() -> ScrollConfig {
        configLock.lock()
        let config = currentConfig
        configLock.unlock()
        return config
    }

    func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard hidThread == nil else {
            return
        }

        let readySemaphore = DispatchSemaphore(value: 0)
        let thread = HIDThread(readySemaphore: readySemaphore) { [weak self] runLoop in
            self?.hidRunLoop = runLoop
        }
        hidThread = thread
        thread.start()
        readySemaphore.wait()

        guard let runLoop = hidRunLoop else {
            hidThread = nil
            return
        }

        performOnHIDRunLoop(runLoop, wait: true) { [weak self] in
            self?.setupManagerOnCurrentThread()
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard let runLoop = hidRunLoop else {
            hidThread = nil
            return
        }

        performOnHIDRunLoop(runLoop, wait: true) { [weak self] in
            self?.teardownManagerOnCurrentThread()
        }

        performOnHIDRunLoop(runLoop, wait: true) {
            CFRunLoopStop(runLoop)
        }

        hidThread?.cancel()
        hidThread = nil
        hidRunLoop = nil
    }

    private func performOnHIDRunLoop(_ runLoop: CFRunLoop, wait: Bool, block: @escaping () -> Void) {
        if CFRunLoopGetCurrent() == runLoop {
            block()
            return
        }

        if wait {
            let semaphore = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                block()
                semaphore.signal()
            }
            CFRunLoopWakeUp(runLoop)
            semaphore.wait()
        } else {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func setupManagerOnCurrentThread() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [[String: Int]] = [
            [kIOHIDVendorIDKey: 0x077d, kIOHIDProductIDKey: 0x0410],
            [kIOHIDVendorIDKey: 0x077d, kIOHIDProductIDKey: 0x04aa],
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                let engine = Unmanaged<PowerMateEngine>.fromOpaque(context).takeUnretainedValue()
                engine.registerInputReportCallback(for: device)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                let engine = Unmanaged<PowerMateEngine>.fromOpaque(context).takeUnretainedValue()
                engine.unregisterInputReportCallback(for: device)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDManagerRegisterInputValueCallback(
            manager,
            { context, _, _, value in
                guard let context else { return }
                let engine = Unmanaged<PowerMateEngine>.fromOpaque(context).takeUnretainedValue()
                engine.handleInputValue(value)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard status == kIOReturnSuccess else {
            fputs("Failed to open IOHIDManager: \(status)\n", stderr)
            self.manager = nil
            return
        }

        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices {
                registerInputReportCallback(for: device)
            }
        }
    }

    private func teardownManagerOnCurrentThread() {
        guard let manager else {
            return
        }

        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices {
                unregisterInputReportCallback(for: device)
            }
        }

        for registration in reportRegistrations.values {
            registration.buffer.deinitialize(count: Int(registration.length))
            registration.buffer.deallocate()
        }

        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        reportRegistrations.removeAll()
        lastEventTimeByDevice.removeAll()
    }

    private func registerInputReportCallback(for device: IOHIDDevice) {
        let key = deviceKey(for: device)
        if reportRegistrations[key] != nil {
            return
        }

        let sizeObject = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString)
        let size = (sizeObject as? NSNumber)?.intValue ?? 0
        guard size >= 2 else {
            return
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        reportRegistrations[key] = ReportRegistration(buffer: buffer, length: CFIndex(size))

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            CFIndex(size),
            { context, _, sender, reportType, _, report, reportLength in
                guard let context else { return }
                let engine = Unmanaged<PowerMateEngine>.fromOpaque(context).takeUnretainedValue()
                engine.handleInputReport(sender: sender, reportType: reportType, report: report, reportLength: reportLength)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        if debugInput {
            fputs("Registered input report callback device=\(key) size=\(size)\n", stderr)
        }
    }

    private func unregisterInputReportCallback(for device: IOHIDDevice) {
        let key = deviceKey(for: device)
        guard let registration = reportRegistrations.removeValue(forKey: key) else {
            return
        }

        registration.buffer.deinitialize(count: Int(registration.length))
        registration.buffer.deallocate()
    }

    private func handleInputReport(
        sender: UnsafeMutableRawPointer?,
        reportType: IOHIDReportType,
        report: UnsafeMutablePointer<UInt8>?,
        reportLength: CFIndex
    ) {
        guard reportType == kIOHIDReportTypeInput, let report, reportLength >= 2 else {
            return
        }

        // Griffin PowerMate: byte 1 is signed axis value for usage 0x33.
        let axis = Int8(bitPattern: report[1])
        let delta = CFIndex(axis)

        if debugInput {
            let senderText = sender.map { String(UInt(bitPattern: $0)) } ?? "unknown"
            fputs("HID report sender=\(senderText) axis=\(delta)\n", stderr)
        }

        let key = sender.map { UInt(bitPattern: $0) } ?? 0
        handleRotationDelta(delta, deviceKey: key)
    }

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let raw = IOHIDValueGetIntegerValue(value)

        guard usagePage == UInt32(kHIDPage_GenericDesktop), usage == UInt32(kHIDUsage_GD_Rx) else {
            return
        }

        if debugInput {
            fputs("Fallback HID value usagePage=\(usagePage) usage=\(usage) value=\(raw)\n", stderr)
        }

        handleRotationDelta(raw, deviceKey: deviceKey(for: element))
    }

    private func handleRotationDelta(_ delta: CFIndex, deviceKey: UInt) {
        guard delta != 0 else { return }

        let config = configSnapshot()
        let now = DispatchTime.now().uptimeNanoseconds
        let previous = lastEventTimeByDevice[deviceKey] ?? now
        lastEventTimeByDevice[deviceKey] = now

        let dt = max(Double(now &- previous) / 1_000_000_000.0, 0.000_5)
        let scroll = scaledScrollDelta(from: delta, dt: dt, config: config)
        guard scroll != 0 else { return }

        let finalScroll = config.invert ? -scroll : scroll
        postScroll(vertical: finalScroll)
    }

    private func scaledScrollDelta(from delta: CFIndex, dt: Double, config: ScrollConfig) -> Int32 {
        let magnitude = Double(Swift.abs(delta))
        guard magnitude > 0 else { return 0 }

        let velocity = magnitude / dt
        let gain = 1.0 + config.acceleration * min(velocity / max(config.velocityReference, 0.001), config.maxBoost)
        let scaled = magnitude * config.sensitivity * gain

        var result = Int32(scaled.rounded(.toNearestOrAwayFromZero))
        if result == 0 {
            result = 1
        }

        return delta < 0 ? -result : result
    }

    private func postScroll(vertical: Int32) {
        guard let source else { return }

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }

        event.post(tap: .cghidEventTap)
    }

    private func deviceKey(for device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private func deviceKey(for element: IOHIDElement) -> UInt {
        let device = IOHIDElementGetDevice(element)
        return UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }
}

@MainActor
private final class AppController: ObservableObject {
    @Published var isEngineRunning = false
    @Published var statusMessage = ""
    @Published var launchAtLogin = false
    @Published var accessibilityTrusted = false

    let settings: SettingsStore

    private let engine: PowerMateEngine
    private let options: RuntimeOptions
    private var accessibilityTimer: Timer?

    init(options: RuntimeOptions) {
        self.options = options
        settings = SettingsStore()
        engine = PowerMateEngine(initialConfig: settings.config, debugInput: options.debugInput)
        settings.onChange = { [weak engine] config in
            engine?.updateConfig(config)
        }

        launchAtLogin = LaunchAgentController.isEnabled()

        if options.showHelp {
            RuntimeOptions.printUsage()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }

        if options.requestAccessibility {
            AccessibilityController.requestPrompt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.terminate(nil)
            }
            return
        }

        refreshAccessibilityStatus()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityStatus()
            }
        }

        startEngine()
    }

    deinit {
        accessibilityTimer?.invalidate()
    }

    func startEngine() {
        guard !isEngineRunning else { return }
        engine.start()
        isEngineRunning = true
    }

    func stopEngine() {
        guard isEngineRunning else { return }
        engine.stop()
        isEngineRunning = false
    }

    func setEngineEnabled(_ enabled: Bool) {
        if enabled {
            startEngine()
        } else {
            stopEngine()
        }
    }

    func restartEngine() {
        stopEngine()
        startEngine()
    }

    func requestAccessibilityPrompt() {
        AccessibilityController.requestPrompt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshAccessibilityStatus()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard let executablePath = Bundle.main.executableURL?.path else {
            statusMessage = "Could not resolve app executable path."
            launchAtLogin = LaunchAgentController.isEnabled()
            return
        }

        do {
            try LaunchAgentController.setEnabled(enabled, executablePath: executablePath)
            launchAtLogin = LaunchAgentController.isEnabled()
            statusMessage = enabled ? "Launch at login enabled" : "Launch at login disabled"
        } catch {
            launchAtLogin = LaunchAgentController.isEnabled()
            statusMessage = "Launch at login error: \(error.localizedDescription)"
        }
    }

    private func refreshAccessibilityStatus() {
        let trusted = AccessibilityController.isTrusted()
        accessibilityTrusted = trusted

        if trusted {
            if statusMessage == "Accessibility permission is required for scrolling output." || statusMessage.isEmpty {
                statusMessage = ""
            }
        } else {
            statusMessage = "Accessibility permission is required for scrolling output."
        }
    }
}

private struct SliderRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(display(value))
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .modifier(ValueChipModifier())
            }

            Slider(value: $value, in: range, step: step)
                .tint(.cyan.opacity(0.85))
        }
    }
}

private struct ValueChipModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive().tint(.cyan.opacity(0.08)), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
        }
    }
}

private struct MenuPanelView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @Namespace private var actionNamespace

    var body: some View {
        let panel = VStack(alignment: .leading, spacing: 16) {
            // MARK: Header with glass icon badge
            HStack(spacing: 10) {
                headerIconBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text("PowerMate Scroll")
                        .font(.title3.weight(.bold))
                    Text("Low-latency wheel daemon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusDot
            }

            // MARK: Slider section card
            sliderSection

            // MARK: Toggles section card
            togglesSection

            // MARK: Action bar
            actionBar
        }
        .padding(16)
        .frame(width: 390)
        .modifier(MenuPanelSurfaceModifier())

        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 18) {
                    panel
                        .glassEffect(.regular.tint(.white.opacity(0.015)), in: .rect(cornerRadius: 20))
                        .glassEffectID("panel", in: actionNamespace)
                }
            } else {
                panel
            }
        }
    }

    // MARK: - Header icon badge

    private var headerIconBadge: some View {
        Image(nsImage: Self.appIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 34, height: 34)
            .clipShape(Circle())
    }

    private static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }()

    // MARK: - Status dot with glow

    private var statusDot: some View {
        Circle()
            .fill(controller.isEngineRunning ? Color.green : Color.red)
            .frame(width: 12, height: 12)
            .shadow(color: (controller.isEngineRunning ? Color.green : Color.red).opacity(0.6), radius: 6)
    }

    // MARK: - Slider section

    @ViewBuilder
    private var sliderSection: some View {
        let sliders = VStack(alignment: .leading, spacing: 14) {
            SliderRow(
                title: "Speed",
                subtitle: "Base scroll per tick",
                value: $settings.sensitivity,
                range: 0.2 ... 8.0,
                step: 0.1,
                display: { String(format: "%.1f", $0) }
            )

            SliderRow(
                title: "Acceleration",
                subtitle: "Extra gain when spinning faster",
                value: $settings.acceleration,
                range: 0.0 ... 1.5,
                step: 0.05,
                display: { String(format: "%.2f", $0) }
            )

            SliderRow(
                title: "Velocity Ref",
                subtitle: "Lower = acceleration kicks in sooner",
                value: $settings.velocityReference,
                range: 5 ... 60,
                step: 1,
                display: { String(format: "%.0f", $0) }
            )

            SliderRow(
                title: "Max Boost",
                subtitle: "Cap on acceleration multiplier",
                value: $settings.maxBoost,
                range: 0 ... 8,
                step: 0.1,
                display: { String(format: "%.1f", $0) }
            )
        }
        .padding(12)

        if #available(macOS 26.0, *) {
            sliders
                .glassEffect(.regular.tint(.cyan.opacity(0.07)), in: .rect(cornerRadius: 12))
        } else {
            sliders
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Toggles section

    @ViewBuilder
    private var togglesSection: some View {
        let toggleContent = VStack(alignment: .leading, spacing: 10) {
            Toggle("Invert direction", isOn: $settings.invert)

            Toggle(
                "Launch At Login",
                isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                )
            )

            if !controller.statusMessage.isEmpty {
                Text(controller.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)

        if #available(macOS 26.0, *) {
            toggleContent
                .glassEffect(.regular.tint(.white.opacity(0.05)), in: .rect(cornerRadius: 12))
        } else {
            toggleContent
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                HStack {
                    Button(controller.isEngineRunning ? "Pause" : "Resume") {
                        controller.setEngineEnabled(!controller.isEngineRunning)
                    }
                    .buttonStyle(.glass)
                    .glassEffectID("toggle-engine", in: actionNamespace)

                    if !controller.accessibilityTrusted {
                        Button("Accessibility") {
                            controller.requestAccessibilityPrompt()
                        }
                        .buttonStyle(.glass)
                        .glassEffectID("accessibility", in: actionNamespace)
                    }

                    Spacer()

                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.glass)
                    .glassEffectID("quit", in: actionNamespace)
                }
            }
        } else {
            HStack {
                Button(controller.isEngineRunning ? "Pause" : "Resume") {
                    controller.setEngineEnabled(!controller.isEngineRunning)
                }
                .buttonStyle(.bordered)

                if !controller.accessibilityTrusted {
                    Button("Accessibility") {
                        controller.requestAccessibilityPrompt()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

private struct MenuPanelSurfaceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        } else {
            content
                .background(
                    ZStack {
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.25), Color.blue.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
    }
}

@main
private struct PowerMateScrollApp: App {
    @StateObject private var controller: AppController

    init() {
        let options = RuntimeOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        _controller = StateObject(wrappedValue: AppController(options: options))
    }

    var body: some Scene {
        MenuBarExtra(
            "PowerMate",
            systemImage: controller.isEngineRunning ? "arrow.up.and.down.circle.fill" : "arrow.up.and.down.circle"
        ) {
            MenuPanelView(controller: controller, settings: controller.settings)
        }
        .menuBarExtraStyle(.window)
    }
}
