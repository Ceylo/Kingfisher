//
//  KFImageRenderer.swift
//  Kingfisher
//
//  Created by onevcat on 2021/05/08.
//
//  Copyright (c) 2021 Wei Wang <onevcat@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

// No `#if canImport(SwiftUI) && canImport(Combine)` gate any more: every platform this
// fork supports has SwiftUI (Android through SkipSwiftUI), and skipstone's bridge
// generator silently drops a file whose top-level `#if` it cannot evaluate — which left
// `KFImageRenderer` without the Kotlin glue its `@State` needs, so `KFImage` rendered
// nothing at all on Android. Only `import Combine` is still conditional.
import SwiftUI
#if !os(Android)
import Combine
#endif

/// A Kingfisher compatible SwiftUI `View` to load an image from a `Source`.
/// Declaring a `KFImage` in a `View`'s body to trigger loading from the given `Source`.
@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
struct KFImageRenderer<HoldingView> : View where HoldingView: KFImageHoldingView & Sendable {
    
    // Not `private`, and `@State` rather than `@StateObject` on Android: there is no
    // Combine there, and skipstone generates a bridged view's Kotlin glue from the
    // property list it can see — a private one is silently left out and the view never
    // recomposes.
    #if os(Android)
    @State var binder: KFImage.ImageBinder
    /// Whether a placeholder has ever been on screen for this view, and whether the
    /// image has since had a composition of its own. Together they hold the placeholder
    /// across the hand-off — see `showPlaceholder` in `body`. Not `private`, and not
    /// inside `#if DEBUG`, for the same bridging reason as `binder`.
    @State var placeholderWasShown = false
    @State var imageHadItsOwnPass = false
    #else
    @StateObject var binder: KFImage.ImageBinder = .init()
    #endif
    let context: KFImage.Context<HoldingView>
    
    init(context: KFImage.Context<HoldingView>) {
        self.init(context: context, binder: .init())
    }

    init(context: KFImage.Context<HoldingView>, binder: KFImage.ImageBinder) {
        #if os(Android)
        _binder = State(wrappedValue: binder)
        #else
        _binder = StateObject(wrappedValue: binder)
        #endif
        self.context = context
    }

    var body: some View {
        if context.startLoadingBeforeViewAppear && !binder.loadingOrSucceeded && !binder.animating {
            binder.markLoading()
            DispatchQueue.main.async { binder.start(context: context) }
        }

        // Draws an image that is already in the memory cache on this very composition.
        // Same guard as the block above, which is also the precedent for mutating the
        // binder straight from `body`. See ``ImageBinder/resolveFromMemoryCache(context:)``
        // for why only this layer can close the gap, and only for a cache *read*.
        #if os(Android)
        if !binder.loadingOrSucceeded && !binder.animating {
            binder.resolveFromMemoryCache(context: context)
        }
        #endif

        return ZStack {
            let isImageRenderable = binder.loadedImage != nil && binder.loaded

            // Which pass the placeholder is released on. SwiftUI drops it in the same
            // pass that first makes the image renderable and that is fine there; SkipUI
            // is not guaranteed to paint the new bitmap in that pass, so the row is laid
            // out with neither the placeholder nor the image in it for one frame. Keeping
            // the placeholder one pass longer closes that: it stays on top until the
            // image has had a composition of its own, which the `onAppear` below reports
            // a pass later (a Compose `SideEffect`).
            //
            // `placeholderWasShown` is what keeps this from *causing* a blink: when the
            // image resolves on the very first composition — a memory-cache hit, see
            // `ImageBinder.resolveFromMemoryCache` — no placeholder was ever on screen,
            // so there is no hand-off to cover and none is inserted.
            #if os(Android)
            let showPlaceholder = !isImageRenderable
                || (placeholderWasShown && !imageHadItsOwnPass)
            #else
            let showPlaceholder = !isImageRenderable
            #endif

            if context.swiftUITransition == nil {
                // Fade transition or no transition: use opacity control
                // Keep the image branch for external transitions without affecting layout while no
                // image is loaded. The zero frame is intentionally tied to `loadedImage` instead of
                // `isImageRenderable`: it is released in the render pass that sets `loadedImage`,
                // one pass before the animated `markLoaded`, so the layout change never falls into
                // the fade transaction and gets interpolated into a scaling effect.
                renderedImage()
                    .opacity(isImageRenderable ? 1.0 : 0.0)
                    .frame(
                        width: binder.loadedImage == nil ? 0 : nil,
                        height: binder.loadedImage == nil ? 0 : nil
                    )
            } else if isImageRenderable {
                // SwiftUI loadTransition: insert/remove view for proper transition behavior
                renderedImage()
            }

            if showPlaceholder {
                ZStack {
                    // Priority: failureView > placeholder > Color.clear
                    // failureView is only set when image loading fails
                    if let failureView = binder.failureView {
                        failureView()
                    } else if let placeholder = context.placeholder {
                        placeholder(binder.progress)
                    } else {
                        Color.clear
                    }
                }
                .onAppear { [weak binder = self.binder] in
                    #if os(Android)
                    placeholderWasShown = true
                    #endif
                    guard let binder = binder else {
                        return
                    }
                    if !binder.loadingOrSucceeded {
                        binder.start(context: context)
                    } else {
                        if context.reducePriorityOnDisappear {
                            binder.restorePriorityOnAppear()
                        }
                    }
                }
                .onDisappear { [weak binder = self.binder] in
                    guard let binder = binder else {
                        return
                    }
                    if context.cancelOnDisappear {
                        binder.cancel()
                    } else if context.reducePriorityOnDisappear {
                        binder.reducePriorityOnDisappear()
                    }
                }
            }

            // Reports, one composition later, that the image has had a pass of its own.
            // Zero-framed: a bare `Color` would expand and size the `ZStack`.
            #if os(Android)
            if isImageRenderable && placeholderWasShown && !imageHadItsOwnPass {
                Color.clear
                    .frame(width: 0, height: 0)
                    .onAppear { imageHadItsOwnPass = true }
            }
            #endif
        }
        // Workaround for https://github.com/onevcat/Kingfisher/issues/1988
        // on iOS 16 there seems to be a bug that when in a List, the `onAppear` of the `ZStack` above in the
        // `binder.loadedImage == nil` not get called. Adding this empty `onAppear` fixes it and the life cycle can
        // work again.
        //
        // There is another "fix": adding an `else` clause and put a `Color.clear` there. But I believe this `onAppear`
        // should work better.
        //
        // It should be a bug in iOS 16, I guess it is some kinds of over-optimization in list cell loading caused it.
        .onAppear()
        // On Android the binder does not call `withAnimation` — it marks the whole
        // Compose frame — so the load transition is applied here instead, keyed on the
        // `Bool` that flips when the image becomes renderable.
        #if os(Android)
        .animation(binder.loadAnimation, value: binder.loaded)
        #endif
    }
    
    @ViewBuilder
    private func renderedImage() -> some View {
        if let swiftUITransition = context.swiftUITransition {
            // Apply SwiftUI loadTransition as the last step for correct rendering order
            configuredImage.transition(swiftUITransition)
        } else {
            configuredImage
        }
    }
    
    @ViewBuilder
    private var configuredImage: some View {
        let configuredImage = context.configurations
            .reduce(HoldingView.created(from: binder.loadedImage, context: context)) {
                current, config in config(current)
            }
        
        // Apply contentConfiguration first, then loadTransition as the final step
        if let contentConfiguration = context.contentConfiguration {
            contentConfiguration(configuredImage)
        } else {
            configuredImage
        }
    }
}

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
extension Image {
    // Creates an Image with either UIImage or NSImage.
    init(crossPlatformImage: KFCrossPlatformImage?) {
        #if os(Android)
        // `UIImage()` does not exist on Android — SkipSwiftUI's is Bitmap-backed and
        // has no empty form — so a 1x1 transparent pixel stands in while loading. It is
        // only ever rendered at `opacity(0)` and inside a zero frame.
        self.init(uiImage: crossPlatformImage ?? .kfPlaceholderPixel)
        #elseif canImport(UIKit)
        self.init(uiImage: crossPlatformImage ?? KFCrossPlatformImage())
        #elseif canImport(AppKit)
        self.init(nsImage: crossPlatformImage ?? KFCrossPlatformImage())
        #endif
    }
}

#if os(Android)
extension KFCrossPlatformImage {
    /// A 1x1 fully transparent PNG, decoded once.
    static let kfPlaceholderPixel: KFCrossPlatformImage = {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )!
        return KFCrossPlatformImage(data: png, scale: 1)!
    }()
}
#endif

#if canImport(UIKit)
@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
extension UIImage.Orientation {
    func toSwiftUI() -> Image.Orientation {
        switch self {
        case .down: return .down
        case .up: return .up
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
#endif
