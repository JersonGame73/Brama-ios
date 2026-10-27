//
//  GameStorageManager.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI
import Combine

final class GameStorageManager: ObservableObject {
    static let shared = GameStorageManager()
    
    @Published var games: [GameTitle] = []
    
    private let fileManager = FileManager.default
    private let gamesStorageKey = "brama_library_games.json"
    
    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    var bramaGamesDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("BramaGames", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    var winePrefixesDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("WinePrefixes", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    init() {
        loadGames()
    }
    
    func loadGames() {
        let fileURL = documentsDirectory.appendingPathComponent(gamesStorageKey)
        if fileManager.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           var decoded = try? JSONDecoder().decode([GameTitle].self, from: data),
           !decoded.isEmpty {
            // Sanitize legacy SF Symbol names saved in older JSON
            for i in 0..<decoded.count {
                if decoded[i].systemIcon == "radiation" {
                    decoded[i].systemIcon = "atom"
                }
            }
            self.games = decoded
        } else {
            self.games = GameTitle.samples
            saveGames()
        }
    }
    
    func saveGames() {
        let fileURL = documentsDirectory.appendingPathComponent(gamesStorageKey)
        if let encoded = try? JSONEncoder().encode(games) {
            try? encoded.write(to: fileURL)
        }
    }
    
    func addGame(
        title: String,
        publisher: String = "Steam Library Import",
        genre: String = "PC Game",
        executableURL: URL,
        colorHexes: [String] = ["#1976D2", "#0D47A1"],
        systemIcon: String = "gamecontroller.fill"
    ) {
        let shouldStopAccess = executableURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccess {
                executableURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let targetGameFolder = bramaGamesDirectory.appendingPathComponent(title, isDirectory: true)
        
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDir)
        var detectedExeName = executableURL.lastPathComponent
        
        if exists && isDir.boolValue {
            // User selected the complete game folder (recommended: copies .exe, UnityPlayer.dll, *_Data, etc.)
            if fileManager.fileExists(atPath: targetGameFolder.path) {
                try? fileManager.removeItem(at: targetGameFolder)
            }
            try? fileManager.copyItem(at: executableURL, to: targetGameFolder)
            
            // Automatically find the primary .exe inside the copied game folder
            if let items = try? fileManager.contentsOfDirectory(atPath: targetGameFolder.path) {
                let exeFiles = items.filter { item in
                    let lower = item.lowercased()
                    return lower.hasSuffix(".exe")
                        && !lower.contains("crashhandler")
                        && !lower.contains("unins")
                        && !lower.contains("redist")
                        && !lower.contains("setup")
                }
                if let primaryExe = exeFiles.first {
                    detectedExeName = primaryExe
                }
            }
        } else {
            // User selected a single .exe file: also try to copy sibling DLLs / Data if accessible in parent directory
            if !fileManager.fileExists(atPath: targetGameFolder.path) {
                try? fileManager.createDirectory(at: targetGameFolder, withIntermediateDirectories: true)
            }
            let destinationFile = targetGameFolder.appendingPathComponent(detectedExeName)
            if fileManager.fileExists(atPath: destinationFile.path) {
                try? fileManager.removeItem(at: destinationFile)
            }
            try? fileManager.copyItem(at: executableURL, to: destinationFile)
            
            // Attempt to copy sibling files (e.g. UnityPlayer.dll, *_Data) if parent directory is accessible
            let parentDir = executableURL.deletingLastPathComponent()
            let parentAccess = parentDir.startAccessingSecurityScopedResource()
            if let siblings = try? fileManager.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil) {
                for sibling in siblings where sibling.lastPathComponent != detectedExeName {
                    let destSibling = targetGameFolder.appendingPathComponent(sibling.lastPathComponent)
                    if !fileManager.fileExists(atPath: destSibling.path) {
                        try? fileManager.copyItem(at: sibling, to: destSibling)
                    }
                }
            }
            if parentAccess {
                parentDir.stopAccessingSecurityScopedResource()
            }
        }
        
        let resolvedPOSIXPath = targetGameFolder.appendingPathComponent(detectedExeName).path
        
        let newGame = GameTitle(
            title: title,
            publisher: publisher,
            genre: genre,
            hoursPlayed: 0.0,
            lastPlayedText: "Recién importado",
            colorHexes: colorHexes,
            systemIcon: systemIcon,
            compatibility: .testing,
            graphicsBackend: .dxmtMetal,
            translationEngine: .fexEmu,
            targetFPS: 60,
            isInstalled: true,
            executablePath: resolvedPOSIXPath,
            winePrefixName: title.lowercased().replacingOccurrences(of: " ", with: "_")
        )
        
        DispatchQueue.main.async {
            // Replace existing entry with same title if re-importing
            self.games.removeAll { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            self.games.insert(newGame, at: 0)
            self.saveGames()
        }
    }
    
    func updateGame(_ game: GameTitle) {
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index] = game
            saveGames()
        }
    }
    
    func deleteGame(_ game: GameTitle) {
        games.removeAll(where: { $0.id == game.id })
        saveGames()
    }
}
