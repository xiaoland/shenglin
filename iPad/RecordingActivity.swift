import Darwin
import Foundation
import ObjectiveC.runtime

/// Reads the system's current recording owner without opening our own audio session.
@MainActor final class RecordingActivity {
    private typealias Shared = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
    private typealias Attribute = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?

    static let current = RecordingActivity()

    private let controller: AnyObject
    private let attribute: Attribute
    private let key: NSString

    private init?() {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(framework, "AVSystemController_IsSomeoneRecordingAttribute"),
              let keyObject = symbol.load(as: UnsafeRawPointer?.self),
              let cls = NSClassFromString("AVSystemController"),
              let shared = class_getClassMethod(cls, NSSelectorFromString("sharedAVSystemController")),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("attributeForKey:")),
              method_getTypeEncoding(shared).map({ String(cString: $0) }) == "@16@0:8",
              method_getTypeEncoding(method).map({ String(cString: $0) }) == "@24@0:8@16" else { return nil }
        key = Unmanaged<NSString>.fromOpaque(keyObject).takeUnretainedValue()
        controller = unsafeBitCast(method_getImplementation(shared), to: Shared.self)(
            cls, NSSelectorFromString("sharedAVSystemController")).takeUnretainedValue()
        attribute = unsafeBitCast(method_getImplementation(method), to: Attribute.self)
    }

    /// nil means the private property is unavailable or returned an unrecognized value.
    func sample() -> Bool? {
        guard let number = attribute(controller, NSSelectorFromString("attributeForKey:"), key)?
            .takeUnretainedValue() as? NSNumber else { return nil }
        let value = number.int64Value
        return value >= 0 ? value > 0 : nil
    }
}
