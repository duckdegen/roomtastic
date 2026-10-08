// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Owners also release partially initialized endpoints when a later setup step throws.
final class DSPResources {
    private var allocations: [(OpaquePointer, (OpaquePointer?) -> Void)] = []
    func own(_ pointer: OpaquePointer?, destroy: @escaping (OpaquePointer?) -> Void) throws -> OpaquePointer {
        guard let pointer else { throw AudioFailure("Cannot allocate bounded audio storage") }
        allocations.append((pointer, destroy)); return pointer
    }
    deinit { for (pointer, destroy) in allocations.reversed() { destroy(pointer) } }
}
final class FloatStorage {
    let pointer: UnsafeMutablePointer<Float>
    init(_ count: Int) { pointer = .allocate(capacity: count); pointer.initialize(repeating: 0, count: count) }
    deinit { pointer.deallocate() }
}
