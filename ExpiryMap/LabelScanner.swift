import SwiftUI
import PhotosUI
import UIKit
import AVFoundation
import Vision
import ImageIO

@MainActor
struct LabelScannerSheet: View {
    let onRecognized: (LabelScanResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var lastPhoto: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var pendingCameraImage: UIImage?
    @State private var showingCamera = false
    @State private var cameraAccessDenied = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var workID = UUID()
    @State private var workTask: Task<Void, Never>?
    @State private var permissionTask: Task<Void, Never>?

    private let accent = Color(red: 0.65, green: 0.73, blue: 0.97)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    preview
                    VStack(spacing: 9) {
                        Text(isWorking ? "正在读标签上的文字" : "拍清名称和到期日期")
                            .font(.title3.bold())
                        Text("让标签正对镜头，避免反光。识别后仍需核对，再保存记录。")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if isWorking {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在这台 iPhone 上识别…").font(.subheadline)
                        }.padding(16)
                    }
                    if let errorMessage {
                        VStack(spacing: 12) {
                            Text(errorMessage).font(.subheadline)
                                .multilineTextAlignment(.center)
                            if cameraAccessDenied {
                                Button("前往设置开启相机") { openSettings() }
                                    .font(.subheadline.bold())
                            } else if previewImage != nil {
                                Button("重新识别这张照片") {
                                    if let previewImage { recognize(previewImage) }
                                }.font(.subheadline.bold())
                            } else if let lastPhoto {
                                Button("重新载入这张照片") { loadPhoto(lastPhoto) }
                                    .font(.subheadline.bold())
                            }
                        }
                        .padding(18).frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 22))
                        .accessibilityElement(children: .contain)
                    }
                    VStack(spacing: 12) {
                        Button(action: requestCamera) {
                            Label("拍摄标签", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent).tint(.black)
                        PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                            Label("从相册选一张", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                        }
                        .buttonStyle(.bordered).tint(.black)
                    }.disabled(isWorking)
                    if !UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Text("这台设备没有可用相机，可以从相册选择标签照片。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Label("照片仅用于本次本机识别，不上传、不保存副本。", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .background(Color(red: 0.98, green: 0.98, blue: 0.99))
            .navigationTitle("拍照记一件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelWork(); dismiss() }
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                if let item { loadPhoto(item) }
            }
            .fullScreenCover(isPresented: $showingCamera, onDismiss: {
                if let image = pendingCameraImage {
                    pendingCameraImage = nil
                    recognize(image)
                }
            }) {
                LabelCameraPicker { image in
                    pendingCameraImage = image
                    showingCamera = false
                }.ignoresSafeArea()
            }
            .onDisappear { cancelWork() }
        }
    }

    @ViewBuilder private var preview: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .accessibilityLabel("待识别的标签照片")
        } else {
            VStack(spacing: 14) {
                Image(systemName: "viewfinder").font(.system(size: 64, weight: .light))
                Text("名称 · 有效期至 / EXP").font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity).frame(height: 225)
            .background(accent, in: RoundedRectangle(cornerRadius: 30))
            .accessibilityElement(children: .combine)
        }
    }

    private func requestCamera() {
        errorMessage = nil
        cameraAccessDenied = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "这台设备没有可用相机，请从相册选择标签照片。"
            return
        }
        permissionTask?.cancel()
        permissionTask = Task {
            let permitted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: permitted = true
            case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for: .video)
            default: permitted = false
            }
            guard !Task.isCancelled else { return }
            if permitted {
                showingCamera = true
            } else {
                cameraAccessDenied = true
                errorMessage = "相机权限未开启。你可以在设置中允许相机，或直接从相册选择照片。"
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        let id = beginWork()
        lastPhoto = item
        previewImage = nil
        workTask = Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = Self.thumbnail(from: data) else { throw LabelScanError.unreadablePhoto }
                guard !Task.isCancelled, workID == id else { return }
                previewImage = image
                let text = try await LabelVisionJob().recognize(image)
                deliver(text, for: id)
            } catch {
                show(error, for: id)
            }
            if workID == id { selectedPhoto = nil }
        }
    }

    private func recognize(_ image: UIImage) {
        let id = beginWork()
        lastPhoto = nil
        previewImage = image
        workTask = Task {
            do {
                let text = try await LabelVisionJob().recognize(image)
                deliver(text, for: id)
            } catch {
                show(error, for: id)
            }
        }
    }

    private func beginWork() -> UUID {
        workTask?.cancel()
        workID = UUID()
        errorMessage = nil
        cameraAccessDenied = false
        isWorking = true
        return workID
    }

    private func deliver(_ text: String, for id: UUID) {
        guard !Task.isCancelled, workID == id else { return }
        isWorking = false
        onRecognized(LabelParser.parse(text))
    }

    private func show(_ error: Error, for id: UUID) {
        guard !Task.isCancelled, workID == id, !(error is CancellationError) else { return }
        isWorking = false
        errorMessage = (error as? LabelScanError)?.errorDescription
            ?? "这次没能识别照片，请重试，或换一张清晰的标签照片。"
    }

    private func cancelWork() {
        workID = UUID()
        workTask?.cancel()
        permissionTask?.cancel()
        isWorking = false
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private static func thumbnail(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3_200
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private enum LabelScanError: LocalizedError {
    case unreadablePhoto
    case noText
    var errorDescription: String? {
        switch self {
        case .unreadablePhoto: return "无法载入这张照片，请重新选择。若照片保存在 iCloud，请先在相册中打开它。"
        case .noText: return "没有读到清楚的文字。请靠近标签、避开反光，再拍一张。"
        }
    }
}

private final class LabelVisionJob: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false

    func recognize(_ image: UIImage) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard let cgImage = image.cgImage else { throw LabelScanError.unreadablePhoto }
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                        request.automaticallyDetectsLanguage = true
                        request.usesLanguageCorrection = true
                        guard self.install(request) else { throw CancellationError() }
                        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: Self.orientation(image.imageOrientation))
                        try handler.perform([request])
                        guard !self.wasCancelled else { throw CancellationError() }
                        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { throw LabelScanError.noText }
                        continuation.resume(returning: text)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func install(_ request: VNRecognizeTextRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.request = request
        return true
    }

    private var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let current = request
        lock.unlock()
        current?.cancel()
    }

    private static func orientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

private struct LabelCameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
