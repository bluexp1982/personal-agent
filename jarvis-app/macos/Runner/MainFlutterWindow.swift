import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 与 Flutter 通信的窗口通道。拖动、全屏查询/切换都走它。
  ///
  /// 提到属性上而不是留在 `awakeFromNib` 的局部变量里：进出全屏的通知也要
  /// 用它回传 `fullScreenChanged`，局部变量出了作用域就拿不到了。
  private var windowChannel: FlutterMethodChannel?

  /// 右栏此刻是否停在一个可缩放的浏览器页上（由 Flutter 侧推送）。
  ///
  /// 只在为真时拦截 Cmd + `=` / `-` / `0`：没有浏览器页时这些组合键必须
  /// 原样放行，不能被一个用不上的快捷键无声吃掉。
  private(set) var browserZoomContextActive = false

  /// 把一次缩放命令交给 Flutter。
  ///
  /// 原生只识别"按了什么"，改哪个标签、改到哪一档都由 Dart 决定：
  /// 工具条按钮与快捷键共用同一条出口。
  func sendBrowserZoom(_ action: String) {
    windowChannel?.invokeMethod("browserZoom", arguments: ["action": action])
  }

  /// 正处在进出全屏的系统过渡动画里。
  ///
  /// macOS 在过渡期间会忽略第二次 `toggleFullScreen`：用户"进了全屏马上按 Esc"
  /// 时，那次退出会石沉大海。用这个标记把目标状态记下来，等 `didEnter/didExit`
  /// 之后再补执行一次。
  private var isTransitioningFullScreen = false

  /// 过渡期间收到的"最终应该停在哪个状态"，`nil` 表示没有待补的操作。
  private var pendingFullScreenTarget: Bool?

  /// 全屏中点了关闭：等退出全屏的动画播完再隐藏。
  ///
  /// `toggleFullScreen` 是异步动画，在全屏空间里直接 `orderOut` 会留下一块
  /// 黑屏、而且窗口仍挂在那个空间上。所以关窗时只记意图，真正的隐藏放在
  /// `handleFullScreenChange` 的"已退出全屏"分支里执行。
  private var pendingHideAfterExitFullScreen = false

  /// 最近一次指针按下是否落在"标题栏空白拖动区"。
  ///
  /// Flutter 侧每按下一次都通过 `titleBarClick` 通道回报：空白区会先调
  /// `startDragging`，而栏头按钮（后退 / 前进 / 模式下拉 / 标签）不会。
  /// 双击缩放只在两次点击都落在空白区时生效，否则在后退按钮上连点两下
  /// 就会被当成"双击标题栏"，窗口跟着缩放。
  private var lastTitleBarClickStartedDrag = false

  /// 当前窗口是否处于系统全屏。
  ///
  /// 用自己的名字而不是 `isFullScreen`：AppKit 对同义属性有过增补，
  /// 这里只读 `styleMask`，不跟系统属性抢名字。
  private var isWindowFullScreen: Bool {
    styleMask.contains(.fullScreen)
  }

  /// 标题栏区的高度（双击缩放只认这一条）。
  ///
  /// 不写死数值：直接问窗口自己要"内容布局区之外"的那一段。这段区域同时也是
  /// macOS 自己的窗口拖动区——换句话说，能双击缩放的带上限就是它，写死一个
  /// 数字迟早会和系统实际值对不上。
  private var titleBarBandHeight: CGFloat {
    frame.height - contentLayoutRect.height
  }

  /// Flutter 侧三栏首行的高度（`shell_layout_state.dart` 的 `kPaneHeaderHeight`）。
  ///
  /// Swift 拿不到 Dart 常量，只能在这里同步一份，两边必须一起改。红绿灯本身由
  /// 系统居中在原生标题条里（`titleBarBandHeight`，macOS 26 上是 32pt），
  /// 首行比它高出来的部分靠 `alignTrafficLights()` 把三颗按钮整体下移，
  /// 让按钮中心落在首行中线上，与 Flutter 的栏头按钮同轴。
  private static let paneHeaderHeight: CGFloat = 40

  /// 把红绿灯摆到 Flutter 首行的垂直中线上。
  ///
  /// 用"容器顶边往下 `paneHeaderHeight` / 2"做绝对定位，而不是在当前坐标上
  /// 累加位移：系统每次重排标题栏（改窗口大小、进出全屏、激活/失焦）都会把
  /// 按钮摆回原生位置，绝对定位保证重复调用既不会越挪越远，也能把系统那次
  /// 覆盖再纠正回来。
  ///
  /// 只动按钮坐标，**不碰**标题栏区高度：原生拖动带与双击缩放带仍是顶部
  /// 那一条，不会像过去加 `NSTitlebarAccessoryViewController` 那样把整条
  /// 第二行都变成可拖动区。
  private func alignTrafficLights() {
    let centerFromTop = Self.paneHeaderHeight / 2
    let types: [NSWindow.ButtonType] = [
      .closeButton, .miniaturizeButton, .zoomButton,
    ]
    for type in types {
      guard
        let button = standardWindowButton(type),
        let container = button.superview
      else { continue }
      let size = button.frame.size
      // 容器的顶边就是窗口顶边：翻转过时 y 从顶往下算，否则从底往上算。
      let centerY = container.isFlipped
        ? centerFromTop
        : container.bounds.height - centerFromTop
      button.setFrameOrigin(
        NSPoint(x: button.frame.origin.x, y: centerY - size.height / 2)
      )
    }
  }

  /// 盯住会让系统重排标题栏的时机，重排之后把红绿灯再摆回去。
  private func observeTitleBarLayout() {
    let names: [Notification.Name] = [
      NSWindow.didResizeNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ]
    for name in names {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleTitleBarLayoutChange(_:)),
        name: name,
        object: self
      )
    }
  }

  @objc private func handleTitleBarLayoutChange(_ note: Notification) {
    alignTrafficLights()
  }

  /// 跟踪系统全屏的进出，并把它同步回 Flutter。
  ///
  /// 用户可能完全绕过界面退出全屏（点绿灯、按 Ctrl+Cmd+F）：
  /// 不把这件事告诉 Dart 侧，窗口已经还原了、界面还停在满屏终端。
  private func observeFullScreen() {
    let names: [Notification.Name] = [
      NSWindow.willEnterFullScreenNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.willExitFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ]
    for name in names {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleFullScreenChange(_:)),
        name: name,
        object: self
      )
    }
  }

  @objc private func handleFullScreenChange(_ note: Notification) {
    switch note.name {
    case NSWindow.willEnterFullScreenNotification,
      NSWindow.willExitFullScreenNotification:
      isTransitioningFullScreen = true
      return
    default:
      break
    }

    // 过渡结束：先把期间积压的目标状态补上，再通知 Dart。
    isTransitioningFullScreen = false
    if let pending = pendingFullScreenTarget {
      pendingFullScreenTarget = nil
      setFullScreen(pending)
    }
    // 全屏里点了关闭：现在退出全屏的动画已经结束，可以真正收进菜单栏了。
    if pendingHideAfterExitFullScreen {
      pendingHideAfterExitFullScreen = false
      hideToTray()
    }
    alignTrafficLights()
    windowChannel?.invokeMethod(
      "fullScreenChanged",
      arguments: ["fullScreen": isWindowFullScreen]
    )
  }

  /// 进入 / 退出系统全屏。目标状态与当前一致时什么都不做。
  private func setFullScreen(_ target: Bool) {
    if isTransitioningFullScreen {
      // 动画还没结束，系统会忽略这次切换：记下来，等过渡结束再补。
      pendingFullScreenTarget = target
      return
    }
    if target == isWindowFullScreen {
      pendingFullScreenTarget = nil
      return
    }
    pendingFullScreenTarget = nil
    toggleFullScreen(nil)
  }

  // MARK: - 收进菜单栏 / 从菜单栏唤回

  /// 把窗口收进菜单栏：窗口消失，进程与 Flutter 引擎继续跑。
  ///
  /// 三个入口共用这一条路径：红叉（`performClose`）、Cmd+W（同上）、
  /// 黄灯最小化（`performMiniaturize`）、Cmd+M、以及"全屏中点了关闭"
  /// （等退出全屏后由 `handleFullScreenChange` 回调进来）。
  func hideToTray() {
    // 已经在菜单栏里：重复调用没有意义，也会让全屏那条 pending 分支空转。
    guard isVisible || isMiniaturized else { return }

    if isWindowFullScreen {
      pendingHideAfterExitFullScreen = true
      // 目标状态与当前一致时 `setFullScreen` 会直接返回，所以这里必须显式
      // 传 false，而不是 `setFullScreen(!isWindowFullScreen)` 之外的取巧写法。
      setFullScreen(false)
      return
    }

    // 最小化中的窗口先还原再 `orderOut`：不清掉这个状态，下次
    // `makeKeyAndOrderFront` 拿回来的会是一颗停在 Dock 位置的小图标。
    if isMiniaturized {
      deminiaturize(nil)
    }
    orderOut(nil)
  }

  /// 从菜单栏唤回窗口，并让它拿到键盘焦点。
  ///
  /// `activate` 与 `makeKeyAndOrderFront` 必须成对：`.accessory` 策略下不
  /// 激活应用的话，窗口会显示出来但打不了字（应用不是 active，输入法、
  /// 光标都不进来）。
  func showFromTray() {
    if isMiniaturized {
      deminiaturize(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  /// 红叉与 Cmd+W。
  ///
  /// 不覆写的话，`performClose` 会走 `close()`：窗口被释放/隐藏，而
  /// AppDelegate 的 `applicationShouldTerminateAfterLastWindowClosed` 一旦
  /// 改成 false，应用就变成"没有窗口也没有入口"的状态。
  override func performClose(_ sender: Any?) {
    hideToTray()
  }

  /// 黄灯与 Cmd+M。
  ///
  /// Dock 图标已经隐藏，`miniaturize` 之后窗口会缩进一个看不见的 Dock——
  /// 用户再也找不到它。这里把"最小化"直接翻译成"收进菜单栏"。
  override func performMiniaturize(_ sender: Any?) {
    hideToTray()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 隐藏系统标题栏：内容一直铺到窗口顶端，只留红绿灯浮在内容上。
    //
    // 只设 `titlebarAppearsTransparent` 不够：标题栏仍占一条高度、把内容顶下去，
    // 看起来依旧是一条空标题栏。必须同时加 `fullSizeContentView`，
    // Flutter 视图才会延伸到标题栏所在的那 28pt 区域。
    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    // 透明标题栏默认还会画一条分隔线，在深色界面上非常显眼。
    self.titlebarSeparatorStyle = .none

    // 窗口下限：390 × 600（逻辑像素 / pt）。
    //
    // 390 是 iPhone 13 的视口宽度，也是窄屏单列布局（< 700 断点）能完整
    // 放下项目卡片的最小值：再窄卡片右侧就会溢出。高度取 600 而不是 iPhone 13
    // 的 844——默认窗口一直是 1280 × 720，844 的下限会让"首次拖边"变成
    // "窗口突然长高"。
    //
    // 用 `contentMinSize` 而不是 `minSize`：这扇窗是 `fullSizeContentView` +
    // 透明标题栏，内容视图铺满整个窗口，它约束的正是 Flutter 视图本身。
    //
    // 同一条下限另外两端各存一份（Windows `win32_window.cpp` 的
    // `WM_GETMINMAXINFO`、Linux `my_application.cc` 的 `GDK_HINT_MIN_SIZE`），
    // 原生读不到 Dart 常量，改动时三处一起改。
    self.contentMinSize = NSSize(width: 390, height: 600)

    // 不要给标题栏加 accessory 去"垫高"它。
    //
    // 曾经在底部加过一个 6pt 的 NSTitlebarAccessoryViewController，想让红绿灯
    // 落到 34pt 栏头的中心轴上。代价是标题栏区从 32pt 一下变成 68pt
    // （`frame.height - contentLayoutRect.height` 实测 32 → 68），而这段区域
    // 整块都是 macOS 的原生拖动区：于是地址栏、左栏标题行这些"第二行"
    // 一按住就拖窗口，双击也会被系统当成标题栏双击。
    // 现在让标题栏保持系统高度（macOS 26 上是 32pt）：拖动带与双击带都只有
    // 这一条，不会蔓延到第二行。Flutter 侧首行比它高（40pt），红绿灯改由
    // 下面的 `alignTrafficLights()` 整体下移半个差值，仍然与栏头按钮同轴。
    //
    // 标题栏藏掉之后，系统不再提供可拖动的区域，
    // 窗口拖动改由 Flutter 侧发起：标题栏空白处（`WindowDragArea`）
    // 按下时通过这个通道回调到下面的 `performDrag`。
    let windowChannel = FlutterMethodChannel(
      name: "personal_agent/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.windowChannel = windowChannel
    windowChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "startDragging":
        // 必须用当前的鼠标按下事件：拖动会话由它开始，松手后就没有事件可用了。
        if let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(nil)
      case "titleBarClick":
        let arguments = call.arguments as? [String: Any]
        self.lastTitleBarClickStartedDrag =
          arguments?["startedDrag"] as? Bool ?? false
        result(nil)
      case "isFullScreen":
        result(self.isWindowFullScreen)
      case "setFullScreen":
        let arguments = call.arguments as? [String: Any]
        let target = arguments?["fullScreen"] as? Bool ?? false
        self.setFullScreen(target)
        result(nil)
      case "setBrowserZoomContext":
        let arguments = call.arguments as? [String: Any]
        self.browserZoomContextActive = arguments?["active"] as? Bool ?? false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // 双击栏头空白：macOS 的系统标题栏没了，缩放/最小化行为要自己补。
    //
    // 只处理顶部那一条栏头（见 `titleBarBandHeight`）：第二行的双击
    // （地址栏选词、工具条按钮、内容区选词）必须原样留给 Flutter。
    // 栏头里还有 Flutter 自己的按钮，坐标判断分不出来，另由
    // `lastTitleBarClickStartedDrag` 要求"两次点击都落在空白拖动区"。
    let doubleClick = NSClickGestureRecognizer(
      target: self,
      action: #selector(handleTitleBarDoubleClick(_:))
    )
    doubleClick.numberOfClicksRequired = 2
    // 不延迟主键事件：Flutter 自己的按钮、列表仍要即时收到点击。
    doubleClick.delaysPrimaryMouseButtonEvents = false
    doubleClick.delegate = self
    flutterViewController.view.addGestureRecognizer(doubleClick)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // 红绿灯由系统居中在原生标题条里（32pt），Flutter 侧首行是 40pt：
    // 把三颗按钮一起下移 4pt，中心才落在首行中线上、与栏头按钮同轴。
    alignTrafficLights()
    observeTitleBarLayout()
    observeFullScreen()
    // 首次 setFrame 之后系统还会再排一次标题栏，帧末补一次，免得第一帧被摆回原位。
    DispatchQueue.main.async { [weak self] in
      self?.alignTrafficLights()
    }
  }

  /// 按 macOS「双击窗口标题栏以」的系统偏好执行缩放 / 最小化 / 无动作。
  @objc private func handleTitleBarDoubleClick(_ sender: NSClickGestureRecognizer) {
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
      miniaturize(nil)
    case "None":
      break
    default:
      // 未设置或 "Maximize"：与系统默认一致，切换窗口缩放状态。
      zoom(nil)
    }
  }
}

extension MainFlutterWindow: NSGestureRecognizerDelegate {
  /// 只有顶部那条标题栏才认双击。
  ///
  /// 第二行往下（左栏标题行、浏览器地址栏与工具条、聊天/终端/预览内容）的
  /// 双击必须原样留给 Flutter：文本选择与双击选词都依赖它，
  /// 不能被窗口缩放手势抢走。
  func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
    // 系统全屏里没有标题栏，顶部那条带已经不存在；此时再按"缩放"处理只会
    // 把满屏终端缩小成一扇窗——全屏终端的第一行也不该成为双击缩放区。
    if isWindowFullScreen {
      return false
    }
    // 先看这一次点击落在哪儿：只有空白拖动区才认双击。
    // 这条判定必须排在坐标判断之前——栏头按钮整好落在顶部这条带里，
    // 只按坐标判断的话，连点两次后退就会顺手把窗口缩放掉。
    if !lastTitleBarClickStartedDrag {
      return false
    }
    guard let view = gestureRecognizer.view else { return false }
    let point = gestureRecognizer.location(in: view)
    let bandHeight = titleBarBandHeight
    return view.isFlipped
      ? point.y <= bandHeight
      : point.y >= view.bounds.height - bandHeight
  }
}
