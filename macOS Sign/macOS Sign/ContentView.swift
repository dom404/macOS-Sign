//
//  macOS_SignApp.swift
//  macOS Sign
//
//  Created by Dominic Carpenter on 08/09/2025.

import SwiftUI
import UniformTypeIdentifiers // Add this import


//MARK: ContentView.swift
import SwiftUI
import Security
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = SigningViewModel()
    @State private var showFilePicker = false
    @State private var dragOver = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("macOS Sign")
                .font(.title)
                .fontWeight(.bold)
            
            // File selection area
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(dragOver ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
                        )
                    
                    if let fileURL = viewModel.selectedFile {
                        VStack {
                            Image(systemName: fileIconName(for: fileURL))
                                .font(.system(size: 32))
                                .foregroundColor(.blue)
                            Text(fileURL.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                            Text("Click to choose a different file")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    } else {
                        VStack {
                            Image(systemName: "doc.badge.arrow.up")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("Drag & Drop a file to sign\nor click to browse")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                }
                .frame(height: 120)
                .onTapGesture {
                    showFilePicker = true
                }
                .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers -> Bool in
                    handleDrop(providers: providers)
                    return true
                }
            }
            
            // Certificate selection
            HStack {
                Text("Signing Identity:")
                    .fontWeight(.medium)
                
                Picker("", selection: $viewModel.selectedIdentity) {
                    Text("Select a certificate").tag(nil as String?)
                    ForEach(viewModel.availableIdentities, id: \.self) { identity in
                        Text(identity).tag(identity as String?)
                    }
                }
                .frame(maxWidth: 300)
            }
            
            // Sign button
            Button(action: {
                viewModel.signFile()
            }) {
                if viewModel.isSigning {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .controlSize(.small)
                } else {
                    Text("Sign File")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedFile == nil || viewModel.selectedIdentity == nil || viewModel.isSigning)
            
            // Status message
            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .foregroundColor(viewModel.signingSuccessful ? .green : .red)
                    .font(.caption)
            }
        }
        .padding()
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            handleFileSelection(result: result)
        }
        .alert("Error", isPresented: $viewModel.showError, presenting: viewModel.currentError) { error in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(error.localizedDescription)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // Use the older method for compatibility
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            viewModel.selectedFile = url
                            viewModel.statusMessage = nil
                        }
                    } else if let url = item as? URL {
                        DispatchQueue.main.async {
                            viewModel.selectedFile = url
                            viewModel.statusMessage = nil
                        }
                    }
                }
            }
        }
        return true
    }
    
    private func handleFileSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                viewModel.selectedFile = url
                viewModel.statusMessage = nil
            }
        case .failure(let error):
            viewModel.currentError = error
            viewModel.showError = true
        }
    }
    
    private func fileIconName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pkg": return "shippingbox"
        case "dmg": return "internaldrive"
        case "app": return "app"
        default: return "doc"
        }
    }
}

// Stroke style extension for dashed border
extension Shape {
    func strokeStyle(dash: [CGFloat]) -> some View {
        self.stroke(style: StrokeStyle(lineWidth: 2, dash: dash))
    }
}

//MARK:  SigningViewModel.swift
import Foundation
import Security

class SigningViewModel: ObservableObject {
    @Published var selectedFile: URL?
    @Published var availableIdentities: [String] = []
    @Published var selectedIdentity: String?
    @Published var isSigning = false
    @Published var showError = false
    @Published var currentError: Error?
    @Published var statusMessage: String?
    @Published var signingSuccessful = false
    
    init() {
        loadSigningIdentities()
    }
    
    func signFile() {
        guard let fileURL = selectedFile, let identity = selectedIdentity else { return }
        
        isSigning = true
        statusMessage = "Signing..."
        signingSuccessful = false
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.executeSigning(fileURL: fileURL, identity: identity)
            
            DispatchQueue.main.async {
                self.isSigning = false
                
                switch result {
                case .success:
                    self.statusMessage = "Successfully signed: \(fileURL.lastPathComponent)"
                    self.signingSuccessful = true
                case .failure(let error):
                    self.statusMessage = "Signing failed"
                    self.currentError = error
                    self.showError = true
                    self.signingSuccessful = false
                }
            }
        }
    }
    
    private func executeSigning(fileURL: URL, identity: String) -> Result<Void, Error> {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.standardOutput = pipe
        process.standardError = pipe
        
        let filePath = fileURL.path
        let fileExtension = fileURL.pathExtension.lowercased()
        
        // Build codesign arguments based on file type
        var arguments = ["-s", identity]
        
        switch fileExtension {
        case "app":
            arguments.append(contentsOf: ["-f", "--deep", filePath])
        case "pkg", "dmg":
            arguments.append(filePath)
        default:
            return .failure(SigningError.unsupportedFileType)
        }
        
        process.arguments = arguments
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error (exit code: \(process.terminationStatus))"
                return .failure(SigningError.signingFailed(errorString))
            }
            
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    
    func loadSigningIdentities() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let items = result as? [SecIdentity] else {
            print("No signing identities found or error: \(status)")
            return
        }
        
        availableIdentities = items.compactMap { identity in
            var certificate: SecCertificate?
            let status = SecIdentityCopyCertificate(identity, &certificate)
            
            guard status == errSecSuccess, let cert = certificate else {
                return nil
            }
            
            return SecCertificateCopySubjectSummary(cert) as String?
        }.sorted()
        
        print("Found identities: \(availableIdentities)")
    }
}

//MARK:  Models.swift
import Foundation

enum SigningError: LocalizedError {
    case unsupportedFileType
    case signingFailed(String)
    case identityNotFound
    case noFileSelected
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Unsupported file type. Please select a .pkg, .dmg, or .app file."
        case .signingFailed(let message):
            return "Signing failed: \(message)"
        case .identityNotFound:
            return "No signing identity found in keychain."
        case .noFileSelected:
            return "Please select a file to sign."
        }
    }
}
