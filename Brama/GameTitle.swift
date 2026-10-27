//
//  GameTitle.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI

enum CompatibilityTier: String, CaseIterable, Identifiable {
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

enum GraphicsBackend: String, CaseIterable, Identifiable {
    case dxmtMetal = "DXMT (DirectX a Metal)"
    case moltenVK = "MoltenVK (Vulkan a Metal)"
    case d3dMetal = "D3DMetal (Apple GPTK)"
    
    var id: String { rawValue }
}

enum TranslationEngine: String, CaseIterable, Identifiable {
    case fexEmu = "FEX-Emu ARM64"
    case box64 = "Box64 ARM64"
    case nativeArm = "ARM64 Nativo"
    
    var id: String { rawValue }
}

struct GameTitle: Identifiable, Hashable {
    let id: UUID
    var title: String
    var publisher: String
    var genre: String
    var hoursPlayed: Double
    var lastPlayedText: String
    var bannerGradient: [Color]
    var systemIcon: String
    var compatibility: CompatibilityTier
    var graphicsBackend: GraphicsBackend
    var translationEngine: TranslationEngine
    var targetFPS: Int
    var isInstalled: Bool
    
    init(
        id: UUID = UUID(),
        title: String,
        publisher: String,
        genre: String,
        hoursPlayed: Double,
        lastPlayedText: String,
        bannerGradient: [Color],
        systemIcon: String,
        compatibility: CompatibilityTier = .verified,
        graphicsBackend: GraphicsBackend = .dxmtMetal,
        translationEngine: TranslationEngine = .fexEmu,
        targetFPS: Int = 60,
        isInstalled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.genre = genre
        self.hoursPlayed = hoursPlayed
        self.lastPlayedText = lastPlayedText
        self.bannerGradient = bannerGradient
        self.systemIcon = systemIcon
        self.compatibility = compatibility
        self.graphicsBackend = graphicsBackend
        self.translationEngine = translationEngine
        self.targetFPS = targetFPS
        self.isInstalled = isInstalled
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
            bannerGradient: [Color(red: 0.95, green: 0.8, blue: 0.0), Color(red: 0.1, green: 0.5, blue: 0.7)],
            systemIcon: "flame.fill",
            compatibility: .verified,
            targetFPS: 40
        ),
        GameTitle(
            title: "Elden Ring",
            publisher: "FromSoftware Inc.",
            genre: "Souls-like / Dark Fantasy",
            hoursPlayed: 82.0,
            lastPlayedText: "Ayer",
            bannerGradient: [Color(red: 0.8, green: 0.6, blue: 0.2), Color(red: 0.2, green: 0.1, blue: 0.05)],
            systemIcon: "shield.checkered",
            compatibility: .verified,
            targetFPS: 45
        ),
        GameTitle(
            title: "Hades II",
            publisher: "Supergiant Games",
            genre: "Rogue-like / Hack and Slash",
            hoursPlayed: 19.3,
            lastPlayedText: "Hace 2 días",
            bannerGradient: [Color(red: 0.8, green: 0.2, blue: 0.3), Color(red: 0.3, green: 0.05, blue: 0.4)],
            systemIcon: "bolt.heart.fill",
            compatibility: .verified,
            targetFPS: 60
        ),
        GameTitle(
            title: "Grand Theft Auto V",
            publisher: "Rockstar Games",
            genre: "Open World / Action",
            hoursPlayed: 120.4,
            lastPlayedText: "Hace 4 días",
            bannerGradient: [Color(red: 0.2, green: 0.5, blue: 0.3), Color(red: 0.1, green: 0.2, blue: 0.4)],
            systemIcon: "car.side.fill",
            compatibility: .playable,
            targetFPS: 60
        ),
        GameTitle(
            title: "Hollow Knight",
            publisher: "Team Cherry",
            genre: "Metroidvania / 2D",
            hoursPlayed: 45.1,
            lastPlayedText: "Semana pasada",
            bannerGradient: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.05, green: 0.08, blue: 0.15)],
            systemIcon: "moon.stars.fill",
            compatibility: .verified,
            targetFPS: 60
        ),
        GameTitle(
            title: "Fallout: New Vegas",
            publisher: "Bethesda Softworks",
            genre: "Post-Apocalyptic RPG",
            hoursPlayed: 56.8,
            lastPlayedText: "Hace 2 semanas",
            bannerGradient: [Color(red: 0.7, green: 0.4, blue: 0.1), Color(red: 0.2, green: 0.15, blue: 0.05)],
            systemIcon: "radiation",
            compatibility: .verified,
            targetFPS: 60
        )
    ]
}
