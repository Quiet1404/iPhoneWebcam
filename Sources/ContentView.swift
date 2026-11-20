import SwiftUI
import AVFoundation
import VideoToolbox
import Network

enum AppLanguage: String, CaseIterable {
    case en = "EN"
    case pl = "PL"

    var badge: String {
        switch self {
        case .en: return "EN 🇬🇧"
        case .pl: return "PL 🇵🇱"
        }
    }

    var title: String {
        switch self {
        case .en: return "iPhone Webcam USB"
        case .pl: return "iPhone Kamera USB"
        }
    }

    var waitingStatus: String {
        switch self {
        case .en: return "Waiting for PC connection (USB :8888)..."
        case .pl: return "Oczekiwanie na połączenie z PC (USB :8888)..."
        }
    }

    var streamingStatus: String {
        switch self {
        case .en: return "Streaming 1080p 60 FPS via USB"
        case .pl: return "Przesyłanie 1080p 60 FPS przez USB"
        }
    }

    var cameraErrorStatus: String {
        switch self {
        case .en: return "Camera access denied. Check Settings."
        case .pl: return "Brak dostępu do kamery. Sprawdź Ustawienia."
        }
    }

    var torchLabel: String {
        switch self {
        case .en: return "Flashlight"
        case .pl: return "Latarka"
        }
    }

    var focusLabel: String {
        switch self {
        case .en: return "Focus"
        case .pl: return "Ostrość"
        }
    }

    var autoFocusValue: String {
        switch self {
        case .en: return "Auto (AF)"
        case .pl: return "Auto (AF)"
        }
    }

    var manualFocusValue: String {
        switch self {
        case .en: return "Manual (MF)"
        case .pl: return "Ręczna (MF)"
        }
    }

    var hintText: String {
        switch self {
        case .en: return "Keep this screen open while streaming to Windows"
        case .pl: return "Nie zamykaj aplikacji podczas przesyłania obrazu do PC"
        }
    }
}

final class CameraStreamManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isConnected = false
    @Published var cameraAuthorized = true
    @Published var torchOn = false
    @Published var manualFocus = false
    @Published var lensPosition: Float = 0.5

    private let captureSession = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.iphonewebcam.videoQueue", qos: .userInteractive)
    private var videoDevice: AVCaptureDevice?
    private var compressionSession: VTCompressionSession?

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var receiveBuffer = Data()

    override init() {
        super.init()
        setupCamera()
        setupEncoder()
        startUSBServer()
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        videoQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    private func setupCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.cameraAuthorized = granted
            }
            guard granted else { return }
            self?.videoQueue.async {
                self?.configureCaptureSession()
            }
        }
    }

    private func configureCaptureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }

        captureSession.addInput(input)
        self.videoDevice = device

        // Configure 60 FPS if supported
        if let format = device.formats.first(where: { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let supports60 = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60.0 }
            return dims.width == 1920 && dims.height == 1080 && supports60
        }) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
                device.unlockForConfiguration()
            } catch {}
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }

        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
        }

        captureSession.commitConfiguration()
    }

    private func setupEncoder() {
        let width: Int32 = 1920
        let height: Int32 = 1080

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { outputCallbackRefCon, _, status, _, sampleBuffer in
                guard status == noErr,
                      let sampleBuffer = sampleBuffer,
                      let refCon = outputCallbackRefCon else { return }
                let manager = Unmanaged<CameraStreamManager>.fromOpaque(refCon).takeUnretainedValue()
                manager.handleEncodedFrame(sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )

        guard status == noErr, let session = compressionSession else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 12_000_000 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard activeConnection != nil,
              let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let conn = activeConnection else { return }

        var annexBData = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Check if keyframe to prepend SPS and PPS
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKeyframe = !notSync
        }

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsSize = 0
            var spsCount = 0
            var spsPtr: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil) == noErr,
               let spsPtr = spsPtr {
                annexBData.append(contentsOf: startCode)
                annexBData.append(spsPtr, count: spsSize)
            }

            var ppsSize = 0
            var ppsPtr: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
               let ppsPtr = ppsPtr {
                annexBData.append(contentsOf: startCode)
                annexBData.append(ppsPtr, count: ppsSize)
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let ptr = dataPointer else { return }

        var offset = 0
        while offset + 4 <= totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, ptr.advanced(by: offset), 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4

            guard offset + Int(nalLength) <= totalLength else { break }
            annexBData.append(contentsOf: startCode)
            ptr.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: Int(nalLength)) { uint8Ptr in
                annexBData.append(uint8Ptr, count: Int(nalLength))
            }
            offset += Int(nalLength)
        }

        if !annexBData.isEmpty {
            conn.send(content: annexBData, completion: .idempotent)
        }
    }

    private func startUSBServer() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Restrict listener to loopback (USB usbmuxd tunnel) for security
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 8888)

            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] newConn in
                self?.acceptConnection(newConn)
            }
            listener.start(queue: videoQueue)
            self.listener = listener
        } catch {
            print("Failed to start USB listener: \(error)")
        }
    }

    private func acceptConnection(_ conn: NWConnection) {
        activeConnection?.cancel()
        activeConnection = conn
        receiveBuffer.removeAll()

        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                case .failed, .cancelled:
                    self?.isConnected = false
                    self?.setTorch(false)
                default:
                    break
                }
            }
        }

        conn.start(queue: videoQueue)
        receiveCommands(on: conn)
    }

    private func receiveCommands(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                while let newlineRange = self.receiveBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = self.receiveBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    self.receiveBuffer.removeSubrange(0...newlineRange.lowerBound)
                    if let cmd = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        self.handleCommand(cmd)
                    }
                }
            }
            if error == nil && !isComplete {
                self.receiveCommands(on: conn)
            }
        }
    }

    private func handleCommand(_ cmd: String) {
        if cmd == "TORCH:1" {
            setTorch(true)
        } else if cmd == "TORCH:0" {
            setTorch(false)
        } else if cmd == "AF" {
            setAutoFocus()
        } else if cmd == "MF" {
            setManualFocus(lensPosition)
        } else if cmd.hasPrefix("FOCUS:"), let val = Float(cmd.dropFirst(6)) {
            setManualFocus(min(max(val, 0.0), 1.0))
        }
    }

    func setTorch(_ on: Bool) {
        videoQueue.async { [weak self] in
            guard let device = self?.videoDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if on {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self?.torchOn = on
                }
            } catch {}
        }
    }

    func setAutoFocus() {
        videoQueue.async { [weak self] in
            guard let device = self?.videoDevice, device.isFocusModeSupported(.continuousAutoFocus) else { return }
            do {
                try device.lockForConfiguration()
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self?.manualFocus = false
                }
            } catch {}
        }
    }

    func setManualFocus(_ position: Float) {
        videoQueue.async { [weak self] in
            guard let device = self?.videoDevice, device.isFocusModeSupported(.locked) else { return }
            do {
                try device.lockForConfiguration()
                device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self?.manualFocus = true
                    self?.lensPosition = position
                }
            } catch {}
        }
    }
}

struct ContentView: View {
    @AppStorage("appLanguage") private var langRaw: String = AppLanguage.en.rawValue
    @StateObject private var camera = CameraStreamManager()

    private var lang: AppLanguage {
        AppLanguage(rawValue: langRaw) ?? .en
    }

    private func toggleLanguage() {
        langRaw = (lang == .en) ? AppLanguage.pl.rawValue : AppLanguage.en.rawValue
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                // Top Bar with Language Switcher
                HStack {
                    Text(lang.title)
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    Button(action: toggleLanguage) {
                        Text(lang.badge)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.16))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)

                Spacer()

                // Connection Status Indicator
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(camera.isConnected ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                            .frame(width: 96, height: 96)

                        Image(systemName: camera.isConnected ? "video.fill" : "cable.connector")
                            .font(.system(size: 40))
                            .foregroundColor(camera.isConnected ? .green : .orange)
                    }

                    Text(
                        !camera.cameraAuthorized
                        ? lang.cameraErrorStatus
                        : (camera.isConnected ? lang.streamingStatus : lang.waitingStatus)
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                }

                // Live Telemetry & Local Controls
                HStack(spacing: 16) {
                    Button(action: { camera.setTorch(!camera.torchOn) }) {
                        VStack(spacing: 6) {
                            Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.title2)
                            Text(lang.torchLabel)
                                .font(.caption.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(camera.torchOn ? Color.yellow.opacity(0.85) : Color.white.opacity(0.12))
                        .foregroundColor(camera.torchOn ? .black : .white)
                        .cornerRadius(12)
                    }

                    Button(action: {
                        if camera.manualFocus {
                            camera.setAutoFocus()
                        } else {
                            camera.setManualFocus(camera.lensPosition)
                        }
                    }) {
                        VStack(spacing: 6) {
                            Image(systemName: camera.manualFocus ? "scope" : "viewfinder")
                                .font(.title2)
                            Text("\(lang.focusLabel): \(camera.manualFocus ? lang.manualFocusValue : lang.autoFocusValue)")
                                .font(.caption.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(camera.manualFocus ? Color.blue.opacity(0.8) : Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                Spacer()

                Text(lang.hintText)
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}
