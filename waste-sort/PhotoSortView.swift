import PhotosUI
import SwiftUI
import UltralyticsYOLO

struct PhotoSortView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var model: YOLO?
    @State private var isLoadingModel = true
    @State private var isInferring = false
    @State private var sourceImage: UIImage?
    @State private var annotatedImage: UIImage?
    @State private var detections: [Box] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pickerButton

                    if isLoadingModel {
                        ProgressView("Loading model")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isInferring {
                        ProgressView("Sorting")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if annotatedImage != nil || sourceImage != nil {
                        results
                    } else {
                        emptyState
                    }
                }
                .padding(20)
            }
            .background(Color(red: 246 / 255, green: 247 / 255, blue: 242 / 255))
            .navigationTitle("Waste Sort")
            .task { loadModel() }
            .onChange(of: pickerItem) { _, newItem in
                Task { await importPhoto(newItem) }
            }
        }
    }

    private var pickerButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            Text("Choose photo")
                .font(.system(.headline, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(BinGuide.organic.color)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isLoadingModel || isInferring)
        .accessibilityHint("Opens the photo library to sort a waste image")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Point the camera, or pick a photo.")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text("Items are sorted into organic, residual, or clean inorganic.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let annotatedImage {
                Image(uiImage: annotatedImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if let sourceImage {
                Image(uiImage: sourceImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Text(detections.isEmpty ? "No items found" : "\(detections.count) item\(detections.count == 1 ? "" : "s")")
                .font(.system(.title3, design: .rounded).weight(.semibold))

            ForEach(Array(detections.enumerated()), id: \.offset) { _, box in
                DetectionRow(className: box.cls, confidence: box.conf)
            }
        }
    }

    private func loadModel() {
        guard model == nil else {
            isLoadingModel = false
            return
        }

        // YOLO's async loader captures `[weak self]`. Keep the instance in
        // `@State` immediately so the completion can fire.
        let yolo = YOLO(WasteSortConfig.modelName, task: .segment) { result in
            Task { @MainActor in
                switch result {
                case .success(let loaded):
                    loaded.setConfidenceThreshold(WasteSortConfig.confidence)
                    isLoadingModel = false
                case .failure(let error):
                    model = nil
                    errorMessage = "Could not load model: \(error.localizedDescription)"
                    isLoadingModel = false
                }
            }
        }
        model = yolo
    }

    private func importPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                errorMessage = "Could not read that photo."
                return
            }
            await runInference(on: image)
        } catch {
            errorMessage = "Could not read that photo."
        }
    }

    private func runInference(on image: UIImage) async {
        guard let model else {
            errorMessage = "Model is not ready yet."
            return
        }

        errorMessage = nil
        sourceImage = image
        isInferring = true
        detections = []
        annotatedImage = nil

        let result = await Task.detached(priority: .userInitiated) {
            model(image)
        }.value

        annotatedImage = result.annotatedImage ?? image
        let minConf = Float(WasteSortConfig.confidence)
        detections = result.boxes.filter { $0.conf >= minConf }
        isInferring = false
    }
}
