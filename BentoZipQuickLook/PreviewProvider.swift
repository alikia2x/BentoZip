import BentoZipCore
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let preview = await ArchiveQuickPreviewFormatter.shared.renderHTMLPreview(for: request.fileURL)
        let htmlData = Data(preview.html.utf8)
        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 780, height: 600)
        ) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8
            return htmlData
        }
        reply.title = request.fileURL.lastPathComponent
        return reply
    }
}
