import SwiftUI
import AVFoundation
import VideoToolbox
import Network

enum AppLanguage: String, CaseIterable {
    case en = "EN"
    case pl = "PL"

    var badge: String { self == .en ? "EN 🇬🇧" : "PL 🇵🇱" }
    var title: String { self == .en ? "iPhone Webcam Pro" : "iPhone Kamera Pro" }
    var waitingStatus: String { self == .en ? "Waiting for PC (USB :8888)..." : "Oczekiwanie na PC (USB :8888)..." }
    var streamingStatus: String { self == .en ? "Live 1080p 60 FPS (USB)" : "Nadawanie 1080p 60 FPS (USB)" }
    var cameraErrorStatus: String { self == .en ? "Camera access denied in Settings." : "Brak dostępu do kamery w Ustawieniach." }
    var torchLabel: String { self == .en ? "Torch" : "Latarka" }
    var focusLabel: String { self == .en ? "Focus" : "Ostrość" }
    var cameraLabel: String { self == .en ? "Camera" : "Kamera" }
    var frontCam: String { self == .en ? "Front" : "Przód" }
    var backCam: String { self == .en ? "Back" : "Tył" }
    var autoOrientLabel: String { self == .en ? "Auto Rotate" : "Auto-obrót" }
    var zoomLabel: String { self == .en ? "Zoom" : "Zoom" }
    var exposureLabel: String { self == .en ? "Exposure" : "Ekspozycja" }
    var wbLabel: String { self == .en ? "WB Lock" : "Blokada WB" }
    var hintText: String {
        self == .en
        ? "All controls sync live with Windows • Keep app open while streaming"
        : "Sterowanie synchronizuje się z PC • Nie zamykaj aplikacji podczas transmisji"
    }
}

final class CameraStreamManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isConnected = false
    @Published var cameraAuthorized = true
    @Published var isFrontCamera = false
    @Published var torchOn = false
    @Published var manualFocus = false
    @Published var lensPosition: Float = 0.5
    @Published var zoomFactor: CGFloat = 1.0
    @Published var maxZoom: CGFloat = 5.0
    @Published var exposureBias: Float = 0.0
    @Published var wbLocked = false
    @Published var autoOrientation = true

    private let captureSession = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.iphonewebcam.videoQueue", qos: .userInteractive)
    private var videoDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var compressionSession: VTCompressionSession?

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var receiveBuffer = Data()
    private var lastSentOrientation = "LANDSCAPE"

    override init() {
        super.init()
        setupCamera()
        setupEncoder()
        startUSBServer()
        startOrientationObserver()
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        videoQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    private func startOrientationObserver() {
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reportDeviceOrientation()
        }
    }

    func reportDeviceOrientation() {
        guard autoOrientation else { return }
        let orientation = UIDevice.current.orientation
        var mode: String?
        switch orientation {
        case .portrait, .portraitUpsideDown:
            mode = "PORTRAIT"
        case .landscapeLeft, .landscapeRight:
            mode = "LANDSCAPE"
        default:
            break
        }
        if let mode = mode, mode != lastSentOrientation {
            lastSentOrientation = mode
            sendToPC("ORIENT:\(mode)")
        }
    }

    private func sendToPC(_ message: String) {
        guard let conn = activeConnection, let data = (message + "\n").data(using: .utf8) else { return }
        conn.send(content: data, completion: .idempotent)
    }

    private func setupCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.cameraAuthorized = granted
            }
            guard granted else { return }
            self?.videoQueue.async {
                self?.configureCaptureSession(position: .back)
            }
        }
    }

    private func configureCaptureSession(position: AVCaptureDevice.Position) {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        if let existing = currentInput {
            captureSession.removeInput(existing)
            currentInput = nil
        }

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)

        guard let camDevice = device,
              let input = try? AVCaptureDeviceInput(device: camDevice),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }

        captureSession.addInput(input)
        self.currentInput = input
        self.videoDevice = camDevice

        if let format = camDevice.formats.first(where: { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let supports60 = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60.0 }
            return dims.width == 1920 && dims.height == 1080 && supports60
        }) {
            do {
                try camDevice.lockForConfiguration()
                camDevice.activeFormat = format
                camDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                camDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
                camDevice.unlockForConfiguration()
            } catch {}
        }

        if captureSession.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
            }
        }

        if let output = captureSession.outputs.first,
           let connection = output.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }

        captureSession.commitConfiguration()

        let maxZ = min(camDevice.activeFormat.videoMaxZoomFactor, 6.0)
        DispatchQueue.main.async {
            self.isFrontCamera = (position == .front)
            self.torchOn = false
            self.zoomFactor = 1.0
            self.maxZoom = max(maxZ, 1.0)
            self.exposureBias = 0.0
            self.wbLocked = false
            self.manualFocus = false
        }
    }

    private func setupEncoder() {
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refCon, _, status, _, sampleBuffer in
                guard status == noErr, let sb = sampleBuffer, let refCon = refCon else { return }
                let manager = Unmanaged<CameraStreamManager>.fromOpaque(refCon).takeUnretainedValue()
                manager.handleEncodedFrame(sb)
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

        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKeyframe = !notSync
        }

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsSize = 0
            var spsPtr: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
               let spsPtr = spsPtr {
                annexBData.append(contentsOf: startCode)
                annexBData.append(spsPtr, count: spsSize)
            }

            var ppsSize = 0
            var ppsPtr: UnsafePointer<UInt8>?
            if CM
