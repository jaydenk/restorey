import AppKit
import PDFKit
import RestoreyCore

/// The recovery kit on paper or in a PDF (UI design §7: copy each field, print, save to a location the user picks).
/// Both are the same pages, laid out here in memory, values in full; nothing is written anywhere but where the user
/// saves it. (Printing hands the pages to macOS's print system, as any printing does.)
@MainActor
enum RecoveryKitExport {
    struct SaveError: Error, CustomStringConvertible {
        let description: String
    }

    /// Writes the kit as a PDF at `url`, readable only by this user where the volume keeps permissions.
    static func savePDF(_ document: RecoveryKitDocument, to url: URL) throws {
        // Created with its permissions, not written and then narrowed.
        guard FileManager.default.createFile(
            atPath: url.path, contents: pdfData(document), attributes: [.posixPermissions: 0o600])
        else {
            throw SaveError(description: "Restorey couldn't save the recovery kit to \(url.path).")
        }
    }

    /// The print panel, for the user's printer (or the panel's own PDF menu), with the PDF's pages.
    static func print(_ document: RecoveryKitDocument) {
        guard let pages = PDFDocument(data: pdfData(document)),
            let operation = pages.printOperation(for: NSPrintInfo(), scalingMode: .pageScaleNone, autoRotate: false)
        else { return }
        operation.jobTitle = title(document)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    /// The volume holding `url` (or its nearest existing folder) is the Mac's internal, fixed disk
    /// (`RecoveryKitLocation`). A volume that doesn't say counts as internal.
    static func isOnInternalDisk(_ url: URL) -> Bool {
        var place = url
        while !FileManager.default.fileExists(atPath: place.path), place.pathComponents.count > 1 {
            place = place.deletingLastPathComponent()
        }
        let values = try? place.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey])
        return RecoveryKitLocation.isOnInternalDisk(isInternal: values?.volumeIsInternal, isRemovable: values?.volumeIsRemovable)
    }

    static func title(_ document: RecoveryKitDocument) -> String {
        "Restorey recovery kit — \(document.planName)"
    }

    /// A file name for the save panel: the title, without characters a file name can't hold.
    static func fileName(_ document: RecoveryKitDocument) -> String {
        title(document).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".pdf"
    }

    /// The kit's pages, on the default paper size (A4 in Australia): the text laid out in one page-sized text
    /// container per page, so a page breaks between lines, and drawn into a PDF context in memory. (AppKit's
    /// `pdfOperation(with:inside:to:)` makes one page as tall as the view instead; its print pipeline paginates
    /// only into a file.) The text stays text, so it can be selected and copied from the PDF.
    static func pdfData(_ document: RecoveryKitDocument) -> Data {
        let paper = NSPrintInfo().paperSize
        let margin = NSEdgeInsets(top: 48, left: 54, bottom: 48, right: 54)
        let printable = CGSize(width: paper.width - margin.left - margin.right, height: paper.height - margin.top - margin.bottom)
        let storage = NSTextStorage(attributedString: text(document))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: printable)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            // A page that takes nothing would repeat for ever.
            if range.length == 0 || NSMaxRange(range) >= layout.numberOfGlyphs { break }
        }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            // The text system draws top down.
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let range = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin.left, y: margin.top)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func text(_ document: RecoveryKitDocument) -> NSAttributedString {
        let ink = NSColor.black
        let quiet = NSColor.darkGray
        let out = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, _ colour: NSColor = ink, after spacing: CGFloat = 4) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = spacing
            out.append(NSAttributedString(string: string + "\n", attributes: [
                .font: font, .foregroundColor: colour, .paragraphStyle: paragraph,
            ]))
        }
        add(title(document), .boldSystemFont(ofSize: 18), after: 2)
        add("Made \(document.createdAt.formatted(date: .long, time: .shortened)).", .systemFont(ofSize: 10), quiet)
        add(RecoveryKitText.why, .systemFont(ofSize: 11), after: 12)
        let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        for section in document.sections {
            add(section.title, .boldSystemFont(ofSize: 13), after: 4)
            if section.title == RecoveryKitText.restoreSection { add(RecoveryKitText.restoreIntro, .systemFont(ofSize: 10.5), quiet) }
            for field in section.fields {
                add(field.label, .systemFont(ofSize: 10, weight: .medium), quiet, after: 1)
                add(field.value, mono, after: 8)
            }
            add("", .systemFont(ofSize: 4), after: 4)
        }
        add(RecoveryKitText.keepItSafe, .systemFont(ofSize: 10.5), quiet)
        return out
    }
}

/// The kit's own sentences, shared by the screen and the printed kit.
enum RecoveryKitText {
    static let why =
        "Without this you can't restore if this Mac is lost. It's the address, password and keys, and how to restore without Restorey."
    static let keepItSafe =
        "Store it off this Mac (a password manager, or paper). Restorey never saves a copy on the Mac."
    static let restoreSection = "Restore without Restorey"
    static let restoreIntro =
        "Install restic (restic.net), then paste these into Terminal in order. The files go to a folder called Restored in your home folder."
    static let reconfirmHeading = "Save a new recovery kit — the saved one has the old keys"
    static let savedTick = "I've saved it somewhere other than this Mac"
}
