#if canImport(UIKit)
import UIKit
#endif
import Kingfisher

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        print(KingfisherManager.shared)
    }
}
