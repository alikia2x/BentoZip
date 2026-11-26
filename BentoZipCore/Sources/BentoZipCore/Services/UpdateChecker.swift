import Foundation
import Observation

/// Semantic Version parser and comparator (SemVer 2.0.0) supporting optional leading `v` and pre-release tags.
public struct SemVer: Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
        let trimmed = prerelease?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prerelease = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public init?(string: String) {
        var cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty else { return nil }

        // Strip build metadata (+...) which does not affect precedence.
        if let plusIndex = cleaned.firstIndex(of: "+") {
            cleaned = String(cleaned[..<plusIndex])
        }

        let coreString: String
        let prereleaseString: String?
        if let dashIndex = cleaned.firstIndex(of: "-") {
            coreString = String(cleaned[..<dashIndex])
            let pre = String(cleaned[cleaned.index(after: dashIndex)...])
            prereleaseString = pre.isEmpty ? nil : pre
        } else {
            coreString = cleaned
            prereleaseString = nil
        }

        let parts = coreString.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        guard let major = Int(parts[0]), major >= 0 else { return nil }

        let minor: Int
        if parts.count >= 2 {
            guard let parsed = Int(parts[1]), parsed >= 0 else { return nil }
            minor = parsed
        } else {
            minor = 0
        }

        let patch: Int
        if parts.count == 3 {
            guard let parsed = Int(parts[2]), parsed >= 0 else { return nil }
            patch = parsed
        } else {
            patch = 0
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prereleaseString
    }

    public var description: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (_?, nil):
            // Pre-release has lower precedence than normal release.
            return true
        case (nil, _?):
            return false
        case (let lPre?, let rPre?):
            let lIds = lPre.split(separator: ".").map(String.init)
            let rIds = rPre.split(separator: ".").map(String.init)
            for (lId, rId) in zip(lIds, rIds) {
                if lId == rId { continue }
                let lNum = Int(lId)
                let rNum = Int(rId)
                switch (lNum, rNum) {
                case (let ln?, let rn?):
                    return ln < rn
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lId < rId
                }
            }
            return lIds.count < rIds.count
        }
    }
}

/// Metadata for a GitHub Release returned by the GitHub Releases API.
public struct GitHubReleaseInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: String { tagName }
    public let tagName: String
    public let name: String
    public let body: String
    public let htmlURL: URL
    public let publishedAt: Date?
    public let downloadURL: URL?

    public var version: SemVer? {
        SemVer(string: tagName)
    }

    public init(
        tagName: String,
        name: String,
        body: String,
        htmlURL: URL,
        publishedAt: Date? = nil,
        downloadURL: URL? = nil
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.downloadURL = downloadURL
    }
}

/// Errors raised when validating an update release payload.
public enum UpdateCheckError: LocalizedError, Sendable, Equatable {
    case insecureReleaseURL(String)

    public var errorDescription: String? {
        switch self {
        case .insecureReleaseURL(let urlString):
            return String(localized: "Update release URL must use HTTPS: \(urlString)", bundle: .module)
        }
    }
}

/// Current state of an update check.
public enum UpdateCheckStatus: Sendable, Equatable {
    case idle
    case checking
    case updateAvailable(GitHubReleaseInfo)
    case upToDate(currentVersion: String)
    case failed(String)
}

/// Zero-dependency update checker backed by the GitHub Releases API.
@Observable
@MainActor
public final class UpdateChecker {
    public nonisolated static let defaultOwner = "alikia2x"
    public nonisolated static let defaultRepo = "BentoZip"

    public private(set) var status: UpdateCheckStatus = .idle
    public private(set) var lastCheckedAt: Date?
    public let currentVersion: String
    public let endpointURL: URL

    private let session: URLSession

    public init(
        owner: String = UpdateChecker.defaultOwner,
        repo: String = UpdateChecker.defaultRepo,
        endpointURL: URL? = nil,
        currentVersion: String? = nil,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
            ?? URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
            ?? URL(fileURLWithPath: "/")
        self.currentVersion = currentVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.0.0"
        self.session = session
    }

    /// Query the configured GitHub Releases endpoint and compare against `currentVersion`.
    @discardableResult
    public func checkForUpdates() async -> UpdateCheckStatus {
        status = .checking

        var request = URLRequest(url: endpointURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BentoZip/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let message = String(localized: "Update server returned HTTP \(http.statusCode).", bundle: .module)
                status = .failed(message)
                return status
            }

            let release = try Self.parseRelease(from: data)
            lastCheckedAt = Date()

            if Self.isNewer(remoteTag: release.tagName, than: currentVersion) {
                status = .updateAvailable(release)
            } else {
                status = .upToDate(currentVersion: currentVersion)
            }
            return status
        } catch is CancellationError {
            status = .idle
            return status
        } catch {
            status = .failed(error.localizedDescription)
            return status
        }
    }

    /// Return `true` when `remoteTag` parses as a higher semantic version than `currentVersion`.
    public nonisolated static func isNewer(remoteTag: String, than currentVersion: String) -> Bool {
        guard let remote = SemVer(string: remoteTag),
              let current = SemVer(string: currentVersion) else {
            return false
        }
        return remote > current
    }

    /// Decode a GitHub `/releases/latest` JSON payload into `GitHubReleaseInfo`.
    public nonisolated static func parseRelease(from data: Data) throws -> GitHubReleaseInfo {
        struct AssetDTO: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        struct ReleaseDTO: Decodable {
            let tagName: String
            let name: String?
            let body: String?
            let htmlURL: URL
            let publishedAt: String?
            let assets: [AssetDTO]?

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case name
                case body
                case htmlURL = "html_url"
                case publishedAt = "published_at"
                case assets
            }
        }

        let dto = try JSONDecoder().decode(ReleaseDTO.self, from: data)

        guard dto.htmlURL.scheme?.lowercased() == "https" else {
            throw UpdateCheckError.insecureReleaseURL(dto.htmlURL.absoluteString)
        }

        let publishedDate: Date? = dto.publishedAt.flatMap { raw in
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = withFraction.date(from: raw) {
                return parsed
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            return standard.date(from: raw)
        }

        let httpsAssets = (dto.assets ?? []).filter {
            $0.browserDownloadURL.scheme?.lowercased() == "https"
        }
        let preferredAsset = httpsAssets.first { $0.name.lowercased().hasSuffix(".dmg") }
            ?? httpsAssets.first { $0.name.lowercased().hasSuffix(".zip") }

        let displayName = (dto.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (dto.name ?? dto.tagName)
            : dto.tagName

        return GitHubReleaseInfo(
            tagName: dto.tagName,
            name: displayName,
            body: dto.body ?? "",
            htmlURL: dto.htmlURL,
            publishedAt: publishedDate,
            downloadURL: preferredAsset?.browserDownloadURL
        )
    }
}
