//
//  ImageBinder.swift
//  Kingfisher
//
//  Created by onevcat on 2019/06/27.
//
//  Copyright (c) 2019 Wei Wang <onevcat@gmail.com>
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

/// `ObservableObject` is Combine's, which Android does not have. The binder there is
/// `@Observable` instead and needs no protocol, so this is an empty marker.
#if os(Android)
protocol KFObservableObject: AnyObject {}
#else
typealias KFObservableObject = ObservableObject
#endif

extension Progress {
    /// `Progress()` is Darwin-only; swift-corelibs-foundation requires a count.
    static var kfNew: Progress {
        #if os(Android)
        Progress(totalUnitCount: 0)
        #else
        Progress()
        #endif
    }
}

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
extension KFImage {

    /// Represents a binder for `KFImage`. It takes responsibility as an `ObjectBinding` and performs
    /// image downloading and progress reporting based on `KingfisherManager`.
    ///
    /// Android has no Combine, hence no `ObservableObject`: there the binder is
    /// `@Observable` and `KFImageRenderer` holds it in a `@State` instead of a
    /// `@StateObject`.
    @MainActor
    #if os(Android)
    @Observable
    #endif
    class ImageBinder: KFObservableObject {
        
        init() {}

        /// `objectWillChange.send()`, or nothing at all under Observation — where
        /// writing an observed property *is* the notification.
        private func notifyChange() {
            #if !os(Android)
            objectWillChange.send()
            #endif
        }

        var downloadTask: DownloadTask?
        private var loading = false

        var loadingOrSucceeded: Bool {
            return loading || loadedImage != nil
        }

        // Do not use @Published due to https://github.com/onevcat/Kingfisher/issues/1717. Revert to @Published once
        // we can drop iOS 12.
        private(set) var loaded = false

        private(set) var animating = false

        /// The animation the load transition should run under, on platforms where the
        /// renderer applies it rather than the binder. See ``applyingAnimation(_:_:)``.
        private(set) var loadAnimation: Animation? = nil

        /// Runs `changes` under `animation`.
        ///
        /// SkipUI's `withAnimation` marks the whole Compose frame, so an image fading in
        /// would animate every unrelated list on screen — and their `scrollTo`. On
        /// Android the animation is therefore handed to `KFImageRenderer`, which applies
        /// it with `.animation(_:value:)` keyed on `loaded`.
        private func applyingAnimation(_ animation: Animation, _ changes: () -> Void) {
            #if os(Android)
            loadAnimation = animation
            changes()
            #else
            withAnimation(animation, changes)
            #endif
        }

        var loadedImage: KFCrossPlatformImage? = nil { willSet { notifyChange() } }
        var failureView: (() -> AnyView)? = nil { willSet { notifyChange() } }
        var progress: Progress = .kfNew

        func markLoading() {
            loading = true
        }

        func markLoaded(sendChangeEvent: Bool) {
            loaded = true
            if sendChangeEvent {
                notifyChange()
            }
        }

        func start<HoldingView: KFImageHoldingView>(context: Context<HoldingView>) where HoldingView: Sendable {
            guard let source = context.source else {
                CallbackQueueMain.currentOrAsync {
                    context.onFailureDelegate.call(KingfisherError.imageSettingError(reason: .emptySource))
                    if let view = context.failureView {
                        self.failureView = view
                    } else if let image = context.options.onFailureImage {
                        self.loadedImage = image
                    }
                    self.loading = false
                    self.markLoaded(sendChangeEvent: false)
                }
                return
            }

            loading = true
            
            progress = .kfNew
            downloadTask = KingfisherManager.shared
                .retrieveImage(
                    with: source,
                    options: context.options,
                    progressBlock: { size, total in
                        self.updateProgress(downloaded: size, total: total)
                        context.onProgressDelegate.call((size, total))
                    },
                    progressiveImageSetter: { image in
                        CallbackQueueMain.currentOrAsync {
                            self.markLoaded(sendChangeEvent: true)
                            self.loadedImage = image
                        }
                    },
                    completionHandler: { [weak self] result in

                        guard let self else { return }

                        CallbackQueueMain.currentOrAsync {
                            self.downloadTask = nil
                            self.loading = false
                        }
                        
                        switch result {
                        case .success(let value):
                            CallbackQueueMain.currentOrAsync {
                                if context.swiftUITransition != nil,
                                   context.shouldApplyFade(cacheType: value.cacheType) {
                                    // Apply SwiftUI loadTransition with custom animation (higher priority than fade)
                                    self.animating = true
                                    self.loadedImage = value.image

                                    let animation = context.swiftUIAnimation ?? .default
                                    CallbackQueueMain.async {
                                        self.applyingAnimation(animation) {
                                            self.markLoaded(sendChangeEvent: true)
                                        }
                                        self.animating = false
                                        context.onSuccessDelegate.call(value)
                                    }
                                } else if let fadeDuration = context.fadeTransitionDuration(cacheType: value.cacheType) {
                                    self.animating = true
                                    self.loadedImage = value.image

                                    let animation = Animation.linear(duration: fadeDuration)
                                    CallbackQueueMain.async {
                                        self.applyingAnimation(animation) {
                                            // Trigger the view render to apply the animation.
                                            self.markLoaded(sendChangeEvent: true)
                                        }
                                        self.animating = false
                                        context.onSuccessDelegate.call(value)
                                    }
                                } else {
                                    self.markLoaded(sendChangeEvent: false)
                                    self.loadedImage = value.image

                                    CallbackQueueMain.async {
                                        context.onSuccessDelegate.call(value)
                                    }
                                }
                            }
                        case .failure(let error):
                            CallbackQueueMain.currentOrAsync {
                                if let view = context.failureView {
                                    self.failureView = view
                                } else if let image = context.options.onFailureImage {
                                    self.loadedImage = image
                                }
                                self.markLoaded(sendChangeEvent: false)
                            }
                            
                            CallbackQueueMain.async {
                                context.onFailureDelegate.call(error)
                            }
                        }
                })
        }
        
        private func updateProgress(downloaded: Int64, total: Int64) {
            progress.totalUnitCount = total
            progress.completedUnitCount = downloaded
            notifyChange()
        }

        /// Cancels the download task if it is in progress.
        func cancel() {
            downloadTask?.cancel()
            downloadTask = nil
            loading = false
        }
        
        /// Restores the download task priority to default if it is in progress.
        ///
        /// A no-op on Android, whose downloader replaces the transport and so has no
        /// `URLSessionTask` to reprioritise; its own two-FIFO gate does the pacing.
        func restorePriorityOnAppear() {
            #if !os(Android)
            guard let downloadTask = downloadTask, loading == true else { return }
            downloadTask.sessionTask?.task.priority = URLSessionTask.defaultPriority
            #endif
        }
        
        /// Reduce the download task priority if it is in progress. See
        /// ``restorePriorityOnAppear()`` for why this does nothing on Android.
        func reducePriorityOnDisappear() {
            #if !os(Android)
            guard let downloadTask = downloadTask, loading == true else { return }
            downloadTask.sessionTask?.task.priority = URLSessionTask.lowPriority
            #endif
        }
    }
}
