// Adapted from Harmony's vendored markiv/SwiftUI-Shimmer:
// https://github.com/markiv/SwiftUI-Shimmer
//
// MIT License
//
// Copyright (c) 2021 Vikram Kriplaney
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import SwiftUI

/// Harmony's locked reflection shimmer: one narrow diagonal band, every 1.8 s.
struct DiagonalShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        if reduceMotion || scenePhase != .active {
            content
        } else {
            content.modifier(DiagonalShimmerSweep())
        }
    }
}

private struct DiagonalShimmerSweep: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isInitialState = true

    private var startPoint: UnitPoint {
        if layoutDirection == .rightToLeft {
            isInitialState ? UnitPoint(x: 1.25, y: -0.25) : UnitPoint(x: 0, y: 1)
        } else {
            isInitialState ? UnitPoint(x: -0.25, y: -0.25) : UnitPoint(x: 1, y: 1)
        }
    }

    private var endPoint: UnitPoint {
        if layoutDirection == .rightToLeft {
            isInitialState ? UnitPoint(x: 1, y: 0) : UnitPoint(x: -0.25, y: 1.25)
        } else {
            isInitialState ? UnitPoint(x: 0, y: 0) : UnitPoint(x: 1.25, y: 1.25)
        }
    }

    func body(content: Content) -> some View {
        content
            .mask {
                LinearGradient(colors: [.black.opacity(0.3), .black, .black.opacity(0.3)],
                               startPoint: startPoint, endPoint: endPoint)
            }
            .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: isInitialState)
            .onAppear {
                // Begin after layout, just as in Harmony's shared shimmer.
                DispatchQueue.main.async { isInitialState = false }
            }
    }
}
