// READ-ONLY probe of the private macOS charge limit client. Lists methods and calls only the getter.
// The method list is filtered to names that read state, and nothing here calls a setter.
import Foundation
import ObjectiveC

guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil else { print("no PowerUI"); exit(1) }
guard let cls = NSClassFromString("PowerUISmartChargeClient") else { print("no class"); exit(1) }
func methods(_ c: AnyClass) -> [String] {
    var n: UInt32 = 0
    guard let list = class_copyMethodList(c, &n) else { return [] }
    defer { free(list) }
    return (0..<Int(n)).map { i in
        let m = list[i]
        return NSStringFromSelector(method_getName(m)) + "  " + String(cString: method_getTypeEncoding(m) ?? UnsafePointer(strdup("?")))
    }.sorted()
}
print("instance methods:"); methods(cls).forEach { print(" ", $0) }
if let meta = object_getClass(cls) { print("class methods:"); methods(meta).forEach { print(" ", $0) } }
typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject
let allocSel = NSSelectorFromString("alloc")
let alloc = unsafeBitCast(class_getMethodImplementation(object_getClass(cls), allocSel), to: Alloc.self)
let initSel = NSSelectorFromString("initWithClientName:")
guard class_respondsToSelector(cls, initSel) else { print("no initWithClientName:"); exit(0) }
typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
let initFn = unsafeBitCast(class_getMethodImplementation(cls, initSel), to: InitFn.self)
let client = initFn(alloc(cls, allocSel), initSel, "jMacosTweakerProbe")
let getSel = NSSelectorFromString("getMCLLimitWithError:")
guard class_respondsToSelector(cls, getSel) else { print("no getter"); exit(0) }
let encoding = String(cString: method_getTypeEncoding(class_getInstanceMethod(cls, getSel)!)!)
print("getter encoding:", encoding)
typealias GetFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Int8
var error: NSError?
let result: Any
if encoding.hasPrefix("@") {
    typealias GetObj = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> AnyObject?
    result = unsafeBitCast(class_getMethodImplementation(cls, getSel), to: GetObj.self)(client, getSel, &error) as Any
} else {
    typealias GetDouble = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Int64
    result = unsafeBitCast(class_getMethodImplementation(cls, getSel), to: GetDouble.self)(client, getSel, &error)
}
print("getMCLLimit ->", result, "error:", error.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "none")

typealias ObjErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> AnyObject?
typealias BoolPlain = @convention(c) (AnyObject, Selector) -> Bool
typealias UIntErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt
var e2: NSError?
let availableSel = NSSelectorFromString("availableChargeLimitsWithError:")
let available = unsafeBitCast(class_getMethodImplementation(cls, availableSel), to: ObjErr.self)(client, availableSel, &e2)
print("availableChargeLimits ->", available as Any, "error:", e2.map { "\($0.domain) \($0.code)" } ?? "none")
let supportedSel = NSSelectorFromString("isMCLSupported")
print("isMCLSupported ->", unsafeBitCast(class_getMethodImplementation(cls, supportedSel), to: BoolPlain.self)(client, supportedSel))
var e3: NSError?
let enabledSel = NSSelectorFromString("isMCLCurrentlyEnabled:")
print("isMCLCurrentlyEnabled ->", unsafeBitCast(class_getMethodImplementation(cls, enabledSel), to: UIntErr.self)(client, enabledSel, &e3), e3.map { "\($0.domain) \($0.code)" } ?? "none")
