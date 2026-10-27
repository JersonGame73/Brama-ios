//
//  GameTitle.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI

enum CompatibilityTier: String, CaseIterable, Identifiable, Codable {
    case verified = "Verificado en Brama"
    case playable = "Jugable"
    case unsupported = "No Compatible"
    case testing = "En Pruebas"
    
    var id: String { rawValue }
    
    var color: Color {
        switch self {
        case .verified: return Color(red: 0.18, green: 0.8, blue: 0.44)
        case .playable: return Color(red: 0.95, green: 0.77, blue: 0.06)
        case .unsupported: return Color(red: 0.91, green: 0.3, blue: 0.24)
        case .testing: return Color(red: 0.2, green: 0.6, blue: 1.0)
        }
    }
    
    var iconName: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .playable: return "exclamationmark.circle.fill"
        case .unsupported: return "xmark.octagon.fill"
        case .testing: return "gearshape.2.fill"
        }
    }
}

enum GraphicsBackend: String, CaseIterable, Identifiable, Codable {
    case dxmtMetal = "DXMT (DirectX a Metal)"
    case moltenVK = "MoltenVK (Vulkan a Metal)"
    case d3dMetal = "D3DMetal (Apple GPTK)"
    
    var id: String { rawValue }
}

enum TranslationEngine: String, CaseIterable, Identifiable, Codable {
    case fexEmu = "FEX-Emu ARM64"
    case box64 = "Box64 ARM64"
    case nativeArm = "ARM64 Nativo"
    
    var id: String { rawValue }
}

struct GameTitle: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var publisher: String
    var genre: String
    var hoursPlayed: Double
    var lastPlayedText: String
    var colorHexes: [String]
    var systemIcon: String
    var compatibility: CompatibilityTier
    var graphicsBackend: GraphicsBackend
    var translationEngine: TranslationEngine
    var targetFPS: Int
    var isInstalled: Bool
    
    // Game options and prefix settings
    var executablePath: String
    var launchArguments: String
    var screenResolution: String
    var scalingMode: String
    var winePrefixName: String
    
    var bannerGradient: [Color] {
        if colorHexes.isEmpty {
            return [Color.blue, Color.purple]
        }
        return colorHexes.map { Color(hex: $0) }
    }
    
    init(
        id: UUID = UUID(),
        title: String,
        publisher: String,
        genre: String,
        hoursPlayed: Double,
        lastPlayedText: String,
        colorHexes: [String],
        systemIcon: String,
        compatibility: CompatibilityTier = .verified,
        graphicsBackend: GraphicsBackend = .dxmtMetal,
        translationEngine: TranslationEngine = .fexEmu,
        targetFPS: Int = 60,
        isInstalled: Bool = true,
        executablePath: String = "",
        launchArguments: String = "",
        screenResolution: String = "1280x800 (Steam Deck)",
        scalingMode: String = "FSR (Metal Super Resolution)",
        winePrefixName: String = "default"
    ) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.genre = genre
        self.hoursPlayed = hoursPlayed
        self.lastPlayedText = lastPlayedText
        self.colorHexes = colorHexes
        self.systemIcon = systemIcon
        self.compatibility = compatibility
        self.graphicsBackend = graphicsBackend
        self.translationEngine = translationEngine
        self.targetFPS = targetFPS
        self.isInstalled = isInstalled
        self.executablePath = executablePath.isEmpty ? "C:\\Games\\\(title)\\game.exe" : executablePath
        self.launchArguments = launchArguments
        self.screenResolution = screenResolution
        self.scalingMode = scalingMode
        self.winePrefixName = winePrefixName
    }
}

// MARK: - Color Hex Helper
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

extension GameTitle {
    static let samples: [GameTitle] = [
        GameTitle(
            title: "Cyberpunk 2077",
            publisher: "CD PROJEKT RED",
            genre: "Action RPG / Open World",
            hoursPlayed: 34.5,
            lastPlayedText: "Hoy",
            colorHexes: ["#F2CC00", "#1976D2"],
            systemIcon: "flame.fill",
            compatibility: .verified,
            targetFPS: 40,
            executablePath: "C:\\Games\\Cyberpunk2077\\bin\\x64\\Cyberpunk2077.exe",
            launchArguments: "-dx11 -nointro"
        ),
        GameTitle(
            title: "Elden Ring",
            publisher: "FromSoftware Inc.",
            genre: "Souls-like / Dark Fantasy",
            hoursPlayed: 82.0,
            lastPlayedText: "Ayer",
            colorHexes: ["#C89B3C", "#331A0D"],
            systemIcon: "shield.checkered",
            compatibility: .verified,
            targetFPS: 45,
            executablePath: "C:\\Games\\ELDEN RING\\Game\\eldenring.exe"
        ),
        GameTitle(
            title: "Hades II",
            publisher: "Supergiant Games",
            genre: "Rogue-like / Hack and Slash",
            hoursPlayed: 19.3,
            lastPlayedText: "Hace 2 días",
            colorHexes: ["#CC334C", "#4C0D66"],
            systemIcon: "bolt.heart.fill",
            compatibility: .verified,
            targetFPS: 60,
            executablePath: "C:\\Games\\Hades II\\Ship\\Hades2.exe"
        ),
        GameTitle(
            title: "Grand Theft Auto V",
            publisher: "Rockstar Games",
            genre: "Open World / Action",
            hoursPlayed: 120.4,
            lastPlayedText: "Hace 4 días",
            colorHexes: ["#33804D", "#1A3366"],
            systemIcon: "car.side.fill",
            compatibility: .playable,
            targetFPS: 60,
            executablePath: "C:\\Games\\Grand Theft Auto V\\GTA5.exe"
        ),
        GameTitle(
            title: "Hollow Knight",
            publisher: "Team Cherry",
            genre: "Metroidvania / 2D",
            hoursPlayed: 45.1,
            lastPlayedText: "Semana pasada",
            colorHexes: ["#334D80", "#0D1426"],
            systemIcon: "moon.stars.fill",
            compatibility: .verified,
            targetFPS: 60,
            executablePath: "C:\\Games\\Hollow Knight\\hollow_knight.exe"
        ),
        GameTitle(
            title: "Fallout: New Vegas",
            publisher: "Bethesda Softworks",
            genre: "Post-Apocalyptic RPG",
            hoursPlayed: 56.8,
            lastPlayedText: "Hace 2 semanas",
            colorHexes: ["#B3661A", "#33260D"],
            systemIcon: "radiation",
            compatibility: .verified,
            targetFPS: 60,
            executablePath: "C:\\Games\\Fallout New Vegas\\FalloutNV.exe"
        )
    ]
}
