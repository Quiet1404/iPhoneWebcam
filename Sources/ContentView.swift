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
            let supports60 = fmt.videoSupportedFrameRateRanges
