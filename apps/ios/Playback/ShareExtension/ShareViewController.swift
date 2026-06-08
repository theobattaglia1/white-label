import UIKit
import UniformTypeIdentifiers

private let playbackAppGroupID = "group.inc.allmyfriends.playback"
private let sharedInboxName = "IncomingAudio"

final class ShareViewController: UIViewController {
    private let brandColor = UIColor(red: 0.95, green: 0.91, blue: 0.82, alpha: 1)
    private let panelColor = UIColor(red: 0.08, green: 0.06, blue: 0.045, alpha: 1)
    private let pencilColor = UIColor(red: 0.62, green: 0.57, blue: 0.50, alpha: 1)

    private var stagedFileName: String?
    private var loadFailed = false

    private let statusLabel = UILabel()
    private let fileLabel = UILabel()
    private let detailLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusIcon = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 0, height: 390)
        buildInterface()
        loadAudioAttachment()
    }

    private func buildInterface() {
        view.backgroundColor = .black

        let backdrop = DotBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = panelColor
        card.layer.cornerRadius = 26
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = brandColor.withAlphaComponent(0.08).cgColor
        card.layer.borderWidth = 1
        view.addSubview(card)

        let logo = UILabel()
        logo.text = "P"
        logo.textAlignment = .center
        logo.textColor = .black
        logo.font = .systemFont(ofSize: 17, weight: .bold)
        logo.backgroundColor = brandColor
        logo.layer.cornerRadius = 17
        logo.layer.masksToBounds = true
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 34),
            logo.heightAnchor.constraint(equalToConstant: 34)
        ])

        let wordmark = UILabel()
        wordmark.text = "PLAYBACK"
        wordmark.textColor = brandColor
        wordmark.font = .systemFont(ofSize: 22, weight: .heavy)

        let brandStack = UIStackView(arrangedSubviews: [logo, wordmark])
        brandStack.axis = .horizontal
        brandStack.spacing = 8
        brandStack.alignment = .center

        let titleLabel = UILabel()
        titleLabel.text = "Add audio"
        titleLabel.textColor = brandColor
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)

        statusLabel.text = "Preparing file"
        statusLabel.textColor = pencilColor
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.text = statusLabel.text?.uppercased()
        statusLabel.letterSpacing(2)

        let fileRow = UIView()
        fileRow.translatesAutoresizingMaskIntoConstraints = false
        fileRow.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        fileRow.layer.cornerRadius = 16
        fileRow.layer.cornerCurve = .continuous
        fileRow.layer.borderColor = brandColor.withAlphaComponent(0.08).cgColor
        fileRow.layer.borderWidth = 1

        let musicIcon = UIImageView(image: UIImage(systemName: "waveform"))
        musicIcon.translatesAutoresizingMaskIntoConstraints = false
        musicIcon.tintColor = brandColor
        musicIcon.contentMode = .scaleAspectFit

        fileLabel.text = "Audio file"
        fileLabel.textColor = brandColor
        fileLabel.font = .systemFont(ofSize: 18, weight: .regular)
        fileLabel.lineBreakMode = .byTruncatingMiddle

        detailLabel.text = "MP3 · M4A · WAV · AIFF"
        detailLabel.textColor = pencilColor
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.letterSpacing(1.4)

        let fileTextStack = UIStackView(arrangedSubviews: [fileLabel, detailLabel])
        fileTextStack.axis = .vertical
        fileTextStack.spacing = 4

        spinner.color = brandColor
        spinner.startAnimating()

        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.isHidden = true

        let accessoryStack = UIStackView(arrangedSubviews: [spinner, statusIcon])
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.axis = .vertical
        accessoryStack.alignment = .center

        let fileStack = UIStackView(arrangedSubviews: [musicIcon, fileTextStack, accessoryStack])
        fileStack.translatesAutoresizingMaskIntoConstraints = false
        fileStack.axis = .horizontal
        fileStack.spacing = 13
        fileStack.alignment = .center
        fileRow.addSubview(fileStack)

        actionButton.setTitle("ADD TO PLAYBACK", for: .normal)
        actionButton.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        actionButton.setTitleColor(.black, for: .normal)
        actionButton.backgroundColor = brandColor.withAlphaComponent(0.45)
        actionButton.layer.cornerRadius = 24
        actionButton.layer.cornerCurve = .continuous
        actionButton.isEnabled = false
        actionButton.addTarget(self, action: #selector(openPlayback), for: .touchUpInside)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cancelButton.setTitleColor(pencilColor, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let contentStack = UIStackView(arrangedSubviews: [brandStack, titleLabel, statusLabel, fileRow, actionButton, cancelButton])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 15
        contentStack.alignment = .fill
        card.addSubview(contentStack)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),

            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -18),

            fileRow.heightAnchor.constraint(equalToConstant: 78),
            fileStack.leadingAnchor.constraint(equalTo: fileRow.leadingAnchor, constant: 15),
            fileStack.trailingAnchor.constraint(equalTo: fileRow.trailingAnchor, constant: -15),
            fileStack.centerYAnchor.constraint(equalTo: fileRow.centerYAnchor),
            musicIcon.widthAnchor.constraint(equalToConstant: 28),
            musicIcon.heightAnchor.constraint(equalToConstant: 28),
            statusIcon.widthAnchor.constraint(equalToConstant: 22),
            statusIcon.heightAnchor.constraint(equalToConstant: 22),
            accessoryStack.widthAnchor.constraint(equalToConstant: 24),
            actionButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    private func loadAudioAttachment() {
        guard let attachment = firstAudioAttachment() else {
            showError("No audio file found")
            return
        }

        attachment.provider.loadFileRepresentation(forTypeIdentifier: attachment.typeIdentifier) { [weak self] url, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
                return
            }
            guard let url else {
                DispatchQueue.main.async { self.showError("That file could not be opened") }
                return
            }

            do {
                let staged = try self.stageAudioFile(
                    url,
                    suggestedName: attachment.provider.suggestedName,
                    typeIdentifier: attachment.typeIdentifier
                )
                DispatchQueue.main.async { self.showReady(fileName: staged.lastPathComponent) }
            } catch {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
        }
    }

    private func firstAudioAttachment() -> (provider: NSItemProvider, typeIdentifier: String)? {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if let type = provider.registeredTypeIdentifiers.first(where: { identifier in
                    guard let itemType = UTType(identifier) else { return false }
                    return itemType.conforms(to: .audio)
                }) {
                    return (provider, type)
                }
            }
        }
        return nil
    }

    private func stageAudioFile(_ sourceURL: URL, suggestedName: String?, typeIdentifier: String) throws -> URL {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: playbackAppGroupID) else {
            throw ShareImportError.sharedInboxUnavailable
        }

        let inbox = container.appendingPathComponent(sharedInboxName, isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let suggestedBaseName = suggestedName.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
        let fallbackName = sourceURL.deletingPathExtension().lastPathComponent
        let baseName = sanitizedFileName(suggestedBaseName ?? fallbackName)
        let preferredExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "m4a"
        let ext = sourceURL.pathExtension.isEmpty ? preferredExtension : sourceURL.pathExtension.lowercased()
        let destination = inbox.appendingPathComponent("\(baseName).\(ext)")

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func showReady(fileName: String) {
        stagedFileName = fileName
        spinner.stopAnimating()
        spinner.isHidden = true
        statusIcon.image = UIImage(systemName: "checkmark.circle.fill")
        statusIcon.tintColor = UIColor(red: 0.37, green: 0.82, blue: 0.50, alpha: 1)
        statusIcon.isHidden = false
        fileLabel.text = displayName(fileName)
        detailLabel.text = "READY TO REVIEW IN PLAYBACK"
        detailLabel.letterSpacing(1.4)
        statusLabel.text = "Audio ready"
        statusLabel.letterSpacing(2)
        actionButton.isEnabled = true
        actionButton.backgroundColor = brandColor
    }

    private func showError(_ message: String) {
        loadFailed = true
        spinner.stopAnimating()
        spinner.isHidden = true
        statusIcon.image = UIImage(systemName: "exclamationmark.triangle.fill")
        statusIcon.tintColor = UIColor(red: 1.0, green: 0.32, blue: 0.19, alpha: 1)
        statusIcon.isHidden = false
        statusLabel.text = "Import unavailable"
        statusLabel.letterSpacing(2)
        fileLabel.text = "Could not prepare file"
        detailLabel.text = message.uppercased()
        detailLabel.letterSpacing(1.4)
        actionButton.isEnabled = false
        actionButton.backgroundColor = brandColor.withAlphaComponent(0.35)
    }

    @objc private func openPlayback() {
        guard !loadFailed, let stagedFileName else { return }
        var components = URLComponents()
        components.scheme = "playback"
        components.host = "import-audio"
        components.queryItems = [URLQueryItem(name: "file", value: stagedFileName)]

        guard let url = components.url else {
            showError("Playback link could not be created")
            return
        }

        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self?.showError("Open Playback and add from Library")
                }
            }
        }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: ShareImportError.cancelled)
    }

    private func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = value.lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .reduce("") { partial, char in
                if char == "-", partial.last == "-" { return partial }
                return partial + char
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "audio" : slug
    }

    private func displayName(_ fileName: String) -> String {
        URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

private enum ShareImportError: LocalizedError {
    case sharedInboxUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sharedInboxUnavailable:
            return "Playback shared import inbox is unavailable."
        case .cancelled:
            return "Import cancelled."
        }
    }
}

private final class DotBackdropView: UIView {
    override func draw(_ rect: CGRect) {
        UIColor.black.setFill()
        UIRectFill(rect)

        let dotColor = UIColor(white: 1, alpha: 0.07)
        dotColor.setFill()
        let spacing: CGFloat = 42
        for row in 0...Int(rect.height / spacing) {
            for col in 0...Int(rect.width / spacing) {
                let offset = CGFloat(row % 2) * 13
                let x = CGFloat(col) * spacing + offset
                let y = CGFloat(row) * spacing + 8
                let size = CGFloat((row + col) % 3 + 2)
                UIBezierPath(ovalIn: CGRect(x: x, y: y, width: size, height: size)).fill()
            }
        }
    }
}

private extension UILabel {
    func letterSpacing(_ value: CGFloat) {
        guard let text else { return }
        attributedText = NSAttributedString(
            string: text,
            attributes: [
                .kern: value,
                .font: font as Any,
                .foregroundColor: textColor as Any
            ]
        )
    }
}
