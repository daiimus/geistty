//
//  SFTPBrowserView.swift
//  Bodak
//
//  UI for browsing remote filesystems via SFTP
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.bodak", category: "SFTPBrowser")

/// View for browsing remote files over SFTP
struct SFTPBrowserView: View {
    let connection: ConnectionProfile
    
    @State private var client: SFTPClient?
    @State private var currentPath: String = "/"
    @State private var items: [SFTPFileAttributes] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedItem: SFTPFileAttributes?
    @State private var pathHistory: [String] = []
    @State private var showActionSheet = false
    @State private var downloadProgress: (current: Int64, total: Int64)?
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading && items.isEmpty {
                    ProgressView("Connecting...")
                } else if let error = error {
                    ContentUnavailableView {
                        Label("Connection Error", systemImage: "wifi.slash")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await connect() }
                        }
                    }
                } else {
                    fileList
                }
            }
            .navigationTitle(currentPath.components(separatedBy: "/").last ?? "Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { disconnect(); dismiss() }
                }
                
                ToolbarItem(placement: .principal) {
                    pathBreadcrumb
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        
                        Button {
                            // Create folder
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        
                        Button {
                            // Upload file
                        } label: {
                            Label("Upload", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await connect()
        }
        .onDisappear {
            disconnect()
        }
        .confirmationDialog(
            selectedItem?.name ?? "File",
            isPresented: $showActionSheet,
            titleVisibility: .visible
        ) {
            if let item = selectedItem {
                if !item.isDirectory {
                    Button("Download") {
                        Task { await downloadFile(item) }
                    }
                    
                    Button("Quick Look") {
                        Task { await previewFile(item) }
                    }
                }
                
                Button("Copy Path") {
                    let fullPath = (currentPath as NSString).appendingPathComponent(item.name)
                    UIPasteboard.general.string = fullPath
                }
                
                Button("Delete", role: .destructive) {
                    Task { await deleteItem(item) }
                }
            }
        }
    }
    
    private var fileList: some View {
        List {
            // Parent directory
            if currentPath != "/" {
                Button {
                    Task { await navigateUp() }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        Text("..")
                        Spacer()
                    }
                }
            }
            
            // Files and directories
            ForEach(items, id: \.name) { item in
                Button {
                    handleItemTap(item)
                } label: {
                    FileRow(item: item)
                }
                .contextMenu {
                    contextMenu(for: item)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await deleteItem(item) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await refresh()
        }
        .overlay {
            if isLoading && !items.isEmpty {
                ProgressView()
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            
            if let progress = downloadProgress {
                VStack {
                    ProgressView(value: Double(progress.current), total: Double(progress.total))
                    Text("Downloading... \(formatBytes(progress.current)) / \(formatBytes(progress.total))")
                        .font(.caption)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    private var pathBreadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    Task { await navigate(to: "/") }
                } label: {
                    Image(systemName: "house.fill")
                        .font(.caption)
                }
                
                let components = currentPath.split(separator: "/").map(String.init)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        let path = "/" + components[0...index].joined(separator: "/")
                        Task { await navigate(to: path) }
                    } label: {
                        Text(component)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: 200)
    }
    
    @ViewBuilder
    private func contextMenu(for item: SFTPFileAttributes) -> some View {
        if !item.isDirectory {
            Button {
                Task { await downloadFile(item) }
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            
            Button {
                Task { await previewFile(item) }
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
        }
        
        Button {
            let fullPath = (currentPath as NSString).appendingPathComponent(item.name)
            UIPasteboard.general.string = fullPath
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
        
        Divider()
        
        Button(role: .destructive) {
            Task { await deleteItem(item) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    
    // MARK: - Actions
    
    private func connect() async {
        isLoading = true
        error = nil
        
        do {
            let sftp = SFTPClient()
            
            // Try to get credentials
            if let keyName = connection.sshKeyName,
               let privateKeyData = try? KeychainManager.shared.getSSHKey(name: keyName) {
                // Connect with key
                try await sftp.connect(
                    host: connection.host,
                    port: connection.port,
                    username: connection.username,
                    privateKey: privateKeyData,
                    publicKey: nil,
                    passphrase: nil
                )
            } else {
                // Connect with password from keychain
                let password = try? KeychainManager.shared.getPassword(for: connection.host, username: connection.username)
                try await sftp.connect(
                    host: connection.host,
                    port: connection.port,
                    username: connection.username,
                    password: password ?? ""
                )
            }
            
            client = sftp
            currentPath = await sftp.pwd()
            await refresh()
            
        } catch {
            self.error = error.localizedDescription
            logger.error("❌ SFTP connection failed: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
    private func disconnect() {
        Task {
            await client?.disconnect()
            client = nil
        }
    }
    
    private func refresh() async {
        guard let client = client else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            items = try await client.listDirectory(currentPath)
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    private func handleItemTap(_ item: SFTPFileAttributes) {
        if item.isDirectory {
            Task { await navigate(to: (currentPath as NSString).appendingPathComponent(item.name)) }
        } else {
            selectedItem = item
            showActionSheet = true
        }
    }
    
    private func navigate(to path: String) async {
        guard let client = client else { return }
        
        pathHistory.append(currentPath)
        
        do {
            try await client.cd(path)
            currentPath = await client.pwd()
            await refresh()
        } catch {
            self.error = error.localizedDescription
            pathHistory.removeLast()
        }
    }
    
    private func navigateUp() async {
        let parent = (currentPath as NSString).deletingLastPathComponent
        await navigate(to: parent)
    }
    
    private func downloadFile(_ item: SFTPFileAttributes) async {
        guard let client = client else { return }
        
        let remotePath = (currentPath as NSString).appendingPathComponent(item.name)
        
        do {
            downloadProgress = (0, Int64(item.size))
            
            let data = try await client.readFile(remotePath) { current, total in
                Task { @MainActor in
                    downloadProgress = (current, total)
                }
            }
            
            downloadProgress = nil
            
            // Save to temporary directory and share
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(item.name)
            try data.write(to: tempURL)
            
            // Use UIActivityViewController to share
            await MainActor.run {
                let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
            }
            
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
            downloadProgress = nil
        }
    }
    
    private func previewFile(_ item: SFTPFileAttributes) async {
        // For now, just download small text files and show them
        guard item.size < 1024 * 1024 else { // 1MB limit for preview
            error = "File too large to preview"
            return
        }
        
        await downloadFile(item)
    }
    
    private func deleteItem(_ item: SFTPFileAttributes) async {
        guard let client = client else { return }
        
        let remotePath = (currentPath as NSString).appendingPathComponent(item.name)
        
        do {
            if item.isDirectory {
                try await client.rmdir(remotePath)
            } else {
                try await client.unlink(remotePath)
            }
            await refresh()
        } catch {
            self.error = "Delete failed: \(error.localizedDescription)"
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Row view for a file/directory item
struct FileRow: View {
    let item: SFTPFileAttributes
    
    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    if !item.isDirectory {
                        Text(formatSize(item.size))
                    }
                    if let date = item.modificationDate {
                        Text(formatDate(date))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var iconName: String {
        if item.isDirectory {
            return "folder.fill"
        } else if item.isSymlink {
            return "link"
        } else {
            return fileIcon(for: item.name)
        }
    }
    
    private var iconColor: Color {
        if item.isDirectory {
            return .blue
        } else if item.isSymlink {
            return .purple
        } else {
            return .secondary
        }
    }
    
    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "markdown":
            return "doc.text"
        case "swift", "h", "m", "c", "cpp", "py", "js", "ts", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "xml", "yaml", "yml", "toml":
            return "curlybraces"
        case "jpg", "jpeg", "png", "gif", "bmp", "svg", "webp":
            return "photo"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "mp4", "mov", "avi", "mkv", "webm":
            return "film"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return "archivebox"
        case "sh", "bash", "zsh":
            return "terminal"
        default:
            return "doc"
        }
    }
    
    private func formatSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    SFTPBrowserView(connection: ConnectionProfile(
        name: "Test",
        host: "example.com",
        port: 22,
        username: "user"
    ))
}
