import SwiftUI
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
                    .padding(12)
                    .background(.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(.bottom, 30)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true // Blokada wygaszania ekranu
            streamer.start()
        }
    }
}

// Podgląd na ekranie iPhone'a
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

class CameraStreamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var statusText = "Inicjalizacja kamery..."
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var compressionSession: VTCompressionSession?
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "video.capture.queue")
    
    func start() {
        setupServer()
        setupCamera()
        setupEncoder(width: 3840, height: 2160) // 4K
    }
    
    // 1. Serwer TCP nasłuchujący na porcie 8888 (dla kabla USB przez iproxy)
    private func setupServer() {
        do {
            listener = try NWListener(using: .tcp, on: 8888)
            listener?.newConnectionHandler = { [weak self] connection in
                self?.activeConnection?.cancel()
                self?.activeConnection = connection
                connection.start(queue: self?.queue ?? .main)
                DispatchQueue.main.async { self?.statusText = "Połączono z PC (4K 60fps)" }
            }
            listener?.start(queue: queue)
            DispatchQueue.main.async { self.statusText = "Oczekiwanie na PC (Port 8888)..." }
        } catch {
            DispatchQueue.main.async { self.statusText = "Błąd sieci: \(error.localizedDescription)" }
        }
    }
    
    // 2. Konfiguracja sensora w maksymalnej jakości (4K 60 FPS)
    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .hd4K3840x2160
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        
        if session.canAddInput(input) { session.addInput(input) }
        
        // Wymuszenie 60 FPS
        do {
            try device.lockForConfiguration()
            for format in device.formats {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if dimensions.width == 3840 && dimensions.height == 2160 {
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
        session.commitConfiguration()
        
        queue.async { self.session.startRunning() }
    }
    
    // 3. Sprzętowy koder H.264 (VideoToolbox)
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
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AverageBitRate, value: 40_000_000 as CFNumber) // 40 Mbps!
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // Zero B-frames = brak opóźnień
        VTCompressionSessionPrepareToEncodeFrames(cs)
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard activeConnection != nil,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cs = compressionSession else { return }
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(cs, imageBuffer: imageBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
    
    fileprivate func sendEncodedData(_ data: Data) {
        activeConnection?.send(content: data, completion: .contentProcessed { _ in })
    }
}

// Callback wyciągający nagłówki SPS/PPS oraz klatki H.264 w formacie Annex-B
private let encodingOutputCallback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, _, sampleBuffer in
    guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
    let streamer = Unmanaged<CameraStreamer>.fromOpaque(refCon).takeUnretainedValue()
    
    let startCode = Data([0x00, 0x00, 0x00, 0x01])
    var payload = Data()
    
    // Jeśli to klatka kluczowa (I-Frame), doklej parametry SPS i PPS
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
    
    // Konwersja jednostek NAL z AVCC na Annex-B
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
Krok 2: Odbiornik na Windows (Python + Wirtualna Kamera)
Na komputerze z Windowsem potrzebujesz:

OBS Studio (zainstaluj je – nie musisz go nawet otwierać, potrzebujemy tylko zainstalowanego w systemie sterownika OBS Virtual Camera).

libimobiledevice dla Windows (pobierz paczkę z GitHuba libimobiledevice-win32, wypakuj – znajduje się tam program iproxy.exe, który robi tunel USB).

Python 3.10+ oraz dwie biblioteki zainstalowane w terminalu:

Bash
pip install av pyvirtualcam numpy
Zapisz poniższy kod jako receiver.py:

Python
import socket
import av
import pyvirtualcam

HOST = '127.0.0.1'
PORT = 8888
WIDTH = 3840
HEIGHT = 2160
FPS = 60

def main():
    print(f"Łączenie z iPhonem przez tunel USB ({HOST}:{PORT})...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((HOST, PORT))
    
    # Tworzymy strumień plikopodobny z gniazda sieciowego dla dekodera FFmpeg (PyAV)
    stream = sock.makefile('rb')
    container = av.open(stream, format='h264')
    
    print("Uruchamianie wirtualnej kamery w systemie Windows (4K 60 FPS)...")
    with pyvirtualcam.Camera(width=WIDTH, height=HEIGHT, fps=FPS, fmt=pyvirtualcam.PixelFormat.RGB) as cam:
        print(f"Gotowe! Wybierz '{cam.device}' w Discordzie, Zoomie lub OBS.")
        for frame in container.decode(video=0):
            # Konwersja klatki na tablicę RGB i wysłanie do sterownika kamery
            img = frame.to_ndarray(format='rgb24')
            cam.send(img)
            cam.sleep_until_next_frame()

if __name__ == '__main__':
    main()
Jak to uruchomić krok po kroku:
Podłącz iPhone'a SE kablem USB do PC i uruchom swoją aplikację na telefonie.

W wierszu poleceń (CMD) na Windowsie uruchom tunel USB:

Bash
iproxy.exe 8888 8888
W drugim oknie terminala uruchom odbiornik:

Bash
python receiver.py
W dowolnym programie na Windowsie (Zoom, Teams, Discord, przeglądarka) wybierz kamerę OBS Virtual Camera. Otrzymasz pełne 4K 60 FPS przy 40 Mbps całkowicie za darmo i bez żadnych znaków wodnych.

(Wskazówka: Jeśli Twój procesor na Windowsie będzie mocno obciążony dekodowaniem 4K w Pythonie, możesz w kodzie Swifta i Pythona zmienić rozdzielczość na 1920x1080 – i tak zmiażdży jakością każdą kamerę internetową na rynku, a zużycie CPU spadnie czterokrotnie).

Czy masz dostęp do komputera Mac / Xcode, żeby skompilować część na iOS, czy potrzebujesz podpowiedzi, jak to ogarnąć na samym Windowsie?
