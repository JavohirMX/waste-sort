import PhotosUI
import SwiftUI
import UltralyticsYOLO

struct PhotoSortView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pickerItem: PhotosPickerItem?
    @State private var model: YOLO?
    @State private var isLoadingModel = true
    @State private var isInferring = false
    @State private var sourceImage: UIImage?
    @State private var fused: [FusedPhotoDetection] = []
    /// User resolutions for unsure items, keyed by detection index.
    @State private var overrides: [Int: String] = [:]
    @State private var errorMessage: String?

    private var photoTracks: [TrackedDetection] {
        fused.enumerated().map { index, item in
            let overridden = overrides[index]
            let classKey = overridden ?? item.classKey
            return TrackedDetection(
                id: index + 1,
                classKey: classKey,
                className: BinGuide.bin(id: classKey).title,
                conf: item.conf,
                displayXywhn: item.box.xywhn,
                beliefUncertain: item.wasUncertain && overridden == nil
            )
        }
    }

    var body: some View {
        ScrollView {
            Group {
                if isLoadingModel {
                    ProgressView("Loading model")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.system(.body, design: .default))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isInferring {
                    ProgressView("Sorting")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if sourceImage != nil {
                    resultsLayout
                } else {
                    emptyState
                }
            }
            .padding(20)
        }
        .background(Theme.photoBackground)
        .navigationTitle("Sort photo")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("Choose photo", systemImage: "photo.on.rectangle")
                        .font(.system(.body, design: .default).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(BinGuide.organic.color, in: Capsule())
                }
                .disabled(isLoadingModel || isInferring)
                .accessibilityHint("Opens the photo library to sort a waste image")
            }
        }
        .task { loadModel() }
        .onChange(of: pickerItem) { _, newItem in
            Task { await importPhoto(newItem) }
        }
        .onChange(of: settings.selectedModelName) { _, _ in
            reloadModel()
        }
        .environment(\.hudTextScale, CGFloat(settings.hudTextScale))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            pickerButton

            VStack(alignment: .leading, spacing: 8) {
                Text("Point the camera, or pick a photo.")
                    .font(.system(.title3, design: .default).weight(.semibold))
                Text("Items are sorted into Organic, Residual, or Recyclable.")
                    .font(.system(.body, design: .default))
                    .foregroundStyle(.secondary)
            }

            CategoryBar(counts: [:])
                .opacity(0.85)
                .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    private var pickerButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            Text("Choose photo")
                .font(.system(.headline, design: .default))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(BinGuide.organic.color)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isLoadingModel || isInferring)
        .accessibilityHint("Opens the photo library to sort a waste image")
    }

    @ViewBuilder
    private var resultsLayout: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 20) {
                annotatedImage
                    .frame(maxWidth: .infinity)
                resultsList
                    .frame(maxWidth: 420)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                annotatedImage
                resultsList
            }
        }
    }

    private var annotatedImage: some View {
        Group {
            if let sourceImage {
                Color.clear
                    .aspectRatio(sourceImage.size, contentMode: .fit)
                    .overlay {
                        Image(uiImage: sourceImage)
                            .resizable()
                            .scaledToFit()
                    }
                    .overlay {
                        GeometryReader { geo in
                            DetectionBoxOverlay(
                                tracks: photoTracks,
                                imageSize: sourceImage.size,
                                viewSize: geo.size,
                                useAspectFill: false,
                                style: settings.boxOverlayStyle
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(fused.isEmpty ? "No items found" : "\(fused.count) item\(fused.count == 1 ? "" : "s")")
                .font(.system(.title3, design: .default).weight(.semibold))

            CategoryBar(counts: photoCounts)
                .padding(.bottom, 4)

            ForEach(fused.indices, id: \.self) { index in
                DetectionRow(
                    classKey: overrides[index] ?? fused[index].classKey,
                    confidence: fused[index].conf
                )
                if fused[index].wasUncertain, overrides[index] == nil {
                    resolveChip(index: index)
                }
            }
        }
    }

    /// Two-button resolution for an unsure photo item; photo mode is not
    /// throughput-bound, so asking beats guessing.
    private func resolveChip(index: Int) -> some View {
        HStack(spacing: 8) {
            Text("Not sure about this one?")
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.secondary)
            Button(BinGuide.cleanInorganic.displayName.capitalized) {
                overrides[index] = BinGuide.cleanInorganic.id
            }
            .buttonStyle(.bordered)
            .tint(BinGuide.cleanInorganic.color)
            Button("Residual") { overrides[index] = BinGuide.residual.id }
                .buttonStyle(.borderedProminent)
                .tint(BinGuide.residual.color)
        }
    }

    private var photoCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for track in photoTracks {
            counts[track.advisedBinID, default: 0] += 1
        }
        return counts
    }

    private func loadModel() {
        guard model == nil else {
            isLoadingModel = false
            return
        }
        beginModelLoad(named: settings.selectedModelName)
    }

    private func reloadModel() {
        model = nil
        isLoadingModel = true
        errorMessage = nil
        beginModelLoad(named: settings.selectedModelName)
    }

    private func beginModelLoad(named name: String) {
        // YOLO's async loader captures `[weak self]`. Keep the instance in
        // `@State` immediately so the completion can fire.
        let yolo = YOLO(name, task: .segment) { result in
            Task { @MainActor in
                switch result {
                case .success(let loaded):
                    applyThresholds(loaded)
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
        fused = []
        overrides = [:]

        applyThresholds(model)
        let minConf = Float(settings.confidence)
        let color = settings.runtime.frameColor.clamped
        let prepared: UIImage
        if color.isIdentity {
            prepared = image
        } else {
            let adjusted = FrameColorAdjuster.apply(color, to: FrameColorAdjuster.ciImage(from: image))
            prepared = FrameColorAdjuster.uiImage(from: adjusted) ?? image
        }
        sourceImage = prepared

        // Two-pass ensemble: the mirror pass supplies a second opinion without a
        // second model; disagreement is what powers the unsure state below.
        let result = await Task.detached(priority: .userInitiated) {
            let flipped = FrameColorAdjuster.uiImage(
                from: FrameColorAdjuster.ciImage(from: prepared).oriented(.upMirrored)
            ) ?? prepared
            return (model(prepared), model(flipped))
        }.value

        var priors: [AppearancePrior?] = []
        if settings.appearanceAssistEnabled {
            let sampler = BoxAppearanceSampler()
            for box in result.0.boxes where box.conf >= minConf {
                priors.append(
                    sampler.sample(image: prepared, rectNorm: box.xywhn)
                        .map { AppearanceAnalyzer.prior(for: $0) }
                )
            }
        }

        let fusedDetections = PhotoDetectionFuser.fuse(
            passes: [
                Array(result.0.boxes.filter { $0.conf >= minConf }),
                Array(result.1.boxes.filter { $0.conf >= minConf })
            ],
            priors: priors
        )
        fused = fusedDetections
        isInferring = false
    }

    private func applyThresholds(_ model: YOLO) {
        model.setConfidenceThreshold(settings.confidence)
        model.setIouThreshold(settings.iou)
        model.setNumItemsThreshold(settings.maxItems)
    }
}
