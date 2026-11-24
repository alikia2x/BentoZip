import AppKit
import BentoZipCore

enum FinderColumnID {
    static let name = NSUserInterfaceItemIdentifier("name")
    static let date = NSUserInterfaceItemIdentifier("date")
    static let size = NSUserInterfaceItemIdentifier("size")
    static let packed = NSUserInterfaceItemIdentifier("packed")
    static let kind = NSUserInterfaceItemIdentifier("kind")
}

@MainActor
enum FinderOutlineCellFactory {
    private static let lockImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        return NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }()

    static func makeView(
        for columnID: NSUserInterfaceItemIdentifier,
        node: FileNode,
        in outlineView: NSOutlineView
    ) -> NSView? {
        switch columnID {
        case FinderColumnID.name:
            let cell = dequeueOrCreate(
                FinderNameCellView.self,
                identifier: columnID,
                in: outlineView
            )
            cell.configure(node: node, lockImage: lockImage)
            return cell

        case FinderColumnID.date:
            let cell = dequeueOrCreate(
                FinderTextCellView.self,
                identifier: columnID,
                in: outlineView
            ) { view in
                view.configureStyle(alignment: .left, monospacedDigits: true)
            }
            if let date = node.modificationDate {
                cell.setText(FileListFormatters.dateFormatter.string(from: date), isPlaceholder: false)
            } else {
                cell.setText("--", isPlaceholder: true)
            }
            return cell

        case FinderColumnID.size:
            let cell = dequeueOrCreate(
                FinderTextCellView.self,
                identifier: columnID,
                in: outlineView
            ) { view in
                view.configureStyle(alignment: .right, monospacedDigits: true)
            }
            if node.isDirectory {
                if node.size > 0 {
                    cell.setText(FileListFormatters.byteFormatter.string(fromByteCount: node.size), isPlaceholder: false)
                } else {
                    cell.setText("--", isPlaceholder: true)
                }
            } else {
                cell.setText(FileListFormatters.byteFormatter.string(fromByteCount: node.size), isPlaceholder: false)
            }
            return cell

        case FinderColumnID.packed:
            let cell = dequeueOrCreate(
                FinderTextCellView.self,
                identifier: columnID,
                in: outlineView
            ) { view in
                view.configureStyle(alignment: .right, monospacedDigits: true)
            }
            if let packed = node.packedSize, !node.isDirectory, packed > 0 {
                cell.setText(FileListFormatters.byteFormatter.string(fromByteCount: packed), isPlaceholder: false)
            } else {
                cell.setText("--", isPlaceholder: true)
            }
            return cell

        case FinderColumnID.kind:
            let cell = dequeueOrCreate(
                FinderTextCellView.self,
                identifier: columnID,
                in: outlineView
            ) { view in
                view.configureStyle(alignment: .left, monospacedDigits: false)
            }
            cell.setText(FileKindCache.localizedKind(for: node), isPlaceholder: false)
            return cell

        default:
            return nil
        }
    }

    private static func dequeueOrCreate<T: NSTableCellView>(
        _ type: T.Type,
        identifier: NSUserInterfaceItemIdentifier,
        in outlineView: NSOutlineView,
        setup: ((T) -> Void)? = nil
    ) -> T {
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? T {
            return reused
        }
        let created = T(frame: .zero)
        created.identifier = identifier
        setup?(created)
        return created
    }
}

@MainActor
private final class FinderNameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let lockView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = NSFont.systemFont(ofSize: 13)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        lockView.contentTintColor = .secondaryLabelColor
        lockView.imageScaling = .scaleProportionallyDown
        lockView.isHidden = true
        lockView.setContentHuggingPriority(.required, for: .horizontal)
        lockView.setContentCompressionResistancePriority(.required, for: .horizontal)
        lockView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, titleField, lockView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            lockView.widthAnchor.constraint(equalToConstant: 12),
            lockView.heightAnchor.constraint(equalToConstant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        self.imageView = iconView
        self.textField = titleField
    }

    func configure(node: FileNode, lockImage: NSImage?) {
        iconView.image = FileIconCache.icon(for: node)
        titleField.stringValue = node.name
        lockView.image = lockImage
        lockView.isHidden = !node.isEncrypted
    }
}

@MainActor
private final class FinderTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        self.textField = label
    }

    func configureStyle(alignment: NSTextAlignment, monospacedDigits: Bool) {
        label.alignment = alignment
        label.font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
    }

    func setText(_ text: String, isPlaceholder: Bool) {
        label.stringValue = text
        label.textColor = isPlaceholder ? .tertiaryLabelColor : .secondaryLabelColor
    }
}
