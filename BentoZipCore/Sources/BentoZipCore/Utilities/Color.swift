import SwiftUI

// Hex Extension
extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted))
        var hexNumber: UInt64 = 0
        scanner.scanHexInt64(&hexNumber)
        
        let r = Double((hexNumber >> 16) & 0xFF) / 255.0
        let g = Double((hexNumber >> 8) & 0xFF) / 255.0
        let b = Double(hexNumber & 0xFF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}
