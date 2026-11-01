import Foundation
import ObjectiveC

public protocol NativeChargeLimitControlling: Sendable {
    /// Values macOS accepts, or empty when the feature is missing.
    func availableLimits() -> [Int]
    /// The active limit, or nil when none is set.
    func currentLimit() -> Int?
    func setLimit(_ value: Int) -> Bool
}

public enum NativeChargeLimitError: Error, Equatable, Sendable {
    case notAccepted
    case refused
    case didNotApply
}

public enum NativeChargeLimit {
    /// Sets a limit only if macOS lists it, then confirms by reading it back.
    public static func apply(_ value: Int, using control: any NativeChargeLimitControlling) -> Result<Int, NativeChargeLimitError> {
        guard control.availableLimits().contains(value) else { return .failure(.notAccepted) }
        guard control.setLimit(value) else { return .failure(.refused) }
        guard control.currentLimit() == value else { return .failure(.didNotApply) }
        return .success(value)
    }
}

/// The charge limit in System Settings, through the same private client System Settings uses. macOS stops charging at
/// the limit and runs from the adapter with the battery at 0 W, verified on Mac16,8 with macOS 27.2.
///
/// It needs no root and no helper, and goes through macOS's own service, so no SMC key is involved. Private API, so every
/// selector and its signature is checked first, and any mismatch means the control is simply not offered.
public final class NativeChargeLimitClient: NativeChargeLimitControlling, @unchecked Sendable {
    private typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject
    private typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
    private typealias SupportedFn = @convention(c) (AnyObject, Selector) -> Bool
    private typealias AvailableFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> AnyObject?
    private typealias EnabledFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt
    private typealias GetFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt8
    private typealias SetFn = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>) -> Bool

    private static let signatures = [
        "isMCLSupported": "B16@0:8",
        "availableChargeLimitsWithError:": "@24@0:8^@16",
        "isMCLCurrentlyEnabled:": "Q24@0:8^@16",
        "getMCLLimitWithError:": "C24@0:8^@16",
        "setMCLLimit:error:": "B28@0:8C16^@20"
    ]

    private let client: AnyObject
    private let cls: AnyClass

    public init?() {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"), let meta = object_getClass(cls) else { return nil }
        for (name, signature) in Self.signatures {
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
                  let encoding = method_getTypeEncoding(method),
                  String(cString: encoding) == signature else { return nil }
        }
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithClientName:")
        guard class_respondsToSelector(cls, initSelector) else { return nil }
        let allocate = unsafeBitCast(class_getMethodImplementation(meta, allocSelector), to: Alloc.self)
        let initialize = unsafeBitCast(class_getMethodImplementation(cls, initSelector), to: InitFn.self)
        self.cls = cls
        client = initialize(allocate(cls, allocSelector), initSelector, "jMacosTweaker")
        let supported = NSSelectorFromString("isMCLSupported")
        guard unsafeBitCast(class_getMethodImplementation(cls, supported), to: SupportedFn.self)(client, supported) else { return nil }
    }

    public func availableLimits() -> [Int] {
        let selector = NSSelectorFromString("availableChargeLimitsWithError:")
        var error: NSError?
        let result = unsafeBitCast(class_getMethodImplementation(cls, selector), to: AvailableFn.self)(client, selector, &error)
        guard error == nil, let values = result as? [NSNumber] else { return [] }
        return values.map(\.intValue).filter { (1...100).contains($0) }.sorted()
    }

    public func currentLimit() -> Int? {
        var error: NSError?
        let enabledSelector = NSSelectorFromString("isMCLCurrentlyEnabled:")
        let enabled = unsafeBitCast(class_getMethodImplementation(cls, enabledSelector), to: EnabledFn.self)(client, enabledSelector, &error)
        guard error == nil, enabled != 0 else { return nil }
        let selector = NSSelectorFromString("getMCLLimitWithError:")
        let limit = unsafeBitCast(class_getMethodImplementation(cls, selector), to: GetFn.self)(client, selector, &error)
        guard error == nil, (1...100).contains(limit) else { return nil }
        return Int(limit)
    }

    public func setLimit(_ value: Int) -> Bool {
        guard (1...100).contains(value) else { return false }
        let selector = NSSelectorFromString("setMCLLimit:error:")
        var error: NSError?
        let accepted = unsafeBitCast(class_getMethodImplementation(cls, selector), to: SetFn.self)(client, selector, UInt8(value), &error)
        return accepted && error == nil
    }
}
