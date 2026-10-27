//
//  ContentView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var perfManager = PerformanceManager.shared
    @StateObject private var controllerManager = ControllerManager.shared
    @StateObject private var storageManager = GameStorageManager.shared
    
    @State private var selectedGame: GameTitle = GameTitle.samples[0]
    @State private var selectedCategoryIndex: Int = 0
    @State private var showQuickAccessMenu: Bool = false
    @State private var showGameSettings: Bool = false
    @State private var showAddGameModal: Bool = false
    @State private var runningGame: GameTitle? = nil
    @State private var currentTimeString: String = ""
    
    private let categories = ["Todos", "Verificados", "Instalados", "Recientes"]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var currentGamesList: [GameTitle] {
        storageManager.games.isEmpty ? GameTitle.samples : storageManager.games
    }
    
    var filteredGames: [GameTitle] {
        switch selectedCategoryIndex {
        case 1:
            return currentGamesList.filter { $0.compatibility == .verified }
        case 2:
            return currentGamesList.filter { $0.isInstalled }
        case 3:
            return currentGamesList.sorted { $0.hoursPlayed > $1.hoursPlayed }
        default:
            return currentGamesList
        }
    }
    
    var body: some View {
        ZStack {
            // Background SteamOS gradient
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.1),
                    Color(red: 0.08, green: 0.12, blue: 0.18),
                    Color(red: 0.04, green: 0.05, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Bar
                topNavigationBar
                
                // Main Scrollable Content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        
                        // Hero Game Banner
                        heroGameBanner(game: selectedGame)
                        
                        // Categories Shelf & Add Game Button
                        categoryTabs
                        
                        // Horizontal Game Cards Shelf
                        gamesHorizontalShelf
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                
                Spacer(minLength: 0)
                
                // Bottom Controller Bar
                bottomControllerBar
            }
            
            // Real-time HUD (MangoHUD Style)
            if perfManager.overlayLevel != .off {
                performanceHUDOverlay
            }
            

            
            // Quick Access Sidebar ("..." Button Menu)
            if showQuickAccessMenu {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showQuickAccessMenu = false
                        }
                    }
                
                HStack {
                    Spacer()
                    QuickAccessMenuView(isPresented: $showQuickAccessMenu)
                        .transition(.move(edge: .trailing))
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            updateTime()
            if let first = currentGamesList.first {
                selectedGame = first
            }
        }
        .onReceive(timer) { _ in
            updateTime()
        }
        .onChange(of: storageManager.games) { newGames in
            if !newGames.contains(where: { $0.id == selectedGame.id }), let first = newGames.first {
                selectedGame = first
            }
        }
        .sheet(isPresented: $showGameSettings) {
            GameSettingsView(game: $selectedGame)
        }
        .sheet(isPresented: $showAddGameModal) {
            AddGameView()
        }
        .fullScreenCover(item: $runningGame) { gameToLaunch in
            GameSessionView(game: gameToLaunch)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
    
    // MARK: - Top Navigation Bar
    private var topNavigationBar: some View {
        HStack(spacing: 16) {
            // Brama Brand
            HStack(spacing: 8) {
                Image("BramaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 0.1, green: 0.62, blue: 1.0).opacity(0.6), lineWidth: 1)
                    )
                
                Text("BRAMA")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                
                Text("DECK")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.1, green: 0.62, blue: 1.0))
                    .cornerRadius(4)
            }
            
            Spacer()
            
            // Add Game Shortcut Button
            Button(action: {
                showAddGameModal = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Añadir Juego")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(red: 0.1, green: 0.62, blue: 1.0))
                .cornerRadius(16)
            }
            
            // System Status (Time, Battery, Wifi)
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                    
                    Text("Wi-Fi")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: perfManager.isCharging ? "battery.100.bolt" : "battery.75")
                        .font(.system(size: 13))
                        .foregroundColor(perfManager.isCharging ? .green : .white)
                    
                    Text("\(perfManager.batteryPercentage)%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                Text(currentTimeString)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .cornerRadius(20)
            
            // User Avatar Profile Pill
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 24, height: 24)
                    .overlay(
                        Text("J")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    )
                
                Text("JersonGame73")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08))
            .cornerRadius(16)
            

            // Quick Access ("...") Button
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showQuickAccessMenu.toggle()
                }
            }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.4))
    }
    
    // MARK: - Hero Game Banner
    private func heroGameBanner(game: GameTitle) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Artwork Card
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: game.bannerGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            
            // Soft overlay gradient for text readability
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .cornerRadius(18)
            .frame(height: 220)
            
            // Banner Content
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    
                    // Compatibility Badge
                    HStack(spacing: 6) {
                        Image(systemName: game.compatibility.iconName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(game.compatibility.color)
                        
                        Text(game.compatibility.rawValue)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(game.compatibility.color)
                        
                        Text("•  \(game.translationEngine.rawValue)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                        
                        Text("•  \(game.screenResolution)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(12)
                    
                    // Game Title & Publisher
                    Text(game.title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                    
                    HStack(spacing: 12) {
                        Text(game.genre)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Text("\(String(format: "%.1f", game.hoursPlayed)) h jugadas")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                
                Spacer()
                
                // Action Buttons (Play & Wine Settings)
                HStack(spacing: 12) {
                    Button(action: {
                        showGameSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                    
                    // Big "JUGAR" Button
                    Button(action: {
                        runningGame = game
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .black))
                            Text("JUGAR")
                                .font(.system(size: 16, weight: .black, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.18, green: 0.8, blue: 0.44), Color(red: 0.13, green: 0.65, blue: 0.35)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(12)
                        .shadow(color: Color(red: 0.18, green: 0.8, blue: 0.44).opacity(0.4), radius: 10, x: 0, y: 4)
                    }
                }
            }
            .padding(24)
        }
    }
    
    // MARK: - Category Tabs
    private var categoryTabs: some View {
        HStack(spacing: 12) {
            ForEach(0..<categories.count, id: \.self) { index in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedCategoryIndex = index
                    }
                }) {
                    Text(categories[index])
                        .font(.system(size: 14, weight: selectedCategoryIndex == index ? .bold : .medium))
                        .foregroundColor(selectedCategoryIndex == index ? .white : .gray)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            selectedCategoryIndex == index ?
                            Color(red: 0.1, green: 0.62, blue: 1.0) :
                            Color.white.opacity(0.06)
                        )
                        .cornerRadius(20)
                }
            }
            
            Spacer()
        }
    }
    
    // MARK: - Games Horizontal Shelf
    private var gamesHorizontalShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BIBLIOTECA PRINCIPAL (\(filteredGames.count)) • Toca 2 veces o pulsa ▶ para abrir")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.gray)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(filteredGames) { game in
                        GameCardView(
                            game: game,
                            isSelected: selectedGame.id == game.id,
                            onPlayPressed: {
                                selectedGame = game
                                runningGame = game
                            }
                        )
                        .onTapGesture {
                            if selectedGame.id == game.id {
                                runningGame = game
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    selectedGame = game
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
    
    // MARK: - Bottom Controller Bar
    private var bottomControllerBar: some View {
        HStack(spacing: 24) {
            Button(action: {
                runningGame = selectedGame
            }) {
                ControllerButtonLegend(buttonLabel: "A", text: "Jugar / Seleccionar", color: .green)
            }
            
            Button(action: {
                showGameSettings = true
            }) {
                ControllerButtonLegend(buttonLabel: "X", text: "Opciones de Wine", color: .blue)
            }
            
            Button(action: {
                showAddGameModal = true
            }) {
                ControllerButtonLegend(buttonLabel: "Y", text: "Añadir Juego", color: .yellow)
            }
            
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showQuickAccessMenu.toggle()
                }
            }) {
                ControllerButtonLegend(buttonLabel: "...", text: "Menú Rápido", color: .gray)
            }
            
            Spacer()
            
            Text("Brama OS v1.0 • Apple Silicon")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.gray.opacity(0.8))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
    }
    
    // MARK: - Performance HUD Overlay (MangoHUD Style)
    private var performanceHUDOverlay: some View {
        VStack {
            HStack {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("FPS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)
                        Text(String(format: "%.1f", perfManager.currentFPS))
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    
                    if perfManager.overlayLevel == .standard || perfManager.overlayLevel == .fullHUD {
                        HStack(spacing: 4) {
                            Text("GPU")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.gray)
                            Text("\(perfManager.gpuUtilizationPercent)%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        
                        HStack(spacing: 4) {
                            Text("BAT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.gray)
                            Text("\(perfManager.batteryPercentage)%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                    }
                    
                    if perfManager.overlayLevel == .fullHUD {
                        HStack(spacing: 4) {
                            Text("JIT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.gray)
                            Text(perfManager.isJITEnabled ? "ON" : "OFF")
                                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                .foregroundColor(perfManager.isJITEnabled ? .green : .red)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.75))
                .cornerRadius(6)
                
                Spacer()
            }
            .padding(.leading, 24)
            .padding(.top, 50)
            
            Spacer()
        }
        .allowsHitTesting(false)
    }
    
    private func updateTime() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        currentTimeString = formatter.string(from: Date())
    }
}

// MARK: - Subviews
fileprivate struct GameCardView: View {
    let game: GameTitle
    let isSelected: Bool
    var onPlayPressed: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: game.bannerGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 150, height: 210)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                isSelected ? Color(red: 0.1, green: 0.62, blue: 1.0) : Color.white.opacity(0.1),
                                lineWidth: isSelected ? 3 : 1
                            )
                    )
                    .shadow(
                        color: isSelected ? Color(red: 0.1, green: 0.62, blue: 1.0).opacity(0.45) : Color.clear,
                        radius: 8,
                        x: 0,
                        y: 4
                    )
                
                // Icon & Quick Play Button on Selected Card
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: game.systemIcon)
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(10)
                    }
                    Spacer()
                    
                    if isSelected {
                        Button(action: {
                            onPlayPressed?()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .black))
                                Text("JUGAR")
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(red: 0.18, green: 0.8, blue: 0.44))
                            .cornerRadius(20)
                            .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                        }
                        .padding(.bottom, 42)
                    }
                }
                .frame(width: 150, height: 210)
                
                // Bottom badge
                HStack(spacing: 4) {
                    Image(systemName: game.compatibility.iconName)
                        .font(.system(size: 10))
                        .foregroundColor(game.compatibility.color)
                    Text(game.compatibility == .verified ? "Verificado" : "Jugable")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.7))
                .cornerRadius(6)
                .padding(8)
            }
            
            Text(game.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            
            Text("\(String(format: "%.1f", game.hoursPlayed)) h")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .scaleEffect(isSelected ? 1.03 : 1.0)
    }
}

fileprivate struct ControllerButtonLegend: View {
    let buttonLabel: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Text(buttonLabel)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundColor(.black)
                .frame(width: 18, height: 18)
                .background(color)
                .clipShape(Circle())
            
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
