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
        lathe(points: silhouette.points)
    }

    /// Same revolution, for any open polyline — used by the liquid body, whose
    /// profile is derived from the cup interior rather than from a Silhouette.
    static func lathe(points: [CGPoint]) -> SCNGeometry {
        let profile = resample(points, to: profileSamples)
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

/// The drink itself. Two parts, because they have different jobs:
///
/// - the **body** is a solid of revolution derived from the cup's own interior,
///   so the liquid always meets the wall. The previous flat disc could only
///   scale, which is why it appeared to hover and shrink rather than fill.
/// - the **surface** is a height field rebuilt each frame from the slosh state,
///   which is what makes the slider feel physical.
enum LiquidMesh {
    /// Fraction of the cup's interior height the drink fills. Deliberately shy
    /// of the rim so a hard slosh cannot push the surface through the lip.
    static let fillFraction: CGFloat = 0.88
    /// Pulled in from the wall so the two surfaces never z-fight.
    static let wallInset: CGFloat = 0.006

    static let surfaceRings = 12
    static let surfaceSegments = 48

    /// Interior floor of the cup, matching `Silhouette.points`.
    private static let floorY: CGFloat = 0.06

    static func innerRadius(_ s: CupMesh.Silhouette, atY y: CGFloat) -> CGFloat {
        let bottom = s.bottomRadius - s.wall
        let top = s.topRadius - s.wall
        let span = max(s.height - floorY, 0.0001)
        let t = min(max((y - floorY) / span, 0), 1)
        return bottom + (top - bottom) * t - wallInset
    }

    static func fillHeight(_ s: CupMesh.Silhouette) -> CGFloat {
        floorY + (s.height - floorY) * fillFraction
    }

    /// Bottom cap plus side wall — no top, because the surface is its own mesh.
    static func body(_ s: CupMesh.Silhouette) -> SCNGeometry {
        let y0 = floorY + 0.004
        let y1 = fillHeight(s)
        let r0 = innerRadius(s, atY: y0)
        let rMid = innerRadius(s, atY: (y0 + y1) / 2)
        let r1 = innerRadius(s, atY: y1)
        return CupMesh.lathe(points: [
            CGPoint(x: 0, y: y0),
            CGPoint(x: r0 * 0.65, y: y0),
            CGPoint(x: r0, y: y0 + 0.012),
            CGPoint(x: rMid, y: (y0 + y1) / 2),
            CGPoint(x: r1, y: y1),
        ])
    }

    struct SurfaceParams {
        var radius: CGFloat
        var tiltX: CGFloat
        var tiltZ: CGFloat
        var ripple: CGFloat
        var phase: CGFloat
    }

    /// Displacement of the surface at a point, as a height field. Tilt is the
    /// bulk sway; the cosine term is the concentric ring that travels outward
    /// after a knock, scaled by radius so the centre stays calm.
    private static func height(x: CGFloat, z: CGFloat, _ p: SurfaceParams) -> CGFloat {
        let d = hypot(x, z)
        let n = p.radius > 0 ? d / p.radius : 0
        return p.tiltX * x + p.tiltZ * z + p.ripple * cos(p.phase - n * 9) * n
    }

    static func surface(_ p: SurfaceParams) -> SCNGeometry {
        let rings = surfaceRings, segs = surfaceSegments
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        vertices.reserveCapacity((rings + 1) * (segs + 1))

        let e: CGFloat = 0.008
        for ring in 0 ... rings {
            let r = p.radius * CGFloat(ring) / CGFloat(rings)
            for seg in 0 ... segs {
                let a = CGFloat(seg) / CGFloat(segs) * .pi * 2
                let x = r * cos(a), z = r * sin(a)
                vertices.append(SCNVector3(x, height(x: x, z: z, p), z))

                // Numeric gradient of the height field — exact enough at this
                // density, and immune to drift if the field gains terms.
                let hx = (height(x: x + e, z: z, p) - height(x: x - e, z: z, p)) / (2 * e)
                let hz = (height(x: x, z: z + e, p) - height(x: x, z: z - e, p)) / (2 * e)
                let len = max(sqrt(hx * hx + 1 + hz * hz), 0.0001)
                normals.append(SCNVector3(-hx / len, 1 / len, -hz / len))
            }
        }

        var indices: [Int32] = []
        for ring in 0 ..< rings {
            for seg in 0 ..< segs {
                let a = Int32(ring * (segs + 1) + seg)
                let b = a + 1
                let c = Int32((ring + 1) * (segs + 1) + seg)
                let d = c + 1
                // Wound so the face normal agrees with the height-field normal
                // (+Y). The obvious order points the geometric normal down, and
                // a double-sided material then shades the surface as if it were
                // lit from beneath — which reads as near-black.
                indices += [a, b, c, b, d, c]
            }
        }

        return SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals),
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }
}

/// Damped harmonic oscillator standing in for the liquid's bulk motion. Not a
/// fluid sim — a spring whose displacement is read as surface tilt, which is
/// what "baked" liquid motion in a product shot actually is. Dragging the
/// slider kicks it; it rings down on its own.
struct Slosh {
    var tiltX: CGFloat = 0
    var tiltZ: CGFloat = 0
    private var vx: CGFloat = 0
    private var vz: CGFloat = 0
    var ripple: CGFloat = 0
    var phase: CGFloat = 0

    private static let stiffness: CGFloat = 52
    private static let damping: CGFloat = 5.0
    private static let maxTilt: CGFloat = 0.16

    /// `delta` is the per-second rate of change of the displayed amount, so a
    /// fast drag sloshes hard and a slow one barely disturbs the surface.
    mutating func kick(_ delta: CGFloat) {
        vx += delta * 0.055
        vz += delta * 0.022
        ripple = min(ripple + abs(delta) * 0.0016, 0.030)
    }

    mutating func step(_ dt: CGFloat) {
        let dt = min(dt, 1.0 / 30)          // never integrate a stalled frame
        vx += (-Self.stiffness * tiltX - Self.damping * vx) * dt
        vz += (-Self.stiffness * tiltZ - Self.damping * vz) * dt
        tiltX = min(max(tiltX + vx * dt, -Self.maxTilt), Self.maxTilt)
        tiltZ = min(max(tiltZ + vz * dt, -Self.maxTilt), Self.maxTilt)
        phase += dt * 7
        ripple *= exp(-dt * 2.4)
    }

    var isAtRest: Bool {
        abs(tiltX) < 0.0006 && abs(tiltZ) < 0.0006
            && abs(vx) < 0.004 && abs(vz) < 0.004 && ripple < 0.0008
    }
}

/// Drives every shape-valued property from a single eased `displayAmount`, so
/// the cup, the liquid and the slosh can never disagree about which tier is on
/// screen. SceneKit calls the renderer delegate on its own thread, so the
/// target is guarded and the class is deliberately not main-actor isolated.
final class LiquidAnimator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var target: Double = 10
    private var display: Double = 10
    private var primed = false
    private var slosh = Slosh()
    private var lastTime: TimeInterval = -1

    private let cupNode: SCNNode
    private let liquidBodyNode: SCNNode
    private let liquidSurfaceNode: SCNNode
    private let creamNodes: [SCNNode]
    private let strawNode: SCNNode

    init(cup: SCNNode, body: SCNNode, surface: SCNNode, cream: [SCNNode], straw: SCNNode) {
        self.cupNode = cup
        self.liquidBodyNode = body
        self.liquidSurfaceNode = surface
        self.creamNodes = cream
        self.strawNode = straw
    }

    func setTarget(_ amount: Double) {
        lock.lock(); target = amount; lock.unlock()
    }

    /// Reduce Motion path: no render loop is running, so snap and draw once.
    func snap(to amount: Double) {
        lock.lock(); target = amount; display = amount; primed = true; lock.unlock()
        slosh = Slosh()
        applyGeometry(for: amount)
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        let target = self.target
        let wasPrimed = primed
        primed = true
        lock.unlock()

        let dt = lastTime < 0 ? 1.0 / 60 : min(time - lastTime, 0.1)
        lastTime = time

        if !wasPrimed {
            display = target                      // opening the sheet must not animate in
        } else {
            let before = display
            // Exponential approach, tuned to settle in ~0.4 s like the old
            // SCNTransaction duration it replaces.
            display += (target - display) * min(1, dt * 11)
            let rate = dt > 0 ? (display - before) / dt : 0
            slosh.kick(CGFloat(rate))
        }
        slosh.step(CGFloat(dt))
        applyGeometry(for: display)
    }

    private func applyGeometry(for amount: Double) {
        let anchors: [Double] = [5, 10, 20, 35]
        var weights = [Double](repeating: 0, count: 3)
        for i in 0 ..< 3 where amount <= anchors[i + 1] || i == 2 {
            guard amount >= anchors[i] || i == 0 else { continue }
            let raw = min(max((amount - anchors[i]) / (anchors[i + 1] - anchors[i]), 0), 1)
            let t = raw * raw * (3 - 2 * raw)
            if i > 0 { weights[i - 1] = 1 - t }
            weights[i] = t
            break
        }
        for (i, w) in weights.enumerated() {
            cupNode.morpher?.setWeight(CGFloat(w), forTargetAt: i)
            liquidBodyNode.morpher?.setWeight(CGFloat(w), forTargetAt: i)
        }

        let s = Self.blendedSilhouette(amount)
        let fillY = LiquidMesh.fillHeight(s)
        let fillR = LiquidMesh.innerRadius(s, atY: fillY)

        liquidSurfaceNode.position = SCNVector3(0, fillY, 0)
        let surface = LiquidMesh.surface(.init(
            radius: fillR,
            tiltX: slosh.tiltX, tiltZ: slosh.tiltZ,
            ripple: slosh.ripple, phase: slosh.phase
        ))
        surface.materials = liquidSurfaceNode.geometry?.materials ?? []
        liquidSurfaceNode.geometry = surface

        let style = CupStyle.shape(for: amount)
        for (i, n) in creamNodes.enumerated() {
            let lift = s.height - 0.02 + CGFloat(i) * 0.10
            n.position = SCNVector3(n.position.x, lift, n.position.z)
            let w = style.whip * (s.topRadius / 0.48)
            n.scale = SCNVector3(w, w, w)
        }

        // The straw rides the surface: it leans with the slosh instead of
        // standing in a liquid that is visibly tipping around it.
        strawNode.position = SCNVector3(s.topRadius * 0.40, s.height + 0.10, 0.06)
        strawNode.scale = SCNVector3(1, style.straw * 0.5 + 0.5, 1)
        strawNode.eulerAngles = SCNVector3(slosh.tiltZ * 0.6, 0, -0.28 + slosh.tiltX * 0.6)
    }

    #if DEBUG
    /// Test hook: poses the surface without running the loop, so the slosh
    /// shape can be checked in a deterministic offscreen render.
    func debugPose(amount: Double, tiltX: CGFloat, ripple: CGFloat, phase: CGFloat) {
        lock.lock(); target = amount; display = amount; primed = true; lock.unlock()
        slosh.tiltX = tiltX
        slosh.ripple = ripple
        slosh.phase = phase
        applyGeometry(for: amount)
    }
    #endif

    private static func blendedSilhouette(_ amount: Double) -> CupMesh.Silhouette {
        let anchors: [Double] = [5, 10, 20, 35]
        if amount <= anchors[0] { return CupMesh.tiers[0] }
        if amount >= anchors[3] { return CupMesh.tiers[3] }
        for i in 0 ..< 3 where amount <= anchors[i + 1] {
            let raw = (amount - anchors[i]) / (anchors[i + 1] - anchors[i])
            let t = CGFloat(raw * raw * (3 - 2 * raw))
            let a = CupMesh.tiers[i], b = CupMesh.tiers[i + 1]
            return .init(
                bottomRadius: a.bottomRadius + (b.bottomRadius - a.bottomRadius) * t,
                topRadius: a.topRadius + (b.topRadius - a.topRadius) * t,
                height: a.height + (b.height - a.height) * t,
                wall: a.wall + (b.wall - a.wall) * t
            )
        }
        return CupMesh.tiers[3]
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
        view.allowsCameraControl = false
        context.coordinator.attach(to: view)
        context.coordinator.apply(amount: amount, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(amount: amount, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        /// Everything that makes up the drink, so the turntable rotates one
        /// object. Spinning only the cup would leave the straw hanging still.
        private var assemblyNode = SCNNode()
        private var cupNode = SCNNode()
        private var liquidBodyNode = SCNNode()
        private var liquidSurfaceNode = SCNNode()
        private var creamNodes: [SCNNode] = []
        private var strawNode = SCNNode()
        private var reduceMotion = false
        private var animator: LiquidAnimator?

        private weak var view: SCNView?
        private var activityObservers: [NSObjectProtocol] = []

        private static let spinKey = "ventus.cup.turntable"

        // MARK: - Playback

        /// A menu-bar app is resident for days, so the renderer must never run
        /// on a sheet nobody is looking at: rendering is gated on the app being
        /// active as well as on Reduce Motion.
        func attach(to view: SCNView) {
            self.view = view
            let animator = LiquidAnimator(
                cup: cupNode, body: liquidBodyNode, surface: liquidSurfaceNode,
                cream: creamNodes, straw: strawNode
            )
            self.animator = animator
            view.delegate = animator
            let center = NotificationCenter.default
            for name in [NSApplication.didBecomeActiveNotification,
                         NSApplication.didResignActiveNotification] {
                activityObservers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refreshPlayback() }
                    }
                )
            }
            refreshPlayback()
        }

        func detach() {
            activityObservers.forEach(NotificationCenter.default.removeObserver)
            activityObservers = []
            assemblyNode.removeAction(forKey: Self.spinKey)
            view?.isPlaying = false
            view?.rendersContinuously = false
            view = nil
        }

        deinit {
            activityObservers.forEach(NotificationCenter.default.removeObserver)
        }

        private func refreshPlayback() {
            let live = !reduceMotion && NSApp.isActive
            view?.isPlaying = live
            view?.rendersContinuously = live

            // Reduce Motion can be switched on while the sheet is open, so the
            // action has to be removable, not just skippable at start-up.
            if live {
                if assemblyNode.action(forKey: Self.spinKey) == nil {
                    assemblyNode.runAction(
                        .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 26)),
                        forKey: Self.spinKey
                    )
                }
            } else {
                assemblyNode.removeAction(forKey: Self.spinKey)
            }
        }

        func buildScene() -> SCNScene {
            let scene = SCNScene()
            assemblyNode = SCNNode()
            scene.rootNode.addChildNode(assemblyNode)

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
            assemblyNode.addChildNode(cupNode)

            // Liquid body: a solid of revolution taken from the cup interior,
            // morphing on the same weights as the cup so it stays in contact
            // with the wall at every blend.
            func liquidMaterial(roughness: CGFloat) -> SCNMaterial {
                let m = SCNMaterial()
                m.lightingModel = .physicallyBased
                m.roughness.contents = roughness
                m.metalness.contents = 0.0
                m.isDoubleSided = true
                return m
            }

            let bodyGeo = LiquidMesh.body(CupMesh.tiers[0])
            bodyGeo.materials = [liquidMaterial(roughness: 0.22)]
            liquidBodyNode = SCNNode(geometry: bodyGeo)
            let liquidMorpher = SCNMorpher()
            liquidMorpher.targets = CupMesh.tiers.dropFirst().map { LiquidMesh.body($0) }
            liquidMorpher.calculationMode = .normalized
            liquidBodyNode.morpher = liquidMorpher
            assemblyNode.addChildNode(liquidBodyNode)

            // Liquid surface: rebuilt per frame from the slosh state. Glossier
            // than the body so it catches a moving highlight as it tips.
            let surfaceGeo = LiquidMesh.surface(
                .init(radius: 0.30, tiltX: 0, tiltZ: 0, ripple: 0, phase: 0)
            )
            surfaceGeo.materials = [liquidMaterial(roughness: 0.14)]
            liquidSurfaceNode = SCNNode(geometry: surfaceGeo)
            assemblyNode.addChildNode(liquidSurfaceNode)

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
                assemblyNode.addChildNode(n)
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
            assemblyNode.addChildNode(strawNode)

            // Lighting. The previous rig was three raw lights and a heavy
            // ambient, which is why every tier flattened to the same white: a
            // constant ambient term washes out exactly the shading that tells
            // the colours apart. An image-based environment replaces it, so
            // the PBR materials get a real gradient and a softbox highlight,
            // and ambient drops to almost nothing.
            scene.lightingEnvironment.contents = Self.studioEnvironment()
            scene.lightingEnvironment.intensity = 1.15

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 560
            key.light?.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
            key.light?.castsShadow = true
            key.light?.shadowRadius = 7
            key.light?.shadowSampleCount = 16
            key.light?.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.30)
            key.eulerAngles = SCNVector3(-0.85, 0.55, 0)
            scene.rootNode.addChildNode(key)

            // Rim from behind-left: separates the cup from the sheet background
            // without lifting the body colour the way a fill light does.
            let rim = SCNNode()
            rim.light = SCNLight()
            rim.light?.type = .directional
            rim.light?.intensity = 430
            rim.light?.color = NSColor(calibratedRed: 0.82, green: 0.89, blue: 1.0, alpha: 1)
            rim.eulerAngles = SCNVector3(-0.30, 2.5, 0)
            scene.rootNode.addChildNode(rim)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 22
            scene.rootNode.addChildNode(ambient)

            // Framed for the tallest tier: cup (1.18) + cream stack (~0.35).
            // A look-at target keeps the composition fixed as the mesh morphs.
            let focus = SCNNode()
            focus.position = SCNVector3(0, 0.60, 0)
            scene.rootNode.addChildNode(focus)

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 34
            camera.camera?.wantsHDR = false
            // Raised to ~25° above the focus. At the old near-level angle the
            // rim occluded the drink entirely — the previous flat disc only
            // showed because it floated just under the lip.
            camera.position = SCNVector3(0, 2.30, 3.70)
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

            // Every shape-valued property belongs to the animator, driven from
            // one eased value so the cup and the liquid can never disagree
            // about which tier is on screen. Only colour and opacity are set
            // here: they need AppKit, and the render thread must not touch it.
            self.reduceMotion = reduceMotion
            if reduceMotion {
                animator?.snap(to: amount)
            } else {
                animator?.setTarget(amount)
            }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = reduceMotion ? 0 : 0.42
            cupNode.geometry?.firstMaterial?.diffuse.contents =
                Self.mix(style.bodyLight, style.bodyDark, 0.62)
            liquidBodyNode.geometry?.firstMaterial?.diffuse.contents = NSColor(style.liquidDeep)
            liquidSurfaceNode.geometry?.firstMaterial?.diffuse.contents = NSColor(style.liquid)
            for n in creamNodes { n.opacity = style.whip }
            strawNode.opacity = style.straw
            SCNTransaction.commit()

            refreshPlayback()
        }

        #if DEBUG
        func debugPose(amount: Double, tiltX: CGFloat, ripple: CGFloat, phase: CGFloat) {
            animator?.debugPose(amount: amount, tiltX: tiltX, ripple: ripple, phase: phase)
        }
        #endif

        /// Procedural studio environment: a soft vertical gradient with one
        /// bright softbox high on the left. Generated rather than shipped as an
        /// asset, for the same reason the meshes are - zero bundle bytes.
        private static func studioEnvironment() -> NSImage {
            let w = 256, h = 128
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: w * 3, bitsPerPixel: 24
            ), let data = rep.bitmapData else { return NSImage(size: .zero) }

            for y in 0 ..< h {
                let v = CGFloat(y) / CGFloat(h - 1)
                // Sky above, floor below, soft horizon between.
                let base = 0.93 - 0.78 * (v * v * (3 - 2 * v))
                for x in 0 ..< w {
                    let u = CGFloat(x) / CGFloat(w - 1)
                    let du = u - 0.27, dv = v - 0.20
                    let box = exp(-(du * du * 26 + dv * dv * 42)) * 0.85
                    let l = min(base + box, 1)
                    // Warm high, cool low, so curved surfaces pick up a colour
                    // gradient instead of a flat grey ramp.
                    let r = min(l * (1 + 0.06 * (1 - v)), 1)
                    let b = min(l * (1 + 0.09 * v), 1)
                    let o = (y * w + x) * 3
                    data[o] = UInt8(r * 255)
                    data[o + 1] = UInt8(l * 255)
                    data[o + 2] = UInt8(b * 255)
                }
            }
            let image = NSImage(size: NSSize(width: w, height: h))
            image.addRepresentation(rep)
            return image
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

    }
}
