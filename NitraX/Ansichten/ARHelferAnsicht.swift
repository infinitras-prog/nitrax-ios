import SwiftUI
import RealityKit
import ARKit

/// 🥽 AR: dein Helfer steht in deinem Zimmer - in Lebensgröße oder als kleine Figur auf dem Tisch. Die Helfer-Seite liefert
/// die Figur in der aktuellen Pose (Netz + Texturen), RealityKit stellt sie auf eine erkannte Fläche.
/// Antippen = hinstellen, zwei Finger = drehen/größer, ein Finger = verschieben.
struct ARModellDaten {
    struct Netz { var pos: [SIMD3<Float>]; var uv: [SIMD2<Float>]? }
    struct Teil { var netz: Int; var idx: [UInt32]; var tex: Int; var farbe: SIMD4<Float>; var durchsichtig: Bool }
    var netze: [Netz]
    var teile: [Teil]
    var texturen: [CGImage?]
    var hoehe: Float
    var boden: Float
    var name: String

    static func aus(_ d: [String: Any]) -> ARModellDaten? {
        func daten(_ s: Any?) -> Data? { (s as? String).flatMap { Data(base64Encoded: $0) } }
        func floats(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        guard let nz = d["netze"] as? [[String: Any]], let tz = d["teile"] as? [[String: Any]] else { return nil }
        let netze: [Netz] = nz.map { n in
            let p = daten(n["pos"]).map(floats) ?? []
            let pos = stride(from: 0, to: p.count - 2, by: 3).map { SIMD3<Float>(p[$0], p[$0 + 1], p[$0 + 2]) }
            let uv = daten(n["uv"]).map(floats).map { u in stride(from: 0, to: u.count - 1, by: 2).map { SIMD2<Float>(u[$0], u[$0 + 1]) } }
            return Netz(pos: pos, uv: uv)
        }
        let teile: [Teil] = tz.compactMap { t in
            guard let netz = (t["netz"] as? NSNumber)?.intValue, let i = daten(t["idx"]) else { return nil }
            let idx = i.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            let f = (t["farbe"] as? [NSNumber])?.map { $0.floatValue } ?? [1, 1, 1, 1]
            return Teil(netz: netz, idx: idx, tex: (t["tex"] as? NSNumber)?.intValue ?? -1,
                        farbe: SIMD4<Float>(f[0], f.count > 1 ? f[1] : 1, f.count > 2 ? f[2] : 1, f.count > 3 ? f[3] : 1),
                        durchsichtig: (t["durchsichtig"] as? Bool) ?? false)
        }
        let tex: [CGImage?] = ((d["texturen"] as? [String]) ?? []).map { url in
            guard let komma = url.firstIndex(of: ","), let b = Data(base64Encoded: String(url[url.index(after: komma)...])) else { return nil }
            return UIImage(data: b)?.cgImage
        }
        return ARModellDaten(netze: netze, teile: teile, texturen: tex, hoehe: Float((d["hoehe"] as? NSNumber)?.doubleValue ?? 1.6),
                             boden: Float((d["boden"] as? NSNumber)?.doubleValue ?? 0), name: d["name"] as? String ?? "Helfer")
    }

    /// RealityKit-Figur: ein Elternteil (Kollision für Gesten), darunter je Teil ein ModelEntity
    @MainActor
    func entity() -> ModelEntity {
        let wurzel = ModelEntity()
        var texCache: [Int: TextureResource] = [:]
        for t in teile where t.netz < netze.count && !t.idx.isEmpty {
            let n = netze[t.netz]
            var beschr = MeshDescriptor(name: "teil")
            beschr.positions = MeshBuffers.Positions(n.pos.map { SIMD3($0.x, $0.y - boden, $0.z) })
            if let uv = n.uv, uv.count == n.pos.count { beschr.textureCoordinates = MeshBuffers.TextureCoordinates(uv) }
            beschr.primitives = .triangles(t.idx)
            guard let netz = try? MeshResource.generate(from: [beschr]) else { continue }
            var mat = UnlitMaterial()
            if t.tex >= 0, t.tex < texturen.count, let cg = texturen[t.tex] {
                if texCache[t.tex] == nil { texCache[t.tex] = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) }
                if let tr = texCache[t.tex] {
                    mat.color = .init(tint: UIColor(red: CGFloat(t.farbe.x), green: CGFloat(t.farbe.y), blue: CGFloat(t.farbe.z), alpha: 1),
                                      texture: .init(tr))
                }
            } else {
                mat.color = .init(tint: UIColor(red: CGFloat(t.farbe.x), green: CGFloat(t.farbe.y), blue: CGFloat(t.farbe.z), alpha: 1))
            }
            if t.durchsichtig || t.farbe.w < 0.99 {
                mat.blending = .transparent(opacity: .init(floatLiteral: t.farbe.w))
                mat.opacityThreshold = 0.35                       // Haare/Wimpern: ausgeschnittene Kanten statt Schleier
            }
            if #available(iOS 18.0, *) { mat.faceCulling = .none }       // Haare/Kleid von beiden Seiten sichtbar
            wurzel.addChild(ModelEntity(mesh: netz, materials: [mat]))
        }
        let b = wurzel.visualBounds(relativeTo: wurzel)
        wurzel.collision = CollisionComponent(shapes: [ShapeResource.generateBox(size: b.extents).offsetBy(translation: b.center)])
        return wurzel
    }
}

@MainActor
final class ARSteuerung: ObservableObject {
    @Published var hinweis = "Bewege das iPhone langsam über den Boden …"
    @Published var steht = false
    @Published var lebensgross = true
    var figur: ModelEntity?
    weak var ansicht: ARView?
    private var anker: AnchorEntity?

    func setzen(_ f: ModelEntity) { figur = f; hinweis = "Tippe auf den Boden oder Tisch, um \(f.name.isEmpty ? "sie" : f.name) hinzustellen" }

    func hinstellen(an punkt: CGPoint) {
        guard let v = ansicht, let f = figur else { return }
        guard let r = v.raycast(from: punkt, allowing: .estimatedPlane, alignment: .horizontal).first else {
            hinweis = "Keine Fläche erkannt – zeig mir den Boden etwas länger"
            return
        }
        anker?.removeFromParent()
        let a = AnchorEntity(world: r.worldTransform)
        f.scale = SIMD3(repeating: lebensgross ? 1 : 0.22)
        // zum iPhone drehen
        if let kamera = v.session.currentFrame?.camera.transform {
            let k = SIMD3<Float>(kamera.columns.3.x, 0, kamera.columns.3.z), p = SIMD3<Float>(r.worldTransform.columns.3.x, 0, r.worldTransform.columns.3.z)
            let d = k - p
            f.orientation = simd_quatf(angle: atan2(d.x, d.z), axis: [0, 1, 0])
        }
        a.addChild(f)
        v.scene.addAnchor(a)
        anker = a
        v.installGestures([.translation, .rotation, .scale], for: f)
        steht = true
        hinweis = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func groesseWechseln() {
        lebensgross.toggle()
        figur?.move(to: Transform(scale: SIMD3(repeating: lebensgross ? 1 : 0.22), rotation: figur?.orientation ?? simd_quatf(), translation: figur?.position ?? .zero),
                    relativeTo: figur?.parent, duration: 0.35)
    }
}

struct ARHelferView: UIViewRepresentable {
    let steuerung: ARSteuerung

    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero)
        let k = ARWorldTrackingConfiguration()
        k.planeDetection = [.horizontal]
        k.environmentTexturing = .automatic
        v.session.run(k)
        let coaching = ARCoachingOverlayView()
        coaching.session = v.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.addSubview(coaching)
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Koordinator.tippen(_:))))
        steuerung.ansicht = v
        return v
    }

    func updateUIView(_ v: ARView, context: Context) {}

    static func dismantleUIView(_ v: ARView, coordinator: Koordinator) { v.session.pause() }

    func makeCoordinator() -> Koordinator { Koordinator(steuerung) }

    final class Koordinator: NSObject {
        let s: ARSteuerung
        init(_ s: ARSteuerung) { self.s = s }
        @MainActor @objc func tippen(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? ARView else { return }
            if s.steht, let e = v.entity(at: g.location(in: v)), e == s.figur || e.parent == s.figur {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            s.hinstellen(an: g.location(in: v))
        }
    }
}

@MainActor
struct ARHelferAnsicht: View {
    @Environment(\.dismiss) private var dismiss
    let laden: (String) async -> [String: Any]?
    @StateObject private var steuerung = ARSteuerung()
    @State private var pose = "stehen"
    @State private var laedt = true
    @State private var fehler: String?

    static let posen = [("stehen", "🧍 Stehen"), ("winken", "👋 Winken"), ("herz", "🫶 Herz"), ("jubeln", "🙌 Jubeln"), ("zwinkern", "😉 Zwinkern")]

    var body: some View {
        ZStack {
            ARHelferView(steuerung: steuerung).ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").padding(12).background(.ultraThinMaterial, in: Circle()) }
                    Spacer()
                    if steuerung.steht {
                        Button { steuerung.groesseWechseln() } label: {
                            Label(steuerung.lebensgross ? "Lebensgroß" : "Tischfigur", systemImage: "arrow.up.and.down.square")
                                .padding(.horizontal, 12).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
                .padding()
                if !steuerung.hinweis.isEmpty || laedt {
                    Text(laedt ? "Figur wird vorbereitet …" : steuerung.hinweis)
                        .font(.callout).padding(.horizontal, 14).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Self.posen, id: \.0) { p in
                            Button(p.1) { pose = p.0; Task { await figurLaden() } }
                                .buttonStyle(.bordered).tint(pose == p.0 ? Farbe.akzent : .white)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 24)
                .disabled(laedt)
            }
            if let fehler {
                Text(fehler).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
            }
        }
        .task { await figurLaden() }
        .statusBarHidden()
    }

    private func figurLaden() async {
        laedt = true
        defer { laedt = false }
        guard ARWorldTrackingConfiguration.isSupported else { fehler = "Dieses iPhone unterstützt AR nicht."; return }
        guard let d = await laden(pose), let m = ARModellDaten.aus(d) else { fehler = "Die Figur kam nicht vom Helfer – ist der Helfer geladen?"; return }
        fehler = nil
        let neu = m.entity()
        neu.name = m.name
        if let alt = steuerung.figur, let eltern = alt.parent {               // schon hingestellt: Pose tauschen, Platz behalten
            neu.transform = alt.transform
            alt.removeFromParent()
            eltern.addChild(neu)
            steuerung.figur = neu
            steuerung.ansicht?.installGestures([.translation, .rotation, .scale], for: neu)
        } else {
            steuerung.setzen(neu)
        }
    }
}
