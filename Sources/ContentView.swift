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
    var statusDenied: String { self == .en ? "Camera access denied." : "Brak dostępu do kamery." }
    var torch: String { self == .en ? "Torch" : "Latarka" }
    var focus: String { self == .en ? "Focus" : "Ostrość" }
    var cam: String { self == .en ? "Camera" : "Kamera" }
    var front: String { self == .en ? "Front" : "Przód" }
    var back: String { self == .en ? "Back" : "Tył" }
    var autoRot: String { self == .en ? "Auto Rotate" : "Auto-obrót" }
    var zoom: String { self == .en ? "Zoom" : "Zoom" }
    var exp: String { self == .en ? "Exposure" : "Ekspozycja" }
    var wb: String { self == .en ? "WB Lock" : "Blokada WB" }
    var hint: String { self == .en ? "Synced with PC • Scroll for more" : "Synchronizacja z PC • Przewiń po więcej" }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) { uiView.updateOrientation() }
    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
            updateOrientation()
        }
        func updateOrientation() {
            guard let c = previewLayer.connection, c.isVideoOrientationSupported else { return }
            switch window?.windowScene?.interfaceOrientation ?? .portrait {
            case .portrait: c.videoOrientation = .portrait
            case .portraitUpsideDown: c.videoOrientation = .portraitUpsideDown
            case .landscapeLeft: c.videoOrientation = .landscapeLeft
            case .landscapeRight: c.videoOrientation = .landscapeRight
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
            session.commitConfiguration()
            return
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
        if let c = session.outputs.first?.connection(with: .video), c.isVideoOrientationSupported {
            c.videoOrientation = .landscapeRight
        }
        session.commitConfiguration()

        let mz = min(dev.activeFormat.videoMaxZoomFactor, 6.0)
        DispatchQueue.main.async {
            self.isFrontCamera = front
            self.torchOn = false
            self.zoomFactor = 1.0
            self.maxZoom = max(mz, 1.0)
            self.exposureBias = 0.0
            self.wbLocked = false
            self.manualFocus = false
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
        let sc: [UInt8] = [0, 0, 0, 1]
        let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        if !(att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false), let desc = CMSampleBufferGetFormatDescription(sb) {
            for idx in 0...1 {
                var size = 0
                var ptr: UnsafePointer<UInt8>?
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: idx, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = ptr {
                    out.append(contentsOf: sc)
                    out.append(p, count: size)
                }
            }
        }
        guard let db = CMSampleBufferGetDataBuffer(sb) else { return }
        var total = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(db, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &rawPtr) == noErr, let ptr = rawPtr else { return }
        var offset = 0
        while offset + 4 <= total {
            var len: UInt32 = 0
            memcpy(&len, ptr.advanced(by: offset), 4)
            len = CFSwapInt32BigToHost(len)
            offset += 4
            guard offset + Int(len) <= total else { break }
            out.append(contentsOf: sc)
            ptr.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: Int(len)) { out.append($0, count: Int(len)) }
            offset += Int(len)
        }
        if !out.isEmpty { conn.send(content: out, completion: .idempotent) }
    }

    private func startUSBServer() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: 8888) else { return }
        l.newConnectionHandler = { [weak self] newConn in
            let ep = "\(newConn.endpoint)"
            guard ep.contains("127.0.0.1") || ep.contains("::1") || ep.contains("localhost") else {
                newConn.cancel()
                return
            }
            self?.connection?.cancel()
            self?.connection = newConn
            self?.rxBuffer.removeAll()
            newConn.stateUpdateHandler = { st in
                DispatchQueue.main.async {
                    if st == .ready { self?.isConnected = true; self?.lastOrient = ""; self?.sendOrientation() }
                    else if case .failed = st { self?.isConnected = false; self?.setTorch(false) }
                    else if st == .cancelled { self?.isConnected = false; self?.setTorch(false) }
                }
            }
            newConn.start(queue: self?.queue ?? .main)
            self?.readLoop(newConn)
        }
        l.start(queue: queue)
        listener = l
    }

    private func readLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let d = data {
                self.rxBuffer.append(d)
                while let nl = self.rxBuffer.firstRange(of: Data([0x0A])) {
                    let line = String(data: self.rxBuffer.subdata(in: 0..<nl.lowerBound), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.rxBuffer.removeSubrange(0...nl.lowerBound)
                    self.execCmd(line)
                }
            }
            if err == nil && !done { self.readLoop(conn) }
        }
    }

    private func execCmd(_ cmd: String) {
        if cmd == "TORCH:1" { setTorch(true) }
        else if cmd == "TORCH:0" { setTorch(false) }
        else if cmd == "AF" { setAutoFocus() }
        else if cmd == "MF" { setManualFocus(lensPosition) }
        else if cmd.hasPrefix("FOCUS:"), let v = Float(cmd.dropFirst(6)) { setManualFocus(min(max(v, 0), 1)) }
        else if cmd == "CAM:FRONT" { switchCamera(front: true) }
        else if cmd == "CAM:BACK" { switchCamera(front: false) }
        else if cmd.hasPrefix("ZOOM:"), let v = Double(cmd.dropFirst(5)) { setZoom(CGFloat(v)) }
        else if cmd.hasPrefix("EXP:"), let v = Float(cmd.dropFirst(4)) { setExposure(v) }
        else if cmd == "WB:LOCK" { setWBLock(true) }
        else if cmd == "WB:AUTO" { setWBLock(false) }
    }

    func switchCamera(front: Bool) { queue.async { [weak self] in self?.configureCamera(front: front) } }
    func setTorch(_ on: Bool) {
        queue.async { [weak self] in
            guard let d = self?.device, d.hasTorch else { return }
            try? d.lockForConfiguration()
            if on { try? d.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) } else { d.torchMode = .off }
            d.unlockForConfiguration()
            DispatchQueue.main.async { self?.torchOn = on }
        }
    }
    func setAutoFocus() {
        queue.async { [weak self] in
            guard let d = self?.device, d.isFocusModeSupported(.continuousAutoFocus) else { return }
            try? d.lockForConfiguration()
            d.focusMode = .continuousAutoFocus
            d.unlockForConfiguration()
            DispatchQueue.main.async { self?.manualFocus = false }
        }
    }
    func setManualFocus(_ pos: Float) {
        queue.async { [weak self] in
            guard let d = self?.device, d.isFocusModeSupported(.locked) else { return }
            try? d.lockForConfiguration()
            d.setFocusModeLocked(lensPosition: pos, completionHandler: nil)
            d.unlockForConfiguration()
            DispatchQueue.main.async { self?.manualFocus = true; self?.lensPosition = pos }
        }
    }
    func setZoom(_ z: CGFloat) {
        queue.async { [weak self] in
            guard let d = self?.device else { return }
            let c = min(max(z, 1.0), min(d.activeFormat.videoMaxZoomFactor, 6.0))
            try? d.lockForConfiguration()
            d.videoZoomFactor = c
            d.unlockForConfiguration()
            DispatchQueue.main.async { self?.zoomFactor = c }
        }
    }
    func setExposure(_ ev: Float) {
        queue.async { [weak self] in
            guard let d = self?.device else { return }
            let c = min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias)
            try? d.lockForConfiguration()
            d.setExposureTargetBias(c, completionHandler: nil)
            d.unlockForConfiguration()
            DispatchQueue.main.async { self?.exposureBias = c }
        }
    }
    func setWBLock(_ lock: Bool) {
        queue.async { [weak self] in
            guard let d = self?.device else { return }
            let m: AVCaptureDevice.WhiteBalanceMode = lock ? .locked : .continuousAutoWhiteBalance
            guard d.isWhiteBalanceModeSupported(m) else { return }
            try? d.lockForConfiguration()
            d.whiteBalanceMode = m
            d.unlockForConfiguration()
            DispatchQueue.main.async { self?.wbLocked = lock }
        }
    }
}

struct ContentView: View {
    @AppStorage("appLanguage") private var langRaw: String = AppLanguage.en.rawValue
    @StateObject private var cam = CameraStreamManager()
    private var l: AppLanguage { AppLanguage(rawValue: langRaw) ?? .en }

    var body: some View {
        ZStack {
            CameraPreviewView(session: cam.session).ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
                    HStack {
                        Text(l.title).font(.headline).foregroundColor(.white)
                        Spacer()
                        Button(l.badge) { langRaw = (l == .en) ? "PL" : "EN" }
                            .font(.subheadline.bold()).foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.black.opacity(0.55)).cornerRadius(8)
                    }.padding(.horizontal).padding(.top, 8)

                    HStack(spacing: 12) {
                        Image(systemName: cam.isConnected ? "video.fill" : "cable.connector")
                            .font(.title3).foregroundColor(cam.isConnected ? .green : .orange)
                            .frame(width: 40, height: 40)
                            .background((cam.isConnected ? Color.green : Color.orange).opacity(0.22)).clipShape(Circle())
                        Text(!cam.cameraAuthorized ? l.statusDenied : (cam.isConnected ? l.statusLive : l.statusWait))
                            .font(.subheadline.weight(.medium)).foregroundColor(.white)
                        Spacer()
                    }.padding(12).background(Color.black.opacity(0.55)).cornerRadius(14).padding(.horizontal)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        Button { cam.switchCamera(front: !cam.isFrontCamera) } label: {
                            ControlTile(icon: "arrow.triangle.2.circlepath.camera.fill", title: "\(l.cam): \(cam.isFrontCamera ? l.front : l.back)", active: cam.isFrontCamera, color: .purple)
                        }
                        Button { cam.setTorch(!cam.torchOn) } label: {
                            ControlTile(icon: cam.torchOn ? "flashlight.on.fill" : "flashlight.off.fill", title: l.torch, active: cam.torchOn, color: .yellow, darkText: true)
                        }.disabled(cam.isFrontCamera).opacity(cam.isFrontCamera ? 0.45 : 1)
                        Button { cam.manualFocus ? cam.setAutoFocus() : cam.setManualFocus(cam.lensPosition) } label: {
                            ControlTile(icon: cam.manualFocus ? "scope" : "viewfinder", title: "\(l.focus): \(cam.manualFocus ? "MF" : "AF")", active: cam.manualFocus, color: .blue)
                        }
                        Button { cam.autoOrientation.toggle(); if cam.autoOrientation { cam.sendOrientation() } } label: {
                            ControlTile(icon: "rectangle.portrait.rotate", title: l.autoRot, active: cam.autoOrientation, color: .green)
                        }
                    }.padding(.horizontal)

                    VStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(l.zoom): \(String(format: "%.1fx", cam.zoomFactor))").font(.caption.bold()).foregroundColor(.white)
                                Spacer()
                                Button("1.0x") { cam.setZoom(1.0) }.font(.caption2.bold()).foregroundColor(.cyan)
                            }
                            Slider(value: Binding(get: { Double(cam.zoomFactor) }, set: { cam.setZoom(CGFloat($0)) }), in: 1.0...Double(cam.maxZoom))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(l.exp): \(String(format: "%+.1f EV", cam.exposureBias))").font(.caption.bold()).foregroundColor(.white)
                                Spacer()
                                Button("0.0 EV") { cam.setExposure(0.0) }.font(.caption2.bold()).foregroundColor(.cyan)
                            }
                            Slider(value: Binding(get: { Double(cam.exposureBias) }, set: { cam.setExposure(Float($0)) }), in: -2.0...2.0)
                        }
                        Button { cam.setWBLock(!cam.wbLocked) } label: {
                            HStack {
                                Image(systemName: cam.wbLocked ? "lock.fill" : "sun.max.fill")
                                Text("\(l.wb): \(cam.wbLocked ? "ON" : "AUTO")").font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(cam.wbLocked ? Color.orange.opacity(0.85) : Color.white.opacity(0.16))
                            .foregroundColor(.white).cornerRadius(10)
                        }
                    }.padding(12).background(Color.black.opacity(0.55)).cornerRadius(14).padding(.horizontal)

                    Text(l.hint).font(.caption2).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal).padding(.bottom, 16)
                }
            }
        }.onAppear { cam.start() }.onDisappear { cam.stop() }
    }
}

struct ControlTile: View {
    let icon: String; let title: String; let active: Bool; let color: Color; var darkText = false
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption.bold()).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 11)
        .background(active ? color.opacity(0.85) : Color.black.opacity(0.55))
        .foregroundColor(active && darkText ? .black : .white).cornerRadius(12)
    }
}
