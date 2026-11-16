import Cocoa
import FlutterMacOS
import os

/// 应用级外壳：菜单栏常驻、单实例、退出路径。
///
/// 这个客户端在这里从"普通窗口应用"变成"菜单栏应用"：Dock 里不再有图标，
/// 关窗不退出进程，唯一入口是屏幕右上角那颗状态栏图标。窗口本身的隐显逻辑
/// 在 `MainFlutterWindow`（`hideToTray` / `showFromTray`），这里只负责
/// 什么时候调它们、以及"怎么真正退出"。
///
/// 为什么用运行时 `setActivationPolicy(.accessory)` 而不是 `Info.plist` 的
/// `LSUIElement`：策略可运行时切换（调试、将来"是否常驻"的开关都留给
/// 自己），且不必改工程配置。放在 `applicationWillFinishLaunching` 里设，
/// 是为了让 Dock 图标一次都不出现——等到 `didFinishLaunching` 再设，
/// 启动瞬间会闪一下。
@main
class AppDelegate: FlutterAppDelegate {
  /// 菜单栏图标。`NSStatusBar.system` 持有它，这里只是引用。
  private var statusItem: NSStatusItem?

  /// Cmd+Q / Cmd+W / Cmd+M 的本地按键监听句柄（`removeMonitor` 要用）。
  private var keyMonitor: Any?

  /// 右键菜单是否正开着。`performClick` 会阻塞到菜单收起，期间的重入要挡掉。
  private var isStatusMenuVisible = false

  /// 第二个实例唤回第一个实例用的分布式通知名。
  ///
  /// 单实例不能靠"检测到就激活"：`.accessory` 策略下 `activate` 不会把
  /// 一个 `orderOut` 掉的窗口叫回来。必须让已运行的进程自己去显示，
  /// 所以第二个实例只投一条通知然后退出。
  private static let showWindowNotification = Notification.Name(
    "personal_agent.showMainWindow"
  )

  /// 统一日志句柄。
  ///
  /// 用 `os.Logger` 而不是 `NSLog`：这个应用的 `NSLog` 输出在这台机器上
  /// 既不进统一日志、也不落到 stderr（实测 `log stream` 一条都抓不到），
  /// 出问题时等于零线索。`Logger` 带 subsystem，`log show` 能直接按
  /// `subsystem == "com.personalagent.jarvis"` 过滤；插值默认是私有的，
  /// 需要看的值一律标 `privacy: .public`。
  private let log = Logger(subsystem: "com.personalagent.jarvis", category: "shell")

  /// 「隐藏 Dock 图标」偏好的存储键。
  ///
  /// 带 `personalAgent.` 前缀，避免与 Flutter 插件写进同一个 domain 的键撞名。
  private static let hideDockIconKey = "personalAgent.hideDockIcon"

  /// 是否隐藏 Dock 图标（= 纯菜单栏形态）。
  ///
  /// **默认 `true`**，且必须用 `object(forKey:)` 判断"有没有设置过"：
  /// `bool(forKey:)` 会把"从没写过"读成 false，老用户升级后 Dock 图标会
  /// 毫无征兆地冒出来，而他们此前的行为是"只有菜单栏"。
  private var hidesDockIcon: Bool {
    get {
      UserDefaults.standard.object(forKey: Self.hideDockIconKey) as? Bool ?? true
    }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.hideDockIconKey)
    }
  }

  /// 把偏好落到 `NSApplication` 上：accessory = 无 Dock 图标，regular = 普通应用。
  ///
  /// 返回 `Bool` 是 AppKit 的约定（切换失败会返回 false），失败必须留日志：
  /// 静默失败的表现是"勾了但 Dock 图标没变"，而用户没有任何可查的线索。
  @discardableResult
  private func applyActivationPolicy() -> Bool {
    let hide = hidesDockIcon
    let applied = NSApp.setActivationPolicy(hide ? .accessory : .regular)
    if applied {
      log.notice("activationPolicy=\(hide ? "accessory" : "regular", privacy: .public)")
    } else {
      log.error("activationPolicy 切换失败 target=\(hide ? "accessory" : "regular", privacy: .public)")
    }
    return applied
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)

    // 形态由偏好决定：默认隐藏（纯菜单栏），用户可在右键菜单里勾掉以显示 Dock。
    applyActivationPolicy()

    // 单实例必须在建窗口之前判：晚一步就已经多了一扇窗、一个引擎。
    terminateIfAnotherInstanceIsRunning()

    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleShowFromOtherInstance(_:)),
      name: Self.showWindowNotification,
      object: nil
    )

    // 生命周期各留一条日志：状态栏项不显示时，第一步就是确认这两个回调
    // 有没有走到我们的实例。
    log.notice(
      "willFinishLaunching：hideDockIcon=\(self.hidesDockIcon, privacy: .public)"
    )
  }

  /// 这里**不能**调 `super`。
  ///
  /// `FlutterAppDelegate`（macOS 版）只是通过 `<NSApplicationDelegate>` 的
  /// 可选方法"声明"了这族回调——所以 Swift 允许 `override`——但它并没有
  /// 实现 `applicationDidFinishLaunching:`。一调 `super` 就是
  /// `unrecognized selector sent to instance`，`NSApplication` 吞掉异常并
  /// 中断整个方法体：建状态栏项、装快捷键监听统统不执行，表现是"菜单栏上
  /// 什么都没有"，不崩、不报错、也没有任何日志。
  ///
  /// `applicationWillFinishLaunching:` 是真实现了的（那边可以调 `super`）。
  override func applicationDidFinishLaunching(_ notification: Notification) {
    log.notice("didFinishLaunching")
    setUpStatusItem()
    installKeyMonitor()
  }

  /// 同样不能调 `super`：`applicationWillTerminate:` 也是只有声明没有实现。
  override func applicationWillTerminate(_ notification: Notification) {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    DistributedNotificationCenter.default().removeObserver(self)
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
  }

  /// 关掉最后一扇窗不等于退出。
  ///
  /// 这是"点红叉就退出"的唯一开关：改回 `true` 会让常驻形态失效，而且因为
  /// Dock 图标已经隐藏，退掉之后没有任何入口能把它叫回来。
  override func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    return false
  }

  /// 从 Finder / Spotlight / Launchpad 再次打开时唤回窗口。
  ///
  /// 正常情况会先被 `terminateIfAnotherInstanceIsRunning` 拦下（第二个进程
  /// 退出、通知第一个进程）；这里兜住"系统把 reopen 事件发给同一个进程"
  /// 的情况（例如没有 Dock 图标时的 `open -a`）。
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    mainWindow?.showFromTray()
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // MARK: - 菜单栏图标

  private func setUpStatusItem() {
    // 显式给一个正数长度，不用 `squareLength` 让 AppKit 自己推算：
    // 内容为空时（取图失败）它会算出 0 宽，状态栏项等于不存在，而这件事
    // 不报错、不打日志，只能靠肉眼发现"图标没了"。
    let sideLength: CGFloat = 24
    let item = NSStatusBar.system.statusItem(withLength: sideLength)

    // 图标被拖走就等于"没有任何入口能唤回窗口"：让系统直接终止进程，
    // 至少不会留下一个看不见、也关不掉的僵尸应用。
    item.behavior = .terminationOnRemoval

    guard let button = item.button else {
      // 没拿到按钮（理论上只有自绘视图的项才会这样）：至少要留下日志，
      // 否则这类失败在外部完全不可见。
      log.error("状态栏项没有 button，图标无法显示")
      statusItem = item
      return
    }

    // 取图顺序：assets 里的品牌图 → 系统符号 → 文字。
    //
    // 最后一级是刻意的：菜单栏图标一旦没有内容，整块宽度会塌掉；而它是
    // 隐藏窗口之后唯一的入口，宁可显示一个不好看的字符，也不能什么都看不到。
    let assetImage = NSImage(named: NSImage.Name("MenuBarIcon"))
    var image = assetImage
    if image == nil {
      // 走到这里通常意味着资源没进 `Assets.car`，或者 imageset 的 idiom
      // 写错了（macOS 只认 `mac`，写成 iOS 的 `universal` 时 actool 照样
      // 编过、`NSImage(named:)` 却返回 nil）。
      log.error("未取到 MenuBarIcon，退回系统符号")
      image = NSImage(
        systemSymbolName: "sparkles",
        accessibilityDescription: "Jarvis"
      )
    }

    if let image {
      // 模板图：AppKit 只读 alpha，深色菜单栏自动反白。assets 的
      // `template-rendering-intent` 已经声明过一次，这里再置一遍是兜底——
      // 万一意图字段没生效，得到的会是一张灰扑扑的彩色图。
      image.isTemplate = true
      image.size = NSSize(width: 18, height: 18)
      button.image = image
      button.imagePosition = .imageOnly
      // 模板图在非整数缩放（外接 1.5× 屏）下按比例缩，避免取最近的整数像素。
      button.imageScaling = .scaleProportionallyDown
    } else {
      log.error("系统符号也不可用，状态栏项退化为文字")
      button.title = "J"
    }

    button.toolTip = "Jarvis"
    button.setAccessibilityLabel("Jarvis")

    // 左键与右键要分流，所以不能在 `statusItem.menu` 上挂菜单：
    // 一挂上去，左键也会弹菜单，"左键切换显隐"就没法做了。
    button.target = self
    button.action = #selector(handleStatusItemClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])

    statusItem = item
    log.notice(
      """
      状态栏项已创建 source=\(assetImage == nil ? "fallback" : "asset", privacy: .public) \
      size=\(NSStringFromSize(button.image?.size ?? .zero), privacy: .public) \
      visible=\(item.isVisible, privacy: .public)
      """
    )
  }

  @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    // 触控板两指点击等价于右键（`NSApp.currentEvent` 报的仍是 leftMouseUp，
    // 但带 control 修饰键）。
    let isSecondary =
      event.type == .rightMouseUp || event.modifierFlags.contains(.control)
    if isSecondary {
      // 排到下一轮主循环再弹，不能在这里同步 `performClick`。
      //
      // 同步弹的话，同一次鼠标点击的事件还没派发完，菜单起来之后那半个
      // mouseUp 可能被菜单当成"点了光标下的条目"——实测表现为右键几次，
      // 「隐藏 Dock 图标」被悄悄翻转（勾选态与实际形态一起变）。
      DispatchQueue.main.async { [weak self] in
        self?.showStatusMenu()
      }
    } else {
      toggleMainWindow()
    }
  }

  /// 右键菜单：显示主窗口 / 隐藏 Dock 图标（勾选）/ 退出。
  ///
  /// 用"临时挂上菜单再 `performClick`"的写法而不是 `popUpMenu(_:)`：
  /// 后者在 10.14 起已废弃，前者是现在的标准做法，而且菜单是同步弹出的，
  /// `performClick` 返回时菜单已经收起，紧接着把 `menu` 摘掉即可。
  private func showStatusMenu() {
    guard let statusItem, let button = statusItem.button else { return }
    // `performClick` 会阻塞在整个菜单追踪里，期间再来一次右键就会叠出第二个
    // 菜单（第二个还会立刻抢占事件）。用一个标记挡住重入。
    guard !isStatusMenuVisible else { return }
    isStatusMenuVisible = true
    defer { isStatusMenuVisible = false }

    let menu = NSMenu()
    // 关掉自动校验：这一项没有走 responder chain 的校验器，AppKit 的自动
    // 启用逻辑会把它当成"没人能处理"而变灰——看起来像功能坏了。
    menu.autoenablesItems = false

    let show = NSMenuItem(
      title: "显示主窗口",
      action: #selector(showMainWindowFromMenu),
      keyEquivalent: ""
    )
    show.target = self
    menu.addItem(show)

    menu.addItem(.separator())

    // 勾选态交给系统菜单自己画（条目左侧的 ✓），不额外画图标。
    // 每次弹菜单都按当前偏好现设一次，不需要维护"菜单打开了再改状态"的路子。
    let hideDock = NSMenuItem(
      title: "隐藏 Dock 图标",
      action: #selector(toggleHideDockIcon),
      keyEquivalent: ""
    )
    hideDock.target = self
    hideDock.state = hidesDockIcon ? .on : .off
    menu.addItem(hideDock)

    menu.addItem(.separator())

    // Cmd+Q 写在菜单上：菜单弹出期间按下它，走的就是这一项。
    let quit = NSMenuItem(
      title: "退出 Jarvis",
      action: #selector(quitApplication),
      keyEquivalent: "q"
    )
    quit.keyEquivalentModifierMask = .command
    quit.target = self
    menu.addItem(quit)

    statusItem.menu = menu
    button.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func showMainWindowFromMenu() {
    mainWindow?.showFromTray()
  }

  /// 切换「隐藏 Dock 图标」。
  ///
  /// 两端的收尾动作都是必要的：
  /// - 切到 accessory 后 Dock 图标消失，应用若正前台要重新 `activate`，
  ///   否则窗口还在、却不是 active 应用，输入法与光标进不来；
  /// - 切到 regular 后 Dock 图标出现，但窗口可能正藏在托盘里。只多一个图标
  ///   而不唤回窗口，用户会以为"勾了没反应"。
  @objc private func toggleHideDockIcon() {
    hidesDockIcon.toggle()

    guard applyActivationPolicy() else {
      // 系统拒绝切换：把偏好翻回去，别让菜单里的勾和实际形态对不上。
      hidesDockIcon.toggle()
      return
    }

    if hidesDockIcon {
      NSApp.activate(ignoringOtherApps: true)
    } else {
      mainWindow?.showFromTray()
    }
  }

  // MARK: - 显示 / 隐藏

  private var mainWindow: MainFlutterWindow? {
    NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first
  }

  /// 左键单击：窗口已经在最前就藏起来，否则叫回来。
  ///
  /// 判据用 `isKeyWindow` 而不是 `isVisible`：窗口被别的应用盖住时它仍然
  /// `isVisible`，那时用户点图标的意图是"把窗口拿到前面"，不是"再隐藏一次"。
  private func toggleMainWindow() {
    guard let window = mainWindow else { return }
    if window.isVisible && !window.isMiniaturized && window.isKeyWindow {
      window.hideToTray()
    } else {
      window.showFromTray()
    }
  }

  // MARK: - 键盘

  /// 菜单栏应用没有可见的主菜单，`MainMenu.xib` 里的 key equivalent 不保证
  /// 被派发（`.accessory` 不接管菜单栏）。这三颗键又必须确定可用，所以在
  /// 本地监听里直接处理：
  ///
  /// - Cmd+Q 退出：没有它就只能靠右键菜单，Dock 已经没了。
  /// - Cmd+W 隐藏：与红叉同一语义。
  /// - Cmd+M 隐藏：Dock 已隐藏，`miniaturize` 之后窗口没有可找回的入口，
  ///   等于把窗口弄丢。这里把"最小化"直接翻译成"收进菜单栏"。
  private func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

      // 浏览器缩放先认：右栏是内嵌 WebView，页面拿到键盘焦点时
      // Cmd + `=` / `-` / `0` 根本到不了 Flutter，只在这一层接得住。
      // 只有 Flutter 明确说过"现在停在一个浏览器页上"时才吞键。
      if let window = self.mainWindow, window.browserZoomContextActive,
        let action = Self.browserZoomAction(for: event, flags: flags)
      {
        window.sendBrowserZoom(action)
        return nil
      }

      // 只认纯粹的 Command 组合：带 Option/Shift/Control 的交给界面自己。
      guard flags == .command else { return event }

      switch event.charactersIgnoringModifiers?.lowercased() {
      case "q":
        self.quitApplication()
        return nil
      case "w", "m":
        // 只对主窗口生效：对话框、浮层里的 Cmd+W 不该把整窗收走。
        guard let window = self.mainWindow, NSApp.keyWindow === window else {
          return event
        }
        window.hideToTray()
        return nil
      default:
        return event
      }
    }
  }

  /// Cmd + `=` / `+` / `-` / `0` 到缩放命令的映射。
  ///
  /// `charactersIgnoringModifiers` 保留 Shift（放大通常按的是 `Shift + =`，
  /// 字符是 `+`），所以两档都要认；小键盘的加减号同理。`0` 只在纯 Command
  /// 下算重置，避免和"切换窗口"之类的 Shift 组合撞上。
  private static func browserZoomAction(
    for event: NSEvent,
    flags: NSEvent.ModifierFlags
  ) -> String? {
    let commandOnly = flags == .command
    let commandShift = flags == [.command, .shift]
    switch event.charactersIgnoringModifiers {
    case "=", "+":
      guard commandOnly || commandShift else { return nil }
      return "in"
    case "-", "_":
      guard commandOnly || commandShift else { return nil }
      return "out"
    case "0":
      guard commandOnly else { return nil }
      return "reset"
    default:
      return nil
    }
  }

  // MARK: - 退出

  @objc private func quitApplication() {
    // 走 `terminate` 而不是 `exit(0)`：让 Flutter 引擎与插件按正常顺序析构，
    // 录音、SSH、本地静态服务才有机会关干净。
    NSApp.terminate(nil)
  }

  // MARK: - 单实例

  /// 已经有同名进程在跑时，通知它显示窗口，然后自己退出。
  ///
  /// 隐藏 Dock 之后，"再点一次应用图标"是很自然的动作（Launchpad、Spotlight、
  /// Finder 都是），每次都会起一个新进程。这里在窗口与引擎创建之前就拦掉。
  private func terminateIfAnotherInstanceIsRunning() {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let others = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleIdentifier)
      .filter { $0 != .current }
    guard !others.isEmpty else { return }

    DistributedNotificationCenter.default().postNotificationName(
      Self.showWindowNotification,
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
    // 通知由 distnoted 异步投递，立刻退出有概率丢掉这条消息（那就变成
    // "两个实例都退出了"）。停 150ms 让投递落地的代价可以忽略。
    Thread.sleep(forTimeInterval: 0.15)
    NSApp.terminate(nil)
  }

  @objc private func handleShowFromOtherInstance(_ note: Notification) {
    // 通知可能来自别的线程组，窗口操作必须回主线程。
    DispatchQueue.main.async { [weak self] in
      self?.mainWindow?.showFromTray()
    }
  }
}
