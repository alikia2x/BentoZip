import SwiftUI
import BentoZipCore

struct FileListView: View {
    @Environment(AppState.self) private var appState

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { appState.selectedEntryIDs },
            set: { appState.selectedEntryIDs = $0 }
        )
    }

    private var entries: [FileEntry] {
        appState.displayedEntries.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Table(entries, selection: selectionBinding) {
            TableColumn("名称") { entry in
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: entry))
                        .foregroundStyle(entry.isDirectory ? Color(hex: "#53b7e7") : iconForegroundColor(for: entry))
                        .font(.system(size: 14))
                    Text(entry.name)
                }
            }
            .width(min: 120, ideal: 240)

            TableColumn("大小") { entry in
                if entry.isDirectory {
                    Text(entry.isDirectory ? "\(entry.children?.count ?? 0) 项" : "—")
                        .foregroundStyle(.secondary)
                } else {
                    Text(formatSize(entry.size))
                }
            }
            .width(min: 60, ideal: 80)

            TableColumn("类型") { entry in
                Text(entry.isDirectory ? "文件夹" : fileTypeDescription(for: entry))
            }
            .width(min: 60, ideal: 80)

            TableColumn("修改日期") { entry in
                if let date = entry.modificationDate {
                    Text(formatDate(date))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 140)
        }
        .onKeyPress(.return) {
            navigateIntoSelection()
            return .handled
        }
        .contextMenu(forSelectionType: UUID.self) { selection in
            if let selected = selection.first,
               let entry = entries.first(where: { $0.id == selected }) {
                if entry.isDirectory {
                    Button("打开") {
                        appState.navigateInto(entry)
                    }
                }
                Divider()
                Button("复制路径") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(entry.url.path, forType: .string)
                }
            }
        } primaryAction: { selection in
            guard let selected = selection.first,
                  let entry = entries.first(where: { $0.id == selected }),
                  entry.isDirectory else { return }
            appState.navigateInto(entry)
        }
    }

    private func navigateIntoSelection() {
        guard let selected = appState.selectedEntryIDs.first,
              let entry = entries.first(where: { $0.id == selected }),
              entry.isDirectory else { return }
        appState.navigateInto(entry)
    }

    private func iconName(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        let ext = entry.url.pathExtension.lowercased()
        switch ext {
        case "zip", "zipx": return "doc.zipper"
        case "7z": return "doc.zipper"
        case "tar", "gz", "tgz", "bz2", "xz": return "doc.zipper"
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "tiff", "bmp", "svg", "heic": return "photo.fill"
        case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
        case "mp4", "mov", "avi", "mkv": return "film.fill"
        case "txt", "md", "rtf": return "doc.text.fill"
        case "json", "xml", "yaml", "yml": return "doc.text"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp": return "chevron.left.forwardslash.chevron.right"
        case "dmg", "iso": return "opticaldiscdrive"
        default: return "doc.fill"
        }
    }

    private func iconForegroundColor(for entry: FileEntry) -> Color {
        let ext = entry.url.pathExtension.lowercased()
        switch ext {
        case "zip", "zipx", "7z", "tar", "gz", "tgz", "bz2", "xz": return .yellow
        case "pdf": return .red
        case "jpg", "jpeg", "png", "gif", "tiff", "bmp", "svg", "heic": return Color(hex: "#53b7e7")
        case "mp3", "wav", "aac", "flac", "m4a": return .pink
        case "mp4", "mov", "avi", "mkv": return .purple
        default: return .secondary
        }
    }

    private func fileTypeDescription(for entry: FileEntry) -> String {
        let ext = entry.url.pathExtension
        if ext.isEmpty { return "—" }
        return ext.uppercased()
    }

    private func formatSize(_ size: Int64) -> String {
        let bytes = Double(size)
        if bytes < 1000 {
            return "\(size) B"
        } else if bytes < 1000 * 1000 {
            return String(format: "%.1f kB", bytes / 1000)
        } else if bytes < 1000 * 1000 * 1000 {
            return String(format: "%.1f MB", bytes / (1000 * 1000))
        } else {
            return String(format: "%.1f GB", bytes / (1000 * 1000 * 1000))
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    FileListView()
        .environment(AppState())
        .environment(ProgressState())
}
