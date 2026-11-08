import UserNotifications

/// 🖼 Mitteilungen mit Vorschaubild: der PC legt ein kleines JPEG (Base64, »vorschau«) in den Push - hier wird es als
/// Anhang eingehängt (kein Netz nötig, funktioniert auch unterwegs). Schnellaktionen kommen über die Kategorie.
final class MitteilungDienst: UNNotificationServiceExtension {
    private var fertig: ((UNNotificationContent) -> Void)?
    private var inhalt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        fertig = contentHandler
        let c = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        inhalt = c
        if let b64 = c.userInfo["vorschau"] as? String, let daten = Data(base64Encoded: b64) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            if (try? daten.write(to: url)) != nil,
               let anhang = try? UNNotificationAttachment(identifier: "vorschau", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]) {
                c.attachments = [anhang]
            }
        }
        contentHandler(c)
    }

    override func serviceExtensionTimeWillExpire() {
        if let f = fertig, let c = inhalt { f(c) }
    }
}
