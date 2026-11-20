import SwiftUI
import AVFoundation
import VideoToolbox
import Network

enum AppLanguage: String {
    case en = "EN", pl = "PL"
    var badge: String { self == .en ? "EN 🇬🇧" : "PL 🇵🇱" }
    var title: String { self == .en ? "iPhone Webcam Pro" : "iPhone Kamera Pro" }
    var statusWait: String { self == .en ? "Waiting for PC (USB :8888)..." : "Oczekiwanie na PC (USB :8888)..." }
    var statusLive: String { self == .en ? "Live 1080p 60 FPS (USB)" : "Nadawanie 1080p 60 FPS (USB)" }
    var statusDenied: String { self == .en ? "Camera access denied in Settings." : "Brak dostępu do kamery w Ustawieniach." }
    var torch: String { self == .en ? "Torch" : "Latarka" }
    var focus: String { self == .en ? "Focus" : "Ostrość" }
    var cam: String { self == .en ? "Camera" : "Kamera" }
    var front: String { self == .en ? "Front" : "Przód" }
    var back: String { self == .en ? "Back" : "Tył" }
    var autoRot: String { self == .en ? "Auto Rotate" : "Auto-obrót" }
    var zoom: String { self == .en ? "Zoom" : "Zoom" }
    var exp: String { self == .en ? "Exposure" : "Ekspozycja" }
    var wb: String { self == .en ? "WB Lock" : "Blokada WB" }
    var hint: String { self == .en ? "Synced live with Windows • Scroll for more controls" : "Synchronizacja z PC • Przewiń w dół po więcej opcji" }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.updateOrientation()
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
            updateOrientation()
        }

        func updateOrientation() {
            guard let conn = previewLayer.connection, conn.isVideoOrientationSupported else { return }
            let orient = window?.windowScene?.interfaceOrientation ?? .portrait
            switch orient {
            case .portrait: conn.videoOrientation = .portrait
            case .portraitUpsideDown: conn.videoOrientation = .portraitUpsideDown
            case .landscapeLeft: conn.videoOrientation = .landscapeLeft
            case .landscapeRight: conn.videoOrientation = .landscapeRight
            default: break
            }
        }
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

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.iphonewebcam.video", qos: .userInteractive)
    private var device: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var encoder: VTCompressionSession?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var rxBuffer = Data()
    private var lastOrient = ""

    override init() {
        super.init()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            DispatchQueue.main.async { self?.cameraAuthorized = ok }
            if ok { self?.queue.async { self?.configureCamera(front: false) } }
        }
        setupEncoder()
        startUSBServer()
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sendOrientation()
        }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        queue.async { [weak self] in if self?.session.isRunning == false { self?.session.startRunning() } }
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    func sendOrientation() {
        guard autoOrientation else { return }
        let o = UIDevice.current.orientation
        let mode = (o == .portrait || o == .portraitUpsideDown) ? "PORTRAIT" : ((o == .landscapeLeft || o == .landscapeRight) ? "LANDSCAPE" : nil)
        if let m = mode, m != lastOrient {
            lastOrient = m
            if let data = "ORIENT:\(m)\n".data(using: .utf8) { connection?.send(content: data, completion: .idempotent) }
        }
    }

    private func configureCamera(front: Bool) {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        if let old = currentInput { session.removeInput(old); currentInput = nil }

        let pos: AVCaptureDevice.Position = front ? .front : .back
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration(); return
        }
        session.addInput(input)
        currentInput = input
        device = dev

        if let fmt = dev.formats.first(where: {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width == 1920 && d.height == 1080 && $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }) {
            try? dev.lockForConfiguration()
            dev.activeFormat = fmt
            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
            dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
            dev.unlockForConfiguration()
        }

        if session.outputs.isEmpty {
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
        }
        if let conn = session.outputs.first?.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }
        session.commitConfiguration()

        let mz = min(dev.activeFormat.videoMaxZoomFactor, 6.0)
        DispatchQueue.main.async {
            self.isFrontCamera = front; self.torchOn = false; self.zoomFactor = 1.0
            self.maxZoom = max(mz, 1.0); self.exposureBias = 0.0; self.wbLocked = false; self.manualFocus = false
        }
    }

    private func setupEncoder() {
        let st = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 1920, height: 1080, codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, _, status, _, sb in
            guard status == noErr, let sb = sb, let ref = ref else { return }
            Unmanaged<CameraStreamManager>.fromOpaque(ref).takeUnretainedValue().onEncoded(sb)
        }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder)

        guard st == noErr, let enc = encoder else { return }
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AverageBitRate, value: 12_000_000 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(enc)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard self.connection != nil, let enc = encoder, let buf = CMSampleBufferGetImageBuffer(sb) else { return }
        VTCompressionSessionEncodeFrame(enc, imageBuffer: buf, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb), duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    private func onEncoded(_ sb: CMSampleBuffer) {
        guard let conn = connection else { return }
        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(
