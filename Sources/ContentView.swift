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
                Spacer()
                Text(streamer.statusText)
                    .padding(10)
                    .background(.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            streamer.start()
        }
    }
}

// Widok podglądu automatycznie dopasowujący się do poziomego ekranu
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
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var compressionSession: VTCompressionSession?
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "video.capture.queue")
    private var forceKeyFrame = false

    func start() {
        setupServer()
        setupCamera()
        setupEncoder(width: 1920, height: 1080)
    }

    private func setupServer() {
        do {
            listener = try NWListener(using: .tcp, on: 8888)
            listener?.newConnectionHandler = { [weak self] connection in
                self?.activeConnection?.cancel()
                self?.activeConnection = connection
                self?.forceKeyFrame = true
                connection.start(queue: self?.queue ?? .main)
                DispatchQueue.main.async { self?.statusText = "Połączono z PC (1080p 60fps)" }
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
            device.unlockForConfiguration()
        } catch {}

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // Wymuszenie poziomej orientacji strumienia wysyłanego do PC
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
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AverageBitRate, value: 12_000_000 as CFNumber)
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
Weryfikacja: Plik ContentView.swift zapisał się bez błędów i ma 202 linie.

Krok 3: Przebuduj plik .ipa i zaktualizuj aplikację na iPhonie
Wejdź w zakładkę Actions -> Build iOS IPA -> Run workflow -> zielony Run workflow.

Po zakończeniu pobierz nowy artefakt iPhoneWebcam-IPA, rozpakuj iPhoneWebcam.ipa i wgraj go przez Sideloadly na iPhone'a SE (nadpisze poprzednią wersję).

Otwórz aplikację na telefonie — interfejs automatycznie obróci się w tryb poziomy (trzymaj telefon poziomo, aparatem u góry po lewej stronie).Weryfikacja: Podgląd na ekranie telefonu wypełnia cały poziomy ekran, a napis na dole znajduje się przy dłuższej krawędzi.

Krok 4: Zaktualizuj C:\Kamera\receiver.py (dekoder bez bufora i bez opóźnień)
Zatrzymaj poprzedni skrypt w konsoli (Ctrl + C), wpisz notepad receiver.py w folderze C:\Kamera, podmień kod na poniższy (używa surowego dekodera CodecContext bez buforowania kontenera) i zapisz (Ctrl + S):

Python
import socket
import av
import pyvirtualcam

HOST = '127.0.0.1'
PORT = 8888
WIDTH = 1920
HEIGHT = 1080
FPS = 60

def main():
    print(f"Łączenie z iPhonem ({HOST}:{PORT})...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.connect((HOST, PORT))

    # Bezpośredni dekoder H.264 bez buforowania kontenera (zero opóźnień)
    codec = av.CodecContext.create('h264', 'r')
    codec.thread_type = 'AUTO'

    print("Uruchamianie wirtualnej kamery (1080p 60 FPS, tryb natychmiastowy)...")
    with pyvirtualcam.Camera(width=WIDTH, height=HEIGHT, fps=FPS, fmt=pyvirtualcam.PixelFormat.RGB) as cam:
        print(f"Gotowe! Wybierz '{cam.device}' w OBS lub komunikatorze.")
        while True:
            data = sock.recv(65536)
            if not data:
                break
            for packet in codec.parse(data):
                for frame in codec.decode(packet):
                    img = frame.to_ndarray(width=WIDTH, height=HEIGHT, format='rgb24')
                    cam.send(img)

if __name__ == '__main__':
    main()
