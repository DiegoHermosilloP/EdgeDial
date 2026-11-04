import Foundation

// MARK: - MultitouchSupport.framework bindings
//
// Apple's MultitouchSupport is a private framework, so there is no header for
// it. The struct layout and function signatures below have been stable since
// roughly OS X 10.5 and are what every trackpad utility on macOS uses. We load
// it with dlopen/dlsym rather than linking it, so a future macOS that moves or
// removes the framework makes EdgeDial degrade gracefully instead of failing to
// launch at all.

struct MTPoint {
    var x: Float
    var y: Float
}

struct MTReadout {
    var position: MTPoint
    var velocity: MTPoint
}

/// One finger in one frame of trackpad data. 96 bytes; see `MultitouchDevice.verifyLayout()`.
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    /// 1 = starting, 2 = hover, 3 = making contact, 4 = touching,
    /// 5 = breaking contact, 6 = lingering, 7 = out of range.
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    /// Position and velocity in 0...1, origin at the bottom-left of the trackpad.
    var normalized: MTReadout
    var size: Float
    var pressure: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    /// Position and velocity in millimetres.
    var absolute: MTReadout
    // Two reserved ints; kept as separate fields because a tuple would make
    // the struct non-C-representable and the callback below needs it to be.
    var reserved0: Int32
    var reserved1: Int32
    var density: Float
}

typealias MTDeviceRef = UnsafeMutableRawPointer
/// Swift will not accept a pointer-to-Swift-struct parameter in a
/// `@convention(c)` signature, so the touch array arrives as a raw pointer and
/// is bound to `MTTouch` inside the callback.
typealias MTContactCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

private typealias MTDeviceCreateDefaultFn = @convention(c) () -> MTDeviceRef?
private typealias MTDeviceCreateListFn = @convention(c) () -> CFArray?
private typealias MTRegisterContactFrameCallbackFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
private typealias MTUnregisterContactFrameCallbackFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (MTDeviceRef, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (MTDeviceRef) -> Void
private typealias MTDeviceIsRunningFn = @convention(c) (MTDeviceRef) -> Bool

/// A frame of touches, already filtered down to fingers actually on the surface.
struct TouchFrame {
    var touches: [MTTouch]
    var timestamp: Double
}

enum MultitouchError: LocalizedError {
    case frameworkMissing
    case symbolsMissing(String)
    case noDevice

    var errorDescription: String? {
        switch self {
        case .frameworkMissing:
            return "MultitouchSupport.framework could not be loaded."
        case .symbolsMissing(let name):
            return "MultitouchSupport is missing the symbol \(name)."
        case .noDevice:
            return "No multitouch device found. Is this a Mac with a trackpad?"
        }
    }
}

/// Wraps a single multitouch device and streams frames of touches.
final class MultitouchDevice {
    /// The callback is a plain C function pointer with no user-info parameter,
    /// so the active instance has to be reachable statically.
    private static weak var active: MultitouchDevice?

    private let handle: UnsafeMutableRawPointer
    private let device: MTDeviceRef
    private let registerCallback: MTRegisterContactFrameCallbackFn
    private let unregisterCallback: MTUnregisterContactFrameCallbackFn
    private let startDevice: MTDeviceStartFn
    private let stopDevice: MTDeviceStopFn

    private(set) var isRunning = false

    /// Called on the multitouch thread, *not* the main thread.
    var onFrame: ((TouchFrame) -> Void)?

    static func verifyLayout() -> Bool {
        MemoryLayout<MTTouch>.size == 96
    }

    init() throws {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else {
            throw MultitouchError.frameworkMissing
        }
        self.handle = handle

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else {
                throw MultitouchError.symbolsMissing(name)
            }
            return unsafeBitCast(raw, to: type)
        }

        self.registerCallback = try symbol(
            "MTRegisterContactFrameCallback", as: MTRegisterContactFrameCallbackFn.self)
        self.unregisterCallback = try symbol(
            "MTUnregisterContactFrameCallback", as: MTUnregisterContactFrameCallbackFn.self)
        self.startDevice = try symbol("MTDeviceStart", as: MTDeviceStartFn.self)
        self.stopDevice = try symbol("MTDeviceStop", as: MTDeviceStopFn.self)

        // Prefer the device list: on machines with both a trackpad and a Magic
        // Mouse, CreateDefault does not always pick the built-in trackpad.
        var resolved: MTDeviceRef?
        if let createList = dlsym(handle, "MTDeviceCreateList") {
            let fn = unsafeBitCast(createList, to: MTDeviceCreateListFn.self)
            if let list = fn() as [AnyObject]?, let first = list.first {
                resolved = Unmanaged.passUnretained(first).toOpaque()
            }
        }
        if resolved == nil, let createDefault = dlsym(handle, "MTDeviceCreateDefault") {
            let fn = unsafeBitCast(createDefault, to: MTDeviceCreateDefaultFn.self)
            resolved = fn()
        }
        guard let device = resolved else { throw MultitouchError.noDevice }
        self.device = device
    }

    func start() {
        guard !isRunning else { return }
        MultitouchDevice.active = self
        registerCallback(device, MultitouchDevice.frameCallback)
        startDevice(device, 0)
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        stopDevice(device)
        unregisterCallback(device, MultitouchDevice.frameCallback)
        if MultitouchDevice.active === self { MultitouchDevice.active = nil }
        isRunning = false
    }

    /// Re-arms the device after a wake from sleep, where the stream can die silently.
    func restart() {
        stop()
        start()
    }

    private static let frameCallback: MTContactCallback = { _, data, count, timestamp, _ in
        guard let instance = MultitouchDevice.active, let data, count >= 0 else { return 0 }
        let fingers = data.assumingMemoryBound(to: MTTouch.self)
        var touches: [MTTouch] = []
        touches.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let touch = fingers[index]
            // States 3 (making contact) and 4 (touching) mean a finger is
            // genuinely on the glass. Hover and lift states are noise here.
            if touch.state == 3 || touch.state == 4 {
                touches.append(touch)
            }
        }
        instance.onFrame?(TouchFrame(touches: touches, timestamp: timestamp))
        return 0
    }

    deinit {
        stop()
        dlclose(handle)
    }
}
