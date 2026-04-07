import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let itemProvider = extensionItem.attachments?.first else {
            completeRequest()
            return
        }

        if itemProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            itemProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                if let text = item as? String {
                    self?.saveToApp(text: text)
                }
            }
        } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            itemProvider.loadItem(forTypeIdentifier: UTType.image.identifier) { [weak self] item, _ in
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    self?.saveToApp(imageData: data)
                }
            }
        } else {
            completeRequest()
        }
    }

    private func saveToApp(text: String? = nil, imageData: Data? = nil) {
        var sharedItems: [[String: Any]] = []
        if let text = text {
            sharedItems.append(["type": "text", "content": text])
        }
        if let imageData = imageData {
            sharedItems.append(["type": "image", "data": imageData.base64EncodedString()])
        }

        UserDefaults(suiteName: "group.com.ollamakit.app")?.set(sharedItems, forKey: "pendingShare")
        completeRequest()
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
