// Нютаг. `Mutex` и `Atomic` с тем же API, что в Synchronization, но с iOS 17: системные — только с iOS 18.
// Внутри — `OSAllocatedUnfairLock`; порядок памяти (`ordering:`) принимаем ради совместимости, лок и так даёт полный.

import os

public final class Mutex<Value>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    public init(_ initialValue: Value) { value = initialValue }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

public enum AtomicOrdering: Sendable { case relaxed, acquiring, releasing, acquiringAndReleasing, sequentiallyConsistent }

public final class Atomic<Value>: @unchecked Sendable {
    private let box: Mutex<Value>

    public init(_ initialValue: Value) { box = Mutex(initialValue) }

    public func load(ordering: AtomicOrdering) -> Value { box.withLock { $0 } }

    public func store(_ desired: Value, ordering: AtomicOrdering) { box.withLock { $0 = desired } }

    @discardableResult
    public func exchange(_ desired: Value, ordering: AtomicOrdering) -> Value {
        box.withLock { value in
            let old = value
            value = desired
            return old
        }
    }
}

extension Atomic where Value: BinaryInteger {
    @discardableResult
    public func add(_ operand: Value, ordering: AtomicOrdering) -> (oldValue: Value, newValue: Value) {
        box.withLock { value in
            let old = value
            value += operand
            return (old, value)
        }
    }

    @discardableResult
    public func subtract(_ operand: Value, ordering: AtomicOrdering) -> (oldValue: Value, newValue: Value) {
        box.withLock { value in
            let old = value
            value -= operand
            return (old, value)
        }
    }
}
