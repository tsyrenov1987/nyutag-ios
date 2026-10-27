// Нютаг. Задержка пути до собеседника и обратно по зондам видео. Своя очередь отправки (backlog) пробку дальше по
// дороге не видит: кадры оседают в буферах TCP у дверей и ядра, а у собеседника звук стоит в них за видео. Поэтому
// отправитель видео раз в полсекунды шлёт метку времени, собеседник сразу её возвращает, и рост задержки эха
// сверх обычной для этого звонка значит: видео надо урезать. Эха не было ни разу (у собеседника старая версия) —
// судить не о чем, видео живёт по своей очереди, как раньше.

public struct DelayGauge: Sendable {
    public enum Verdict: Sendable, Equatable {
        /// Эха ещё не было.
        case unknown
        /// Задержка как обычно: можно прибавлять.
        case clear
        /// Подросла: держим как есть.
        case fair
        /// Пробка: урезаем.
        case jammed
    }

    static let probeEvery: Int64 = 500
    /// Сверх обычной задержки — пробка.
    static let jamMargin: Int64 = 500
    /// Не дальше от обычной — путь свободен.
    static let clearMargin: Int64 = 200
    /// Обычная задержка — наименьшая за это время: путь мог смениться при переподключении.
    static let baseWindow: Int64 = 60_000

    /// Метки зондов без эха, по порядку отправки.
    private var pending: [UInt32] = []
    private var lastProbe: Int64?
    /// (когда пришло эхо, задержка), по порядку.
    private var samples: [(at: Int64, delay: Int64)] = []

    public init() {}

    /// Метка для нового зонда, если пора его слать. `now` — мс от начала звонка.
    public mutating func probe(now: Int64) -> UInt32? {
        if let lastProbe, now - lastProbe < Self.probeEvery { return nil }
        lastProbe = now
        let stamp = UInt32(truncatingIfNeeded: now)
        pending.append(stamp)
        if pending.count > 32 { pending.removeFirst() }
        return stamp
    }

    /// Пришло эхо. Зонды до него, оставшиеся без эха, потерялись: их больше не ждём.
    public mutating func echo(_ stamp: UInt32, now: Int64) {
        guard let index = pending.firstIndex(of: stamp) else { return }
        pending.removeFirst(index + 1)
        samples.append((now, Int64(UInt32(truncatingIfNeeded: now) &- stamp)))
        samples.removeAll { now - $0.at > Self.baseWindow }
    }

    /// Обычная задержка звонка.
    public var base: Int64? { samples.map(\.delay).min() }

    /// Задержка сейчас: наименьшая из эх за последнюю секунду (одиночный всплеск — не пробка), но не меньше
    /// возраста самого старого зонда без эха (эхо перестало приходить — это тоже пробка).
    public func delay(now: Int64) -> Int64? {
        guard !samples.isEmpty else { return nil }
        let recent = samples.filter { now - $0.at <= 1_000 }.map(\.delay).min() ?? 0
        let waiting = pending.first.map { Int64(UInt32(truncatingIfNeeded: now) &- $0) } ?? 0
        return max(recent, waiting)
    }

    public func verdict(now: Int64) -> Verdict {
        guard let base, let delay = delay(now: now) else { return .unknown }
        if delay > base + Self.jamMargin { return .jammed }
        return delay <= base + Self.clearMargin ? .clear : .fair
    }
}
