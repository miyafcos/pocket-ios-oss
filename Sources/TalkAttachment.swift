import UIKit

/// The reduction a picked photo goes through before upload: the web app's
/// rule (app.js IMAGE_ATTACH_*), so the phone and the browser send the same
/// thing. The server takes a JSON body of 6 MB, base64 included, which is
/// about 4.5 MB of picture; a full-size phone photo came back 413 on
/// 2026-09-15 when nothing was reduced.
enum TalkAttachment {
    static let maxDimension: CGFloat = 2000
    static let quality: CGFloat = 0.85
    static let maxBytes = 4 * 1024 * 1024

    /// JPEG data no wider or taller than `maxDimension`, or nil when even the
    /// reduced picture is over the byte limit.
    static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scaled: UIImage
        if longest > maxDimension, longest > 0 {
            let scale = maxDimension / longest
            let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1 // pixels, not points: the picker's image already carries the photo's own scale
            scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else if image.scale != 1 {
            // A 1x re-render so the JPEG's pixel count is the point size, as for a scaled photo.
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            scaled = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        } else {
            scaled = image
        }
        guard let data = scaled.jpegData(compressionQuality: quality), data.count <= maxBytes else { return nil }
        return data
    }
}
