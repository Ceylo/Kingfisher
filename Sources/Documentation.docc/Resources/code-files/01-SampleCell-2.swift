#if canImport(UIKit)
import UIKit
#endif

class SampleCell: UITableViewCell {
    var sampleImageView: UIImageView = {
        let imageView = UIImageView(frame: .zero)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()
}
