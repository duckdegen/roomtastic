// SPDX-License-Identifier: MIT
import SwiftUI
import AVFoundation
import RoomPlan
import ARKit
import SceneKit
import RoomtasticShared

struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onFailure: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController(); controller.onCode = onCode; controller.onFailure = onFailure; return controller
    }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}
final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "org.roomtastic.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { onFailure?("Camera permission is required to scan the Mac QR code."); return }
            configure()
        }
    }
    private func configure() {
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else { throw CaptureError.rejected("A camera is not available.") }
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { throw CaptureError.rejected("Cannot start QR camera input.") }
            session.addInput(input)
            let metadata = AVCaptureMetadataOutput()
            guard session.canAddOutput(metadata) else { throw CaptureError.rejected("Cannot create QR scanner.") }
            session.addOutput(metadata); metadata.setMetadataObjectsDelegate(self, queue: .main); metadata.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; self.preview = preview; view.layer.addSublayer(preview); preview.frame = view.bounds
            cameraQueue.async { [session] in session.startRunning() }
        } catch { onFailure?(error.localizedDescription) }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true; stop(); onCode?(code)
    }
    func stop() { cameraQueue.async { [session] in session.stopRunning() } }
}
struct RoomScanner: UIViewRepresentable {
    @Binding var finish: Bool
    var onRoom: (CapturedRoom) -> Void
    var arSession: ARSession
    var onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onRoom: onRoom, onFailure: onFailure) }
    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero, arSession: arSession); view.delegate = context.coordinator; view.captureSession.run(configuration: RoomCaptureSession.Configuration()); return view
    }
    func updateUIView(_ view: RoomCaptureView, context: Context) {
        if finish && !context.coordinator.stopped { context.coordinator.stopped = true; view.captureSession.stop(pauseARSession: false) }
    }
    static func dismantleUIView(_ view: RoomCaptureView, coordinator: Coordinator) { if !coordinator.stopped { view.captureSession.stop(pauseARSession: false) } }
    final class Coordinator: UIViewController, RoomCaptureViewDelegate {
        var stopped = false
        let onRoom: (CapturedRoom) -> Void
        let onFailure: (String) -> Void
        init(onRoom: @escaping (CapturedRoom) -> Void, onFailure: @escaping (String) -> Void) { self.onRoom = onRoom; self.onFailure = onFailure; super.init(nibName: nil, bundle: nil) }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Storyboard initialization is unavailable.") }
        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
            if let error { onFailure(error.localizedDescription); return false }; return true
        }
        func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            if let error { onFailure(error.localizedDescription) } else { onRoom(processedResult) }
        }
    }
}

struct TrackingPreview: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView { let view = ARSCNView(frame: .zero); view.session = session; return view }
    func updateUIView(_ view: ARSCNView, context: Context) {}
}

struct SpatialPlacementView: UIViewControllerRepresentable {
    let session: ARSession
    let title: String
    let tags: [PhysicalSpeaker]
    let isRoomAligned: () -> Bool
    let onRelocalize: () -> Void
    let onPlace: (Point3, Double) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> SpatialPlacementController {
        let controller = SpatialPlacementController()
        controller.placement = self
        return controller
    }

    func updateUIViewController(_ controller: SpatialPlacementController, context: Context) {
        controller.placement = self
        controller.updateTags()
    }

    static func dismantleUIViewController(_ controller: SpatialPlacementController, coordinator: ()) {
        controller.stop()
    }
}

final class SpatialPlacementController: UIViewController {
    var placement: SpatialPlacementView!
    private let cameraView = ARSCNView(frame: .zero)
    private let tagRoot = SCNNode()
    private let targetNode = SCNNode(geometry: SCNSphere(radius: 0.018))
    private let statusLabel = UILabel()
    private let reticle = UILabel()
    private let placeButton = UIButton(type: .system)
    private var displayLink: CADisplayLink?
    private var delivered = false
    private var renderedTags: [TagAppearance] = []
    private var tagsRendered = false

    private struct TagAppearance: Equatable {
        let id: UUID
        let name: String
        let point: Point3
        let facing: Double
        let sub: Bool
    }

    private struct Target {
        let point: Point3
        let facing: Double
        let distance: Double
        let usesDepth: Bool
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        cameraView.session = placement.session
        cameraView.scene = SCNScene()
        cameraView.automaticallyUpdatesLighting = true
        cameraView.rendersContinuously = true
        cameraView.isPlaying = true
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cameraView)
        NSLayoutConstraint.activate([
            cameraView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cameraView.topAnchor.constraint(equalTo: view.topAnchor),
            cameraView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        cameraView.scene.rootNode.addChildNode(tagRoot)
        targetNode.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGreen
        targetNode.geometry?.firstMaterial?.lightingModel = .constant
        targetNode.isHidden = true
        cameraView.scene.rootNode.addChildNode(targetNode)

        reticle.text = "+"
        reticle.font = .systemFont(ofSize: 44, weight: .light)
        reticle.textColor = .white
        reticle.textAlignment = .center
        reticle.translatesAutoresizingMaskIntoConstraints = false
        reticle.isAccessibilityElement = false
        view.addSubview(reticle)
        NSLayoutConstraint.activate([
            reticle.centerXAnchor.constraint(equalTo: cameraView.centerXAnchor),
            reticle.centerYAnchor.constraint(equalTo: cameraView.centerYAnchor)
        ])

        let heading = UILabel()
        heading.text = placement.title
        heading.font = .preferredFont(forTextStyle: .headline)
        let instructions = UILabel()
        instructions.text = "Aim the crosshair at the speaker’s acoustic center on its front face, then tap Place. For a subwoofer, aim at the center of its front face. This tags what you aim at; it does not recognize speakers."
        instructions.font = .preferredFont(forTextStyle: .subheadline)
        addPanel([heading, instructions], atTop: true)

        statusLabel.text = "Look around the scanned room to align tracking."
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.accessibilityIdentifier = "spatialPlacementStatus"
        let facingNote = UILabel()
        facingNote.text = "Facing is suggested toward this camera; adjust it in the editor afterward. Blue sphere: speaker. Orange box: linked subwoofer. Arrows show facing."
        facingNote.font = .preferredFont(forTextStyle: .caption1)
        placeButton.configuration = .filled()
        placeButton.setTitle("Place", for: .normal)
        placeButton.isEnabled = false
        placeButton.addTarget(self, action: #selector(confirmPlacement), for: .touchUpInside)
        let relocalize = UIButton(type: .system)
        relocalize.setTitle("Relocalize saved room", for: .normal)
        relocalize.addTarget(self, action: #selector(relocalizeRoom), for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.accessibilityIdentifier = "placement.cancel"
        cancel.addTarget(self, action: #selector(cancelPlacement), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [cancel, relocalize])
        actions.axis = .horizontal
        actions.distribution = .equalSpacing
        addPanel([statusLabel, facingNote, placeButton, actions], atTop: false)
        updateTags()
    }

    private func addPanel(_ views: [UIView], atTop: Bool) {
        let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        panel.layer.cornerRadius = 16
        panel.clipsToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for case let label as UILabel in views {
            label.textColor = .white
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        panel.contentView.addSubview(stack)
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            atTop ? panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
                : panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -12)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard displayLink == nil, !delivered else { return }
        cameraView.isPlaying = true
        cameraView.rendersContinuously = true
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
        link.preferredFramesPerSecond = 10
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        cameraView.isPlaying = false
        cameraView.rendersContinuously = false
        // The recorder owns the shared ARSession; dismissing this view must not pause it.
    }

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var controller: SpatialPlacementController?
        init(_ controller: SpatialPlacementController) { self.controller = controller }
        @objc func tick() { controller?.refreshTarget() }
    }

    func updateTags() {
        guard isViewLoaded else { return }
        let appearances = placement.tags.map {
            TagAppearance(id: $0.id, name: $0.name, point: $0.position, facing: $0.facingRadians, sub: $0.linkedSubwoofer)
        }
        guard !tagsRendered || appearances != renderedTags else { return }
        tagsRendered = true
        renderedTags = appearances
        tagRoot.childNodes.forEach { $0.removeFromParentNode() }
        for tag in appearances {
            guard [tag.point.x, tag.point.y, tag.point.z, tag.facing].allSatisfy(\.isFinite) else { continue }
            let root = SCNNode()
            root.position = SCNVector3(Float(tag.point.x), Float(tag.point.y), Float(tag.point.z))
            let color: UIColor = tag.sub ? .systemOrange : .systemBlue
            let marker = SCNNode(geometry: tag.sub
                ? SCNBox(width: 0.075, height: 0.075, length: 0.075, chamferRadius: 0.006)
                : SCNSphere(radius: 0.045))
            marker.geometry?.firstMaterial?.diffuse.contents = color
            marker.geometry?.firstMaterial?.lightingModel = .constant
            root.addChildNode(marker)
            let arrow = SCNNode()
            arrow.eulerAngles.y = -Float(tag.facing)
            let stem = SCNNode(geometry: SCNCylinder(radius: 0.007, height: 0.18))
            stem.position.z = -0.09
            stem.eulerAngles.x = -.pi / 2
            let tip = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.025, height: 0.05))
            tip.position.z = -0.205
            tip.eulerAngles.x = -.pi / 2
            for node in [stem, tip] {
                node.geometry?.firstMaterial?.diffuse.contents = color
                node.geometry?.firstMaterial?.lightingModel = .constant
                arrow.addChildNode(node)
            }
            root.addChildNode(arrow)
            let text = SCNText(string: "\(tag.sub ? "SUB" : "SPEAKER") · \(tag.name)", extrusionDepth: 0)
            text.font = .systemFont(ofSize: 12, weight: .semibold)
            text.flatness = 0.5
            text.firstMaterial?.diffuse.contents = color
            text.firstMaterial?.lightingModel = .constant
            let label = SCNNode(geometry: text)
            label.scale = SCNVector3(0.004, 0.004, 0.004)
            label.position.y = 0.08
            let bounds = label.boundingBox
            label.pivot = SCNMatrix4MakeTranslation((bounds.min.x + bounds.max.x) / 2, bounds.min.y, 0)
            label.constraints = [SCNBillboardConstraint()]
            root.addChildNode(label)
            tagRoot.addChildNode(root)
        }
        tagRoot.isHidden = !placement.isRoomAligned()
    }

    private func trackingProblem(_ frame: ARFrame?) -> String? {
        guard placement.isRoomAligned() else {
            return "Room alignment is not ready. Look around the scanned room, or tap Relocalize saved room."
        }
        guard let frame, (0...0.25).contains(CACurrentMediaTime() - frame.timestamp) else {
            return "Waiting for a fresh camera frame. Keep the camera uncovered."
        }
        guard case .normal = frame.camera.trackingState else {
            return "Tracking is limited. Move slowly and look at textured parts of the scanned room."
        }
        return nil
    }

    private func refreshTarget() {
        guard !delivered else { return }
        let frame = placement.session.currentFrame
        let problem = trackingProblem(frame)
        tagRoot.isHidden = problem != nil
        let target = problem == nil ? currentTarget() : nil
        placeButton.isEnabled = target != nil
        targetNode.isHidden = target == nil
        reticle.textColor = target == nil ? .white : .systemGreen
        if let target {
            targetNode.position = SCNVector3(Float(target.point.x), Float(target.point.y), Float(target.point.z))
            let source = target.usesDepth
                ? "Depth on the aimed surface."
                : "Surface placement: estimated plane hit; verify it is the speaker front, not the wall or floor behind it."
            statusLabel.text = String(format: "%.2f m away · room Y %.2f m\n%@", target.distance, target.point.y, source)
        } else {
            statusLabel.text = problem ?? "No reliable surface under the crosshair (0.15–8 m). Move slowly or change your angle. Nothing will be placed until a real surface is found."
        }
    }

    private func currentTarget() -> Target? {
        guard let frame = placement.session.currentFrame, trackingProblem(frame) == nil,
              cameraView.bounds.width > 0, cameraView.bounds.height > 0 else { return nil }
        let center = CGPoint(x: cameraView.bounds.midX, y: cameraView.bounds.midY)
        let world: SIMD3<Float>
        let usesDepth: Bool
        if let depthPoint = depthTarget(frame) {
            world = depthPoint
            usesDepth = true
        } else if let query = cameraView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
                  let hit = placement.session.raycast(query).first {
            let p = hit.worldTransform.columns.3
            world = SIMD3(p.x, p.y, p.z)
            usesDepth = false
        } else {
            return nil
        }
        let camera = frame.camera.transform.columns.3
        let towardCamera = SIMD3(camera.x, camera.y, camera.z) - world
        let distance = Double(simd_length(towardCamera))
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite, distance.isFinite,
              (0.15...8).contains(distance),
              simd_length(SIMD2(towardCamera.x, towardCamera.z)) > 0.01,
              trackingProblem(placement.session.currentFrame) == nil,
              (0...0.25).contains(CACurrentMediaTime() - frame.timestamp) else { return nil }
        return Target(point: Point3(x: Double(world.x), y: Double(world.y), z: Double(world.z)),
                      facing: atan2(Double(towardCamera.x), -Double(towardCamera.z)),
                      distance: distance, usesDepth: usesDepth)
    }

    private func depthTarget(_ frame: ARFrame) -> SIMD3<Float>? {
        guard let depth = frame.sceneDepth, let confidence = depth.confidenceMap,
              let orientation = view.window?.windowScene?.interfaceOrientation,
              orientation != .unknown else { return nil }
        let imagePoint = CGPoint(x: 0.5, y: 0.5).applying(
            frame.displayTransform(for: orientation, viewportSize: cameraView.bounds.size).inverted())
        guard imagePoint.x.isFinite, imagePoint.y.isFinite,
              (0..<1).contains(imagePoint.x), (0..<1).contains(imagePoint.y) else { return nil }
        let map = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8 else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard width > 0, height > 0,
              CVPixelBufferGetWidth(confidence) == width,
              CVPixelBufferGetHeight(confidence) == height else { return nil }
        guard CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let x = Int(imagePoint.x * CGFloat(width)), y = Int(imagePoint.y * CGFloat(height))
        let quality = confidenceBase.advanced(by: y * CVPixelBufferGetBytesPerRow(confidence))
            .assumingMemoryBound(to: UInt8.self)[x]
        guard quality >= UInt8(ARConfidenceLevel.medium.rawValue) else { return nil }
        let meters = base.advanced(by: y * CVPixelBufferGetBytesPerRow(map))
            .assumingMemoryBound(to: Float32.self)[x]
        guard meters.isFinite, (0.15...8).contains(meters) else { return nil }
        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let u = Float(imagePoint.x * resolution.width)
        let v = Float(imagePoint.y * resolution.height)
        let cameraPoint = SIMD4<Float>((u - intrinsics.columns.2.x) * meters / intrinsics.columns.0.x,
                                      -(v - intrinsics.columns.2.y) * meters / intrinsics.columns.1.y,
                                      -meters, 1)
        let point = frame.camera.transform * cameraPoint
        return SIMD3(point.x, point.y, point.z)
    }

    @objc private func confirmPlacement() {
        // Never commit the throttled preview: resolve the aim against a fresh frame again.
        guard !delivered, let target = currentTarget() else { refreshTarget(); return }
        delivered = true
        placeButton.isEnabled = false
        stop()
        placement.onPlace(target.point, target.facing)
    }

    @objc private func relocalizeRoom() {
        guard !delivered else { return }
        placeButton.isEnabled = false
        targetNode.isHidden = true
        tagRoot.isHidden = true
        placement.onRelocalize()
        refreshTarget()
    }

    @objc private func cancelPlacement() {
        guard !delivered else { return }
        delivered = true
        stop()
        placement.onCancel()
    }
}
