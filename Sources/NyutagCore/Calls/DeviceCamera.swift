// Нютаг. Камера телефона для видеозвонка: AVCaptureSession, 640×480 повёрнуто в портрет, до 24 кадров в секунду.
// Звуком камера не управляет: сессию звука ведёт звонок (CallKit), иначе запуск камеры сбил бы разговор.

#if os(iOS)
import AVFoundation

public final class DeviceCamera: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "chat.nyutag.camera")
    /// Только в очереди камеры.
    private var pipe: VideoPipe?
    private var position: AVCaptureDevice.Position = .front
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
        if (try? device.lockForConfiguration()) != nil {
            let pace = CMTime(value: 1, timescale: CMTimeScale(VideoFormat.frameRate))
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(VideoFormat.frameRate) }) {
                device.activeVideoMinFrameDuration = pace
                device.activeVideoMaxFrameDuration = pace
            }
            device.unlockForConfiguration()
        }
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pipe, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Поворот, заданный при настройке, сессия может не применить: тогда кадр лежит боком (как у сенсора).
        // Чиним на соединении, с которого кадр пришёл; этот боковой кадр не шлём — у собеседника он вышел бы повёрнутым.
        if CVPixelBufferGetWidth(buffer) > CVPixelBufferGetHeight(buffer),
           connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
            log("камера: кадр боком, поворот 90° выставлен заново")
            return
        }
        pipe.capture(buffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), mirrored: position == .front)
    }

    enum CameraError: Error { case missing }
}
#endif
