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
           let decoded = try? JSONDecoder().decode([GameTitle].self, from: data),
           !decoded.isEmpty {
            self.games = decoded
        } else {
            // First time launch: initialize with sample games
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
        // Secure access to external file/folder picked by UIDocumentPicker
        let shouldStopAccess = executableURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccess {
                executableURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let targetGameFolder = bramaGamesDirectory.appendingPathComponent(title, isDirectory: true)
        if !fileManager.fileExists(atPath: targetGameFolder.path) {
            try? fileManager.createDirectory(at: targetGameFolder, withIntermediateDirectories: true)
        }
        
        // Target executable destination or path
        let exeFileName = executableURL.lastPathComponent
        let destinationFile = targetGameFolder.appendingPathComponent(exeFileName)
        
        // If file doesn't already exist in destination, copy it
        if !fileManager.fileExists(atPath: destinationFile.path) {
            try? fileManager.copyItem(at: executableURL, to: destinationFile)
        }
        
        let newGame = GameTitle(
            title: title,
            publisher: publisher,
            genre: genre,
            hoursPlayed: 0.0,
            lastPlayedText: "Recién añadido",
            colorHexes: colorHexes,
            systemIcon: systemIcon,
            compatibility: .testing,
            graphicsBackend: .dxmtMetal,
            translationEngine: .fexEmu,
            targetFPS: 60,
            isInstalled: true,
            executablePath: "C:\\Games\\\(title)\\\(exeFileName)",
            winePrefixName: title.lowercased().replacingOccurrences(of: " ", with: "_")
        )
        
        DispatchQueue.main.async {
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
