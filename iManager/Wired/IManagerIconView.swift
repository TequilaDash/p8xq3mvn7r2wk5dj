import SwiftUI

struct IManagerIconView: View {
    var size: CGFloat = 29

    var body: some View {
        Group {
            if let image = Self.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }

    private final class BundleToken {}

    private static let image: UIImage? = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "IManagerIcon", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()
}
