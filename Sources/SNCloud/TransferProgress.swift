// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// Transfer progress: how many bytes have arrived and how many are expected in
/// total. `total` is sometimes zero — not every response states a length.
///
/// A closure rather than an `NSProgress`, because what crosses actor boundaries
/// here is a value: a class without `Sendable` does not get through.
///
/// The same spelling `RMCloud` uses, on purpose: a typealias for a function type
/// is not a nominal type, so this name and that one are the *same* type, and a
/// host that declares its own copy shadows both without converting anything.
public typealias TransferProgress = @Sendable (_ completed: Int64, _ total: Int64) -> Void
