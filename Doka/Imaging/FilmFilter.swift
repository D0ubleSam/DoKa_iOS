import Foundation

struct FilmFilter: Identifiable, Hashable {
    let id: String
    let name: String
    let family: String

    static let original = FilmFilter(id: "original", name: "原图", family: "原图")
    static let all: [FilmFilter] = [.original] + [
        ("f_classic_chrome", "F Classic Chrome", "F"),
        ("f_provia", "F PROVIA", "F"),
        ("f_velvia", "F Velvia", "F"),
        ("f_cc", "F CC", "F"),
        ("f_classic_neg", "F Classic Neg", "F"),
        ("f_cn", "F CN", "F"),
        ("f_c200", "F C200", "F"),
        ("f_160c", "F 160C", "F"),
        ("f_pro_neg", "F Pro Neg", "F"),
        ("f_400h", "F 400H", "F"),
        ("f_s100", "F S100", "F"),
        ("f_s400", "F S400", "F"),
        ("k_portra_160", "Portra 160", "K"),
        ("k_gold_200", "Gold 200", "K"),
        ("k_portra_400", "Portra 400", "K"),
        ("agfa_vista_800", "Vista 800", "Agfa"),
        ("agfa_ap_100", "AP 100", "Agfa"),
        ("doka_s100", "Doka S100", "Doka"),
        ("doka_s50", "Doka S50", "Doka"),
        ("doka_s160", "Doka S160", "Doka"),
        ("doka_s200", "Doka S200", "Doka"),
        ("doka_s400", "Doka S400", "Doka"),
        ("doka_x400", "Doka X400", "Doka"),
        ("doka_x100", "Doka X100", "Doka")
    ].map { FilmFilter(id: "lut_" + $0.0, name: $0.1, family: $0.2) }
}

enum PhotoRatio: String, CaseIterable, Identifiable {
    case standard = "3:4", square = "1:1", widescreen = "9:16"
    var id: String { rawValue }
    var value: CGFloat {
        switch self {
        case .standard: return 3 / 4
        case .square: return 1
        case .widescreen: return 9 / 16
        }
    }
}

struct RenderSettings: Equatable {
    var filterID = FilmFilter.original.id
    var intensity: Float = 1
    var tone: Float = 0
    var chroma: Float = 0
    var paletteIntensity: Float = 1
    var ratio = PhotoRatio.standard
}
