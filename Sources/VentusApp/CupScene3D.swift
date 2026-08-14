import SwiftUI
import SceneKit

/// Real 3D tip cup: a lathed mesh whose geometry is genuinely morphed between
/// four tier shapes by `SCNMorpher`, lit with PBR materials and an orbiting
/// camera.
///
/// Why SceneKit and not RealityKit: `RealityView` requires macOS 15 and Ventus
/// targets macOS 14. `SCNMorpher` is also precisely the right primitive here —
/// blend weights map straight onto the slider. If the deployment target ever
/// moves to 15, the scene graph translates over.
///
/// Why procedural and not an authored USDZ: this ships zero asset bytes and no
/// modelling pipeline. The view and its wiring are asset-shaped, so a
/// Blender-authored USDZ with the same four shape keys can replace
/// `CupMesh.lathe` later without touching anything else.
enum CupMesh {
    /// Samples per profile. Every tier MUST produce this exact count —
    /// `SCNMorpher` requires topologically identical targets.
    static let profileSamples = 44
    /// Segments around the axis of revolution.
    static let radialSegments = 56

    /// Key silhouette of one tier, in (radius, height). Resampled below, so
    /// these can differ in count between tiers.
    struct Silhouette {
        var bottomRadius: CGFloat
        var topRadius: CGFloat
        var height: CGFloat
        var wall: CGFloat

        /// Outside wall up, over the rim, back down the inside, across the
        /// inner floor — a closed cup solid.
        var points: [CGPoint] {
            [
                CGPoint(x: 0, y: 0),
                CGPoint(x: bottomRadius * 0.72, y: 0),
                CGPoint(x: bottomRadius, y: 0.02),
                CGPoint(x: bottomRadius, y: 0.05),
                CGPoint(x: (bottomRadius + topRadius) / 2, y: height * 0.5),
                CGPoint(x: topRadius, y: height),
                CGPoint(x: topRadius - wall, y: height),
                CGPoint(x: (bottomRadius + topRadius) / 2 - wall, y: height * 0.5),
                CGPoint(x: bottomRadius - wall, y: 0.06),
                CGPoint(x: 0, y: 0.06),
            ]
        }
    }

    static let tiers: [Silhouette] = [
        .init(bottomRadius: 0.30, topRadius: 0.38, height: 0.72, wall: 0.035),  // drip
        .init(bottomRadius: 0.34, topRadius: 0.46, height: 0.88, wall: 0.040),  // flat white
        .init(bottomRadius: 0.36, topRadius: 0.48, height: 1.00, wall: 0.035),  // matcha
        .init(bottomRadius: 0.36, topRadius: 0.54, height: 1.18, wall: 0.030),  // frappé
    ]

    /// Resamples a polyline to a fixed count by arc length, so every tier ends
    /// up with identical vertex counts and ordering.
    private static func resample(_ pts: [CGPoint], to count: Int) -> [CGPoint] {
        var lengths: [CGFloat] = [0]
        for i in 1 ..< pts.count {
            let d = hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            lengths.append(lengths[i - 1] + d)
        }
        let total = lengths.last ?? 1
        guard total > 0 else { return Array(repeating: pts[0], count: count) }

        var out: [CGPoint] = []
        for s in 0 ..< count {
            let target = total * CGFloat(s) / CGFloat(count - 1)
            var seg = 1
            while seg < lengths.count - 1 && lengths[seg] < target { seg += 1 }
            let span = max(lengths[seg] - lengths[seg - 1], 0.0001)
            let t = (target - lengths[seg - 1]) / span
            let a = pts[seg - 1], b = pts[seg]
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return out
    }

    /// Revolves a profile into a closed mesh with analytically-derived smooth
    /// normals (SceneKit does not generate normals for custom geometry).
    static func lathe(_ silhouette: Silhouette) -> SCNGeometry {
        let profile = resample(silhouette.points, to: profileSamples)
        let rings = radialSegments + 1

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        vertices.reserveCapacity(profileSamples * rings)

        for p in 0 ..< profileSamples {
            // Profile tangent → 2D normal, then swept around Y.
            let prev = profile[max(p - 1, 0)]
            let next = profile[min(p + 1, profileSamples - 1)]
            var tx = next.x - prev.x, ty = next.y - prev.y
            let tl = max(hypot(tx, ty), 0.0001)
            tx /= tl; ty /= tl
            let n2 = CGPoint(x: ty, y: -tx)

            for r in 0 ..< rings {
                let a = CGFloat(r) / CGFloat(radialSegments) * .pi * 2
                let ca = cos(a), sa = sin(a)
                vertices.append(SCNVector3(profile[p].x * ca, profile[p].y, profile[p].x * sa))
                normals.append(SCNVector3(n2.x * ca, n2.y, n2.x * sa))
            }
        }

        var indices: [Int32] = []
        for p in 0 ..< (profileSamples - 1) {
            for r in 0 ..< radialSegments {
                let a = Int32(p * rings + r)
                let b = Int32(p * rings + r + 1)
                let c = Int32((p + 1) * rings + r)
                let d = Int32((p + 1) * rings + r + 1)
                indices += [a, c, b, b, c, d]
            }
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals),
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        return geometry
    }
}

/// SwiftUI host. The scene is built once and only *updated* on slider changes —
/// rebuilding per frame would thrash the GPU.
struct CupScene3D: NSViewRepresentable {
    let amount: Double
    var reduceMotion: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.buildScene()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true                 // drive the idle spin
        view.rendersContinuously = !reduceMotion
        view.allowsCameraControl = false
        context.coordinator.apply(amount: amount, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        view.rendersContinuously = !reduceMotion
        context.coordinator.apply(amount: amount, reduceMotion: reduceMotion)
    }

    @MainActor
    final class Coordinator {
        private var cupNode = SCNNode()
        private var liquidNode = SCNNode()
        private var creamNodes: [SCNNode] = []
        private var strawNode = SCNNode()
        private var spinning = false

        func buildScene() -> SCNScene {
            let scene = SCNScene()

            // Cup: tier 0 is the base mesh, tiers 1–3 are morph targets.
            let base = CupMesh.lathe(CupMesh.tiers[0])
            let bodyMaterial = SCNMaterial()
            bodyMaterial.lightingModel = .physicallyBased
            bodyMaterial.roughness.contents = 0.52
            bodyMaterial.metalness.contents = 0.0
            bodyMaterial.isDoubleSided = true
            base.materials = [bodyMaterial]

            cupNode = SCNNode(geometry: base)
            let morpher = SCNMorpher()
            morpher.targets = CupMesh.tiers.dropFirst().map { CupMesh.lathe($0) }
            morpher.calculationMode = .normalized
            cupNode.morpher = morpher
            scene.rootNode.addChildNode(cupNode)

            // Liquid disc, parented to the cup so it morphs along in position.
            let disc = SCNCylinder(radius: 0.34, height: 0.012)
            let liquidMaterial = SCNMaterial()
            liquidMaterial.lightingModel = .physicallyBased
            liquidMaterial.roughness.contents = 0.12
            liquidMaterial.metalness.contents = 0.0
            disc.materials = [liquidMaterial]
            liquidNode = SCNNode(geometry: disc)
            scene.rootNode.addChildNode(liquidNode)

            // Whipped cream: three stacked, offset spheres.
            for i in 0 ..< 3 {
                let s = SCNSphere(radius: 0.20 - CGFloat(i) * 0.045)
                let m = SCNMaterial()
                m.lightingModel = .physicallyBased
                m.diffuse.contents = NSColor(calibratedWhite: 0.98, alpha: 1)
                m.roughness.contents = 0.75
                s.materials = [m]
                let n = SCNNode(geometry: s)
                n.position = SCNVector3(
                    CGFloat(i % 2 == 0 ? -0.02 : 0.02), 0, CGFloat(i) * 0.015
                )
                creamNodes.append(n)
                scene.rootNode.addChildNode(n)
            }

            // Straw, in the Ventus accent.
            let straw = SCNCylinder(radius: 0.026, height: 0.62)
            let strawMaterial = SCNMaterial()
            strawMaterial.lightingModel = .physicallyBased
            strawMaterial.diffuse.contents = NSColor(VentusPalette.accent)
            strawMaterial.roughness.contents = 0.30
            straw.materials = [strawMaterial]
            strawNode = SCNNode(geometry: straw)
            strawNode.eulerAngles.z = -0.28
            scene.rootNode.addChildNode(strawNode)

            // Lighting: warm key with soft shadow, cool fill, low ambient.
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 340
            key.light?.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
            key.light?.castsShadow = true
            key.light?.shadowRadius = 8
            key.light?.shadowSampleCount = 16
            key.light?.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.28)
            key.eulerAngles = SCNVector3(-0.9, 0.6, 0)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .omni
            fill.light?.intensity = 140
            fill.light?.color = NSColor(calibratedRed: 0.85, green: 0.92, blue: 1.0, alpha: 1)
            fill.position = SCNVector3(-1.6, 0.8, 1.6)
            scene.rootNode.addChildNode(fill)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 115
            scene.rootNode.addChildNode(ambient)

            // Framed for the tallest tier: cup (1.18) + cream stack (~0.35).
            // A look-at target keeps the composition fixed as the mesh morphs.
            let focus = SCNNode()
            focus.position = SCNVector3(0, 0.72, 0)
            scene.rootNode.addChildNode(focus)

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 34
            camera.camera?.wantsHDR = false
            camera.position = SCNVector3(0, 1.55, 3.9)
            let lookAt = SCNLookAtConstraint(target: focus)
            lookAt.isGimbalLockEnabled = true
            camera.constraints = [lookAt]
            scene.rootNode.addChildNode(camera)

            return scene
        }

        /// Maps the dollar amount onto morph weights, node transforms and
        /// material colours. Normalized morphing blends
        /// `base * (1 - Σw) + Σ(wᵢ · targetᵢ)`, so a pair of adjacent weights
        /// summing to 1 gives a clean crossfade between neighbouring tiers.
        func apply(amount: Double, reduceMotion: Bool) {
            let style = CupStyle.interpolated(for: amount)
            let anchors: [Double] = [5, 10, 20, 35]
            var weights = [Double](repeating: 0, count: 3)

            for i in 0 ..< (anchors.count - 1) where amount <= anchors[i + 1] || i == anchors.count - 2 {
                guard amount >= anchors[i] || i == 0 else { continue }
                let span = anchors[i + 1] - anchors[i]
                let raw = min(max((amount - anchors[i]) / span, 0), 1)
                let t = raw * raw * (3 - 2 * raw)   // smoothstep, matches the 2D version
                if i > 0 { weights[i - 1] = 1 - t }
                weights[i] = t
                break
            }
            for (i, w) in weights.enumerated() {
                cupNode.morpher?.setWeight(CGFloat(w), forTargetAt: i)
            }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = reduceMotion ? 0 : 0.42

            cupNode.geometry?.firstMaterial?.diffuse.contents = Self.mix(style.bodyLight, style.bodyDark, 0.62)

            // Liquid sits just below the rim of the current blended silhouette.
            let height = blend(\.height, amount: amount)
            let topRadius = blend(\.topRadius, amount: amount)
            liquidNode.position = SCNVector3(0, height - 0.05, 0)
            liquidNode.scale = SCNVector3(
                (topRadius - 0.05) / 0.34, 1, (topRadius - 0.05) / 0.34
            )
            liquidNode.geometry?.firstMaterial?.diffuse.contents = NSColor(style.liquid)

            for (i, n) in creamNodes.enumerated() {
                let lift = height - 0.02 + CGFloat(i) * 0.10
                n.position = SCNVector3(n.position.x, lift, n.position.z)
                let rimScale = topRadius / 0.48
                let w = style.whip * rimScale
                n.scale = SCNVector3(w, w, w)
                n.opacity = style.whip
            }

            strawNode.position = SCNVector3(topRadius * 0.40, height + 0.10, 0.06)
            strawNode.opacity = style.straw
            strawNode.scale = SCNVector3(1, style.straw * 0.5 + 0.5, 1)

            SCNTransaction.commit()

            // Slow idle turntable — started once, and never under Reduce Motion.
            if !reduceMotion, !spinning {
                spinning = true
                cupNode.runAction(.repeatForever(
                    .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 26)
                ))
            }
        }

        /// Blends two SwiftUI colours into one NSColor for a PBR diffuse slot.
        static func mix(_ a: Color, _ b: Color, _ t: CGFloat) -> NSColor {
            let ca = NSColor(a).usingColorSpace(.sRGB) ?? .white
            let cb = NSColor(b).usingColorSpace(.sRGB) ?? .white
            return NSColor(
                srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
                green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
                alpha: 1
            )
        }

        private func blend(_ key: KeyPath<CupMesh.Silhouette, CGFloat>, amount: Double) -> CGFloat {
            let anchors: [Double] = [5, 10, 20, 35]
            if amount <= anchors[0] { return CupMesh.tiers[0][keyPath: key] }
            if amount >= anchors[3] { return CupMesh.tiers[3][keyPath: key] }
            for i in 0 ..< 3 where amount <= anchors[i + 1] {
                let raw = (amount - anchors[i]) / (anchors[i + 1] - anchors[i])
                let t = CGFloat(raw * raw * (3 - 2 * raw))
                let a = CupMesh.tiers[i][keyPath: key]
                let b = CupMesh.tiers[i + 1][keyPath: key]
                return a + (b - a) * t
            }
            return CupMesh.tiers[3][keyPath: key]
        }
    }
}
