import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 抠主体：苹果系统自带的「抠出前景」（跟相册里长按把猫拎起来是同一个东西）。抠不出来返回 nil，调用方当整张照片用。
public enum Cutout {
    public static func liftSubject(_ image: Data) async -> Data? {
        guard let src = CGImageSourceCreateWithData(image as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first, !obs.allInstances.isEmpty,
              let masked = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: masked)
        let ctx = CIContext()
        guard let out = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
