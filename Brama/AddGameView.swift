//
//  AddGameView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct AddGameView: View {
    @ObservedObject var storageManager = GameStorageManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var gameTitle: String = ""
    @State private var publisher: String = "Steam Library"
    @State private var genre: String = "Acción / Aventura"
    @State private var selectedColorPairIndex: Int = 0
    @State private var selectedURL: URL? = nil
    @State private var showFilePicker: Bool = false
    
    private let colorThemes: [[String]] = [
        ["#1976D2", "#0D47A1"], // Azul Steam
        ["#F2CC00", "#E65100"], // Naranja / Oro
        ["#9C27B0", "#4A148C"], // Púrpura Cyber
        ["#2E7D32", "#1B5E20"], // Verde Militar
        ["#C62828", "#880E4F"]  // Rojo Crimson
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.08, green: 0.11, blue: 0.16)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        
                        // Header instructions
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AÑADIR JUEGO A BRAMA")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.gray)
                            
                            Text("Transfiere la carpeta de tu juego desde tu Steam Deck o PC a la app Archivos de tu iPad, y selecciónala a continuación.")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(10)
                        
                        // File Selection Card
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ARCHIVO EJECUTABLE O CARPETA")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.gray)
                            
                            Button(action: {
                                showFilePicker = true
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedURL == nil ? "doc.badge.plus" : "checkmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(selectedURL == nil ? Color(red: 0.1, green: 0.62, blue: 1.0) : .green)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(selectedURL == nil ? "Seleccionar en la app Archivos" : selectedURL!.lastPathComponent)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        
                                        Text(selectedURL == nil ? "Admite archivos .exe o carpetas completas" : "Ubicación lista para importar")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                    }
                                    
                                    Spacer()
                                    
                                    Text("Explorar")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Color(red: 0.1, green: 0.62, blue: 1.0))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color(red: 0.1, green: 0.62, blue: 1.0).opacity(0.15))
                                        .cornerRadius(6)
                                }
                                .padding(14)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                            }
                        }
                        
                        // Game Title Field
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NOMBRE DEL JUEGO")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.gray)
                            
                            TextField("ej. Doom Eternal, Hollow Knight", text: $gameTitle)
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)
                        }
                        
                        // Color Theme Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("COLOR DEL BANNER")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.gray)
                            
                            HStack(spacing: 12) {
                                ForEach(0..<colorThemes.count, id: \.self) { idx in
                                    let colors = colorThemes[idx]
                                    Button(action: { selectedColorPairIndex = idx }) {
                                        Circle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color(hex: colors[0]), Color(hex: colors[1])],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 38, height: 38)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.white, lineWidth: selectedColorPairIndex == idx ? 3 : 0)
                                            )
                                    }
                                }
                            }
                        }
                        
                        Spacer(minLength: 20)
                        
                        // Submit Button
                        Button(action: handleSaveGame) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Añadir a la Biblioteca Brama")
                            }
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                gameTitle.trimmingCharacters(in: .whitespaces).isEmpty ?
                                Color.gray.opacity(0.3) :
                                Color(red: 0.1, green: 0.62, blue: 1.0)
                            )
                            .cornerRadius(12)
                        }
                        .disabled(gameTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Añadir Juego")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .foregroundColor(.gray)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item, .folder, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let firstUrl = urls.first {
                        self.selectedURL = firstUrl
                        if gameTitle.isEmpty {
                            // Automatically derive clean title from filename
                            let cleanName = firstUrl.deletingPathExtension().lastPathComponent
                                .replacingOccurrences(of: "_", with: " ")
                                .replacingOccurrences(of: "-", with: " ")
                            self.gameTitle = cleanName.capitalized
                        }
                    }
                case .failure(let error):
                    print("Error selecting file: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func handleSaveGame() {
        let finalTitle = gameTitle.trimmingCharacters(in: .whitespaces)
        guard !finalTitle.isEmpty else { return }
        
        let dummyURL = storageManager.bramaGamesDirectory.appendingPathComponent("\(finalTitle).exe")
        let executable = selectedURL ?? dummyURL
        
        storageManager.addGame(
            title: finalTitle,
            publisher: publisher,
            genre: genre,
            executableURL: executable,
            colorHexes: colorThemes[selectedColorPairIndex],
            systemIcon: "gamecontroller.fill"
        )
        dismiss()
    }
}
