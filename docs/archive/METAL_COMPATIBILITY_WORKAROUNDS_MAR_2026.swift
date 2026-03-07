// ARCHIVED: March 2026
//
// Vestigial Metal renderer compatibility workarounds that are no longer needed.
//
// 1. layerClass override to CAMetalLayer.self
//    - Ghostty uses IOSurface-backed rendering, not the view's backing layer.
//      It creates its own IOSurfaceLayer and adds it as a sublayer (Metal.zig:113-133).
//      The view's layerClass has no effect on rendering.
//
// 2. ObjC addSublayer selector workaround (registerGhosttyMethods)
//    - The original Ghostty iOS code had a bug: it used objc.sel("addSublayer")
//      (no colon) but passed an argument. ObjC method names include colons for
//      parameters, so this was a selector mismatch.
//    - Fixed in Ghostty's Zig code (Metal.zig:133): now uses "addSublayer:" (WITH colon).
//    - The runtime method registration, forwardingTarget, and resolveInstanceMethod
//      overrides are no longer necessary.

// --- Original code from Ghostty.swift ---

// override class var layerClass: AnyClass {
//     return CAMetalLayer.self
// }

// MARK: - Ghostty Metal Renderer Compatibility (ARCHIVED)
//
// Ghostty's Metal.zig had this iOS code (line 117):
//   info.view.msgSend(void, objc.sel("addSublayer"), .{layer.layer.value});
//
// The issue: objc.sel("addSublayer") creates selector "addSublayer" (NO colon),
// but it passes an argument. In ObjC, method names include colons for parameters:
//   - "addSublayer" = no arguments
//   - "addSublayer:" = one argument
//
// This was a bug in Ghostty's iOS code path. We worked around it by adding
// a method at class initialization that handles "addSublayer" selector
// but accepts the argument anyway.
//
// Note: Swift's @objc(addSublayer:) would create the selector WITH a colon,
// which won't match what Ghostty was looking for.

// /// Runtime-registered flag to avoid double registration
// private static var methodsRegistered = false
//
// /// Register custom methods that Ghostty expects.
// /// This MUST be called before any SurfaceView is created.
// static func registerGhosttyMethods() {
//     guard !methodsRegistered else { return }
//     methodsRegistered = true
//
//     // Ghostty calls "addSublayer" (no colon) but passes one argument.
//     // We need to add this method at runtime since Swift can't express this.
//     let selector = sel_registerName("addSublayer")
//
//     // The IMP signature: void function(id self, SEL _cmd, id sublayer)
//     let imp: @convention(c) (AnyObject, Selector, AnyObject) -> Void = { (self_, sel_, sublayer) in
//         if let view = self_ as? UIView {
//             if let caLayer = sublayer as? CALayer {
//                 view.layer.addSublayer(caLayer)
//             } else {
//                 // Try to cast through AnyObject to id and use ObjC runtime
//                 let obj = sublayer as AnyObject
//                 if let caLayer = obj as? CALayer {
//                     view.layer.addSublayer(caLayer)
//                 }
//             }
//         }
//     }
//
//     // Type encoding: v = void return, @ = id (self), : = SEL, @ = id (argument)
//     let typeEncoding = "v@:@"
//
//     let success = class_addMethod(
//         SurfaceView.self,
//         selector,
//         unsafeBitCast(imp, to: IMP.self),
//         typeEncoding
//     )
//
//     if !success {
//         // Method already exists - try to replace it
//         let method = class_getInstanceMethod(SurfaceView.self, selector)
//         if let method = method {
//             method_setImplementation(method, unsafeBitCast(imp, to: IMP.self))
//         }
//     }
//
//     // Also add "addSublayer:" (with colon) just in case
//     let selectorWithColon = sel_registerName("addSublayer:")
//     _ = class_addMethod(
//         SurfaceView.self,
//         selectorWithColon,
//         unsafeBitCast(imp, to: IMP.self),
//         typeEncoding
//     )
// }
//
// /// Override to forward unrecognized selectors to self.layer
// /// This catches any CALayer methods that Ghostty might call on the view
// override func forwardingTarget(for aSelector: Selector!) -> Any? {
//     // Check if the layer responds to this selector
//     if layer.responds(to: aSelector) {
//         return layer
//     }
//     return super.forwardingTarget(for: aSelector)
// }
//
// /// Override method resolution to catch unhandled methods
// override class func resolveInstanceMethod(_ sel: Selector!) -> Bool {
//     let selectorName = NSStringFromSelector(sel)
//
//     // If it's addSublayer (with or without colon), register our handler
//     if selectorName == "addSublayer" || selectorName == "addSublayer:" {
//         registerGhosttyMethods()
//         return true
//     }
//
//     return super.resolveInstanceMethod(sel)
// }
