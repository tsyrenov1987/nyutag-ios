// Нютаг. Камера телефона для видеозвонка: AVCaptureSession, 640×480 с поворотом по RotationCoordinator, до 24 кадров в секунду.
// Звуком камера не управляет: сессию звука ведёт звонок (CallKit), иначе запуск камеры сбил бы разговор.

#if os(iOS)
import AVFoundation
import CoreImage

public final class DeviceCamera: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "chat.nyutag.camera")
    /// Только в очереди камеры.
    private var pipe: VideoPipe?
    private var position: AVCaptureDevice.Position = .front
    /// Только в очереди камеры. Угол поворота знает система: у iPhone 17 фронтальный сенсор квадратный
    /// и стоит не так, как у прежних, — жёсткие 90° клали кадр набок.
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    /// Ориентация сенсора камеры (как лежит кадр без поворота).
    private var sensorLandscape: Bool?
    private var appliedAngle: CGFloat = -1
    private lazy var turner = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private var turnPool: CVPixelBufferPool?
    private var turnSize = (width: 0, height: 0)
    private var turnLogged = false
    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    public static var available: Bool { AVCaptureDevice.default(for: .video) != nil }

    public func start(_ pipe: VideoPipe) throws {
        guard Self.available else { throw CameraError.missing }
        queue.async { [self] in
            self.pipe = pipe
            session.beginConfiguration()
            session.automaticallyConfiguresApplicationAudioSession = false
            if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            useCamera(position)
            session.commitConfiguration()
            session.startRunning()
            log("камера: запущена (\(position == .front ? "фронтальная" : "основная"))")
        }
    }

    public func stop() {
        queue.async { [self] in
            pipe = nil
            session.stopRunning()
            log("камера: остановлена")
        }
    }

    public func switchCamera() {
        queue.async { [self] in
            session.beginConfiguration()
            useCamera(position == .front ? .back : .front)
            session.commitConfiguration()
        }
    }

    /// В очереди камеры, внутри begin/commitConfiguration.
    private func useCamera(_ wanted: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: wanted)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        for old in session.inputs { session.removeInput(old) }
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        position = device.position
        coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let sensor = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        sensorLandscape = sensor.width == sensor.height ? nil : sensor.width > sensor.height
        appliedAngle = -1
        if (try? device.lockForConfiguration()) != nil {
            let pace = CMTime(value: 1, timescale: CMTimeScale(VideoFormat.frameRate))
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(VideoFormat.frameRate) }) {
                device.activeVideoMinFrameDuration = pace
                device.activeVideoMaxFrameDuration = pace
            }
            device.unlockForConfiguration()
        }
        if let connection = output.connection(with: .video) {
            aim(connection)
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        }
        log("камера: сенсор \(sensor.width)×\(sensor.height), угол \(Int(coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90))")
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pipe, var buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let angle = aim(connection)
        // Сессия может не применить поворот: тогда кадр лежит как у сенсора. Повернуть надо было на 90/270,
        // а форма кадра та же, что у сенсора, — поворачиваем сами, иначе у собеседника и в своём окошке лицо набок.
        let landscape = CVPixelBufferGetWidth(buffer) > CVPixelBufferGetHeight(buffer)
        if angle == 90 || angle == 270, landscape == (sensorLandscape ?? true) {
            guard let upright = turned(buffer, by: angle) else { return }
            if !turnLogged {
                turnLogged = true
                log("камера: поворот \(Int(angle))° сессия не применила, поворачиваю сами")
            }
            buffer = upright
        }
        pipe.capture(buffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), mirrored: position == .front)
    }

    /// Ставит на соединение угол, при котором горизонт ровный (телефон держат как держат); возвращает его.
    @discardableResult
    private func aim(_ connection: AVCaptureConnection) -> CGFloat {
        let angle = coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        if angle != appliedAngle {
            appliedAngle = angle
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
        return angle
    }

    /// Тот же кадр, повёрнутый по часовой на `angle` (как `videoRotationAngle`), в новом буфере из пула.
    private func turned(_ buffer: CVPixelBuffer, by angle: CGFloat) -> CVPixelBuffer? {
        let width = CVPixelBufferGetHeight(buffer), height = CVPixelBufferGetWidth(buffer)
        if turnPool == nil || turnSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(buffer),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            turnPool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &turnPool)
            turnSize = (width, height)
        }
        guard let pool = turnPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        var image = CIImage(cvPixelBuffer: buffer).oriented(angle == 90 ? .right : .left)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        turner.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return out
    }

    enum CameraError: Error { case missing }
}
#endif
