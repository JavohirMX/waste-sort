import UltralyticsYOLO

enum YOLOViewPredictorAccess {
    static func setCapturesOriginalImage(_ enabled: Bool, in view: YOLOView) {
        predictor(in: view)?.capturesOriginalImage = enabled
    }

    static func predictor(in view: YOLOView) -> BasePredictor? {
        let mirror = Mirror(reflecting: view)
        for child in mirror.children where child.label == "videoCapture" {
            if let capture = child.value as? VideoCapture {
                return capture.predictor as? BasePredictor
            }
        }
        return nil
    }
}
