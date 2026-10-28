import UIKit
import ImageIO
import ExpoModulesCore

/// Expo asks this subscriber before rotating any window. Only the photo viewer
/// expands the mask; the viewfinder and every other app screen stay portrait.
public final class CameraOrientationSubscriber: ExpoAppDelegateSubscriber {
  static var viewingPhoto = false // main thread only

  public func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    return Self.viewingPhoto ? .allButUpsideDown : .portrait
  }
}

/// A single immutable, app-owned snapshot, not a gallery or an editor.
/// UIKit owns pinch focal points, zoom bounds, pan inertia and edge bounce.
final class CameraPhotoViewer: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  private let file: URL
  private let facts: [String: Any]
  private let image: UIImage
  private let onClose: (Bool) -> Void
  private let removePhoto: (@escaping (String?) -> Void) -> Void
  private let scroll = UIScrollView()
  private let photo = UIImageView()
  private let backdrop = UIView()
  private let top = UIView()
  private let bottom = UIStackView()
  private var viewport = CGSize.zero
  private var chromeHidden = false
  private var closing = false
  private var deleting = false
  private var zoomInProgress = false
  private let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
  private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(dragToClose(_:)))

  init(file: URL, facts: [String: Any], image: UIImage,
       removePhoto: @escaping (@escaping (String?) -> Void) -> Void,
       onClose: @escaping (Bool) -> Void) {
    self.file = file
    self.facts = facts
    self.image = image
    self.removePhoto = removePhoto
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var prefersStatusBarHidden: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    CameraOrientationSubscriber.viewingPhoto ? .allButUpsideDown : .portrait
  }
  override var shouldAutorotate: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    backdrop.backgroundColor = .black
    view.addSubview(backdrop)
    scroll.delegate = self
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 6
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.bouncesZoom = true
    scroll.alwaysBounceVertical = false
    scroll.alwaysBounceHorizontal = false
    photo.image = image
    photo.contentMode = .scaleAspectFit
    photo.isAccessibilityElement = true
    photo.accessibilityLabel = text("最近拍摄的照片", "Latest photo")
    photo.accessibilityHint = text("使用操作菜单放大或还原照片", "Use actions to zoom in or fit the photo")
    photo.accessibilityCustomActions = [
      UIAccessibilityCustomAction(name: text("放大", "Zoom in"), target: self, selector: #selector(accessibleZoomIn)),
      UIAccessibilityCustomAction(name: text("显示全图", "Fit photo"), target: self, selector: #selector(accessibleZoomOut)),
    ]
    scroll.addSubview(photo)
    view.addSubview(scroll)

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
    tap.require(toFail: doubleTap)
    scroll.addGestureRecognizer(doubleTap)
    scroll.addGestureRecognizer(tap)
    dismissPan.maximumNumberOfTouches = 1
    dismissPan.delegate = self
    scroll.addGestureRecognizer(dismissPan)
    scroll.panGestureRecognizer.require(toFail: dismissPan)

    view.addSubview(top)
    let closeButton = button("xmark", text("关闭", "Close"), #selector(closeTapped))
    top.addSubview(closeButton)
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      closeButton.leadingAnchor.constraint(equalTo: top.leadingAnchor),
      closeButton.topAnchor.constraint(equalTo: top.topAnchor),
      closeButton.bottomAnchor.constraint(equalTo: top.bottomAnchor),
    ])
    bottom.axis = .horizontal
    bottom.distribution = .equalSpacing
    bottom.addArrangedSubview(button("square.and.arrow.up", text("分享", "Share"), #selector(share)))
    bottom.addArrangedSubview(button("info.circle", text("照片信息", "Photo info"), #selector(info)))
    bottom.addArrangedSubview(button("ellipsis", text("更多", "More"), #selector(more)))
    view.addSubview(bottom)
    for chrome in [top, bottom] { chrome.translatesAutoresizingMaskIntoConstraints = false }
    NSLayoutConstraint.activate([
      top.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      top.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      top.heightAnchor.constraint(equalToConstant: 48),
      bottom.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
      bottom.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
      bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
      bottom.heightAnchor.constraint(equalToConstant: 48),
    ])
  }

  private func text(_ chinese: String, _ english: String) -> String { zh ? chinese : english }
  private func button(_ symbol: String, _ label: String, _ action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: symbol), for: .normal)
    button.tintColor = .white
    button.backgroundColor = UIColor(white: 0.12, alpha: 0.85)
    button.layer.cornerRadius = 24
    button.accessibilityLabel = label
    button.widthAnchor.constraint(equalToConstant: 48).isActive = true
    button.heightAnchor.constraint(equalToConstant: 48).isActive = true
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if #available(iOS 16.0, *) { setNeedsUpdateOfSupportedInterfaceOrientations() }
    UIViewController.attemptRotationToDeviceOrientation()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    backdrop.frame = view.bounds
    guard viewport != view.bounds.size, view.bounds.width > 0, image.size.width > 0 else { return }
    // Rotation fits the whole photo again. Hiding tools and opening sheets never
    // changes this viewport, so neither can move a zoomed photo underneath the user.
    viewport = view.bounds.size
    scroll.transform = .identity
    scroll.frame = view.bounds
    scroll.setZoomScale(1, animated: false)
    zoomInProgress = false
    scroll.contentInset = .zero
    let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
    photo.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
    scroll.contentSize = photo.bounds.size
    centerPhoto()
    scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
  // These delegate callbacks also cover animated zooms and bounce on iOS 15+.
  func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { zoomInProgress = true }
  func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPhoto() }
  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    zoomInProgress = false
    centerPhoto()
  }
  private func centerPhoto() {
    let x = max(0, (scroll.bounds.width - photo.frame.width) / 2)
    let y = max(0, (scroll.bounds.height - photo.frame.height) / 2)
    scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
  }

  @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
    guard !deleting else { return }
    if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: true); return }
    let point = gesture.location(in: photo)
    let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
    scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
  }
  @objc private func accessibleZoomIn() -> Bool { scroll.setZoomScale(min(6, scroll.zoomScale * 2), animated: true); return true }
  @objc private func accessibleZoomOut() -> Bool { scroll.setZoomScale(1, animated: true); return true }
  @objc private func toggleChrome() {
    chromeHidden.toggle()
    // Keep an explicit close action available to VoiceOver.
    let hidden = chromeHidden && !UIAccessibility.isVoiceOverRunning
    top.isUserInteractionEnabled = !hidden
    bottom.isUserInteractionEnabled = !hidden
    top.accessibilityElementsHidden = hidden
    bottom.accessibilityElementsHidden = hidden
    UIView.animate(withDuration: 0.18) { self.top.alpha = hidden ? 0 : 1; self.bottom.alpha = hidden ? 0 : 1 }
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === dismissPan else { return true }
    let velocity = dismissPan.velocity(in: view)
    return !deleting && !closing && presentedViewController == nil && scroll.zoomScale <= 1.001
      && !scroll.isZooming && !scroll.isZoomBouncing && !zoomInProgress
      && velocity.y > 0 && velocity.y > abs(velocity.x)
  }
  @objc private func dragToClose(_ gesture: UIPanGestureRecognizer) {
    let distance = max(0, gesture.translation(in: view).y)
    if gesture.state == .changed {
      if gesture.numberOfTouches != 1 {
        gesture.isEnabled = false; gesture.isEnabled = true
        resetDrag(); return
      }
      scroll.transform = CGAffineTransform(translationX: gesture.translation(in: view).x * 0.25, y: distance)
      backdrop.alpha = max(0.15, 1 - distance / max(1, view.bounds.height * 0.65))
      top.alpha = 0; bottom.alpha = 0
    } else if gesture.state == .ended {
      if distance > min(160, view.bounds.height * 0.22) || (distance > 30 && gesture.velocity(in: view).y > 900) {
        finish(deleted: false)
      } else { resetDrag() }
    } else if gesture.state == .cancelled || gesture.state == .failed { resetDrag() }
  }
  private func resetDrag() {
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22) {
      self.scroll.transform = .identity
      self.backdrop.alpha = 1
      let alpha: CGFloat = self.chromeHidden && !UIAccessibility.isVoiceOverRunning ? 0 : 1
      self.top.alpha = alpha; self.bottom.alpha = alpha
    }
  }

  @objc private func closeTapped() { if !deleting { finish(deleted: false) } }
  override func accessibilityPerformEscape() -> Bool { closeTapped(); return true }
  private func finish(deleted: Bool) {
    guard !closing else { return }
    closing = true
    CameraOrientationSubscriber.viewingPhoto = false
    if #available(iOS 16.0, *) {
      setNeedsUpdateOfSupportedInterfaceOrientations()
      presentingViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
      view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
        NSLog("[CameraEngine] photo viewer rotation: %@", error.localizedDescription)
      }
    }
    dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { self.onClose(deleted) }
  }

  @objc private func share() {
    let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
    activity.popoverPresentationController?.sourceView = bottom
    present(activity, animated: true)
  }

  @objc private func info() {
    // Metadata is read from this photo, never the current ring/recommended value.
    let properties = CGImageSourceCreateWithURL(file as CFURL, nil).flatMap {
      CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any]
    } ?? [:]
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    var rows: [(String, String)] = []
    if let name = facts["profileName"] as? String, !name.isEmpty { rows.append((text("相机", "Camera"), name)) }
    if let time = facts["capturedAt"] as? Double {
      let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .medium
      rows.append((text("拍摄时间", "Captured"), formatter.string(from: Date(timeIntervalSince1970: time / 1000))))
    }
    if let f = exif["FNumber"] as? Double, f > 0 { rows.append((text("实际光圈", "Aperture"), String(format: "ƒ/%.2g", f))) }
    if let mm = exif["FocalLength"] as? Double, mm > 0 { rows.append((text("镜头焦距", "Lens focal length"), String(format: "%.1f mm", mm))) }
    if let mm = exif["FocalLenIn35mmFilm"] as? Double, mm > 0 { rows.append((text("等效焦距", "35mm equivalent"), String(format: "%.0f mm", mm))) }
    if let time = exif["ExposureTime"] as? Double, time > 0 {
      rows.append((text("快门", "Shutter"), time < 1 ? String(format: "1/%.0f s", 1 / time) : String(format: "%.2g s", time)))
    }
    if let iso = (exif["ISOSpeedRatings"] as? [NSNumber])?.first { rows.append(("ISO", iso.stringValue)) }
    if let w = properties[kCGImagePropertyPixelWidth as String] as? Int, let h = properties[kCGImagePropertyPixelHeight as String] as? Int {
      let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
      rows.append((text("分辨率", "Resolution"), orientation >= 5 ? "\(h) × \(w)" : "\(w) × \(h)"))
    }
    let content = UIViewController()
    content.title = text("照片信息", "Photo info")
    content.view.backgroundColor = .systemBackground
    let list = UIScrollView()
    let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 18
    list.addSubview(stack); content.view.addSubview(list)
    list.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
      list.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
      list.leadingAnchor.constraint(equalTo: content.view.leadingAnchor), list.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: list.contentLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: list.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: list.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: list.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: list.frameLayoutGuide.widthAnchor, constant: -48),
    ])
    for (label, value) in rows {
      let line = UILabel(); line.numberOfLines = 0
      line.font = .preferredFont(forTextStyle: .body); line.adjustsFontForContentSizeCategory = true
      line.text = "\(label)  ·  \(value)"; stack.addArrangedSubview(line)
    }
    let nav = UINavigationController(rootViewController: content)
    content.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(closeInfo))
    nav.modalPresentationStyle = .pageSheet
    nav.sheetPresentationController?.detents = [.medium(), .large()]
    nav.sheetPresentationController?.prefersGrabberVisible = true
    present(nav, animated: true)
  }
  @objc private func closeInfo() { presentedViewController?.dismiss(animated: true) }

  @objc private func more() {
    let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    menu.addAction(UIAlertAction(title: text("删除照片…", "Delete photo…"), style: .destructive) { _ in self.confirmDelete() })
    menu.addAction(UIAlertAction(title: text("照片状态", "Photo status"), style: .default) { _ in
      CameraPhotoStore.shared.showRecovery {}
    })
    menu.addAction(UIAlertAction(title: text("取消", "Cancel"), style: .cancel))
    menu.popoverPresentationController?.sourceView = bottom
    present(menu, animated: true)
  }
  private func confirmDelete() {
    let confirm = UIAlertController(title: text("删除这张照片？", "Delete this photo?"),
      message: text("将删除系统相册中的这张照片及 App 预览。已单独保留的本地原图可在照片状态中管理。",
        "Deletes this photo from Photos and its app preview. Separately retained originals can be managed in Photo status."), preferredStyle: .alert)
    confirm.addAction(UIAlertAction(title: text("取消", "Cancel"), style: .cancel))
    confirm.addAction(UIAlertAction(title: text("删除照片", "Delete photo"), style: .destructive) { _ in
      self.deleting = true
      self.view.isUserInteractionEnabled = false
      self.removePhoto { error in
        self.deleting = false
        self.view.isUserInteractionEnabled = true
        if let error {
          let alert = UIAlertController(title: self.text("未能删除照片", "Couldn't delete photo"), message: error, preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: self.text("关闭", "Close"), style: .cancel))
          alert.addAction(UIAlertAction(title: self.text("系统设置", "Settings"), style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          })
          self.present(alert, animated: true)
        } else { self.finish(deleted: true) }
      }
    })
    present(confirm, animated: true)
  }
}
