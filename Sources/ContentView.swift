import SwiftUI
import Combine
import AVFoundation
import VideoToolbox
import Network

struct ContentView: View {
    @StateObject private var streamer = CameraStreamer()
    
    var body: some View {
        ZStack {
            CameraPreview(session: streamer.session)
                .ignoresSafeArea()
            
            VStack {
                // Górny pasek sterowania (Latarka + Tryb AF/MF)
                HStack(spacing: 12) {
                    Button(action: { streamer.toggleTorch() }) {
                        HStack(spacing: 6) {
                            Image(systemName: streamer.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            Text(streamer.isTorchOn ? "Latarka: WŁ." : "Latarka: WYŁ.")
                        }
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(streamer.isTorchOn ? Color.yellow.opacity(0.9) : Color.black.opacity(0.65))
                        .foregroundColor(streamer.isTorchOn ? .black : .white)
                        .cornerRadius(10)
                    }
                    
                    Button(action: { streamer.toggleFocusMode() }) {
                        HStack(spacing: 6) {
                            Image(systemName: streamer.isManualFocus ? "hand.tap.fill" : "camera.metering.center.weighted")
                            Text(streamer.isManualFocus ? "Focus: Ręczny (MF)" : "Focus: Auto (AF)")
                        }
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(streamer.isManualFocus ? Color.blue.opacity(0.85) : Color.black.opacity(0.65))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                Spacer()
                
                // Suwak ręcznej ostrości (widoczny tylko w trybie MF)
                if streamer.isManualFocus {
                    HStack(spacing: 12) {
                        Text("Blisko")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        
                        Slider(
                            value: Binding(
                                get: { streamer.focusPosition },
                                set: { streamer.setManualFocus($0) }
                            ),
                            in: 0.0...1.0
                        )
                        .accentColor(.yellow)
                        
                        Text("Daleko")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(10)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 6)
                }
                
                // Pasek statusu połączenia
                Text(streamer.statusText)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.bottom, 14)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            streamer.start()
        }
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            let interfaceOrientation = window?.windowScene?.interfaceOrientation ?? .landscapeRight
            connection.videoOrientation = interfaceOrientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewContainerView, context: Context) {}
}

class CameraStreamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var statusText = "Inicjalizacja kamery..."
    @Published var isTorchOn = false
    @Published var isManualFocus = false
    @Published var focusPosition: Float = 0.5
    
    let session = AVCaptureSession()
    private var captureDevice: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    private var compressionSession: VTCompressionSession?
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "video.capture.queue", qos: .userInteractive)
    private var forceKeyFrame = false
    
    func start() {
        setupServer()
        setupCamera()
        setupEncoder(width: 1920, height: 1080)
    }
    
    func toggleTorch() {
        guard let device = captureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if device.torchMode == .on {
                device.torchMode = .off
                DispatchQueue.main.async { self.isTorchOn = false }
            } else {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                DispatchQueue.main.async { self.isTorchOn = true }
            }
            device.unlockForConfiguration()
        } catch {}
    }
    
    func toggleFocusMode() {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            if isManualFocus {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                DispatchQueue.main.async { self.isManualFocus = false }
            } else {
                if device.isFocusModeSupported(.locked) {
                    let currentPos = device.lensPosition
                    device.setFocusModeLocked(lensPosition: currentPos, completionHandler: nil)
                    DispatchQueue.main.async {
                        self.focusPosition = currentPos
                        self.isManualFocus = true
                    }
                }
            }
            device.unlockForConfiguration()
        } catch {}
    }
    
    func setManualFocus(_ value: Float) {
        focusPosition = value
        guard isManualFocus, let device = captureDevice, device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: value, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {}
    }
    
    private func setupServer() {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            
            listener = try NWListener(using: params, on: 8888)
            listener?.newConnectionHandler = { [weak self] connection in
                self?.activeConnection?.cancel()
                self?.activeConnection = connection
                self?.forceKeyFrame = true
                connection.start(queue: self?.queue ?? .main)
                DispatchQueue.main.async { self?.statusText = "Połączono (Low-Latency 1080p)" }
            }
            listener?.start(queue: queue)
            DispatchQueue.main.async { self.statusText = "Oczekiwanie na PC (Port 8888)..." }
        } catch {
            DispatchQueue.main.async { self.statusText = "Błąd sieci: \(error.localizedDescription)" }
        }
    }
    
    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        
        self.captureDevice = device
        if session.canAddInput(input) { session.addInput(input) }
        
        do {
            try device.lockForConfiguration()
            for format in device.formats {
                let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if dim.width == 1920 && dim.height == 1080 {
                    for range in format.videoSupportedFrameRateRanges {
                        if range.maxFrameRate >= 60 {
                            device.activeFormat = format
                            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
                            break
                        }
                    }
                }
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {}
        
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
    }
    
    private func setupEncoder(width: Int32, height: Int32) {
        VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )
        guard let cs = compressionSession else { return }
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AverageBitRate, value: 10_000_000 as CFNumber)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(cs)
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard activeConnection != nil,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cs = compressionSession else { return }
        
        var props: CFDictionary? = nil
        if forceKeyFrame {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyFrame = false
        }
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(cs, imageBuffer: imageBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
    
    fileprivate func sendEncodedData(_ data: Data) {
        activeConnection?.send(content: data, completion: .contentProcessed { _ in })
    }
}

private let encodingOutputCallback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, _, sampleBuffer in
    guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
    let streamer = Unmanaged<CameraStreamer>.fromOpaque(refCon).takeUnretainedValue()
    
    let startCode = Data([0x00, 0x00, 0x00, 0x01])
    var payload = Data()
    
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
       let attachment = attachments.first,
       !(attachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false),
       let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
        
        var spsSize = 0, spsCount = 0
        var spsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)
        
        var ppsSize = 0, ppsCount = 0
        var ppsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil)
        
        if let sps = spsPointer, let pps = ppsPointer {
            payload.append(startCode)
            payload.append(sps, count: spsSize)
            payload.append(startCode)
            payload.append(pps, count: ppsSize)
        }
    }
    
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    
    var offset = 0
    while offset < totalLength - 4, let ptr = dataPointer {
        var nalLength: UInt32 = 0
        memcpy(&nalLength, ptr.advanced(by: offset), 4)
        nalLength = CFSwapInt32BigToHost(nalLength)
        
        payload.append(startCode)
        payload.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr.advanced(by: offset + 4)).assumingMemoryBound(to: UInt8.self), count: Int(nalLength)))
        offset += 4 + Int(nalLength)
    }
    
    streamer.sendEncodedData(payload)
}
