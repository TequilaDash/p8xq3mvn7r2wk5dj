//
//  MultitaskStackView.swift
//  LiveContainer
//
//  图五: 原生 springboard 风格的**堆叠后台界面**.
//  双击辅助触控进入 -> 看到所有在跑的多任务窗口(卡片堆叠, 后一个压前一个),
//  点卡片进入该 app 的多任务窗口, 卡片上滑删除该窗口(结束访客进程).
//  设计:
//   · 数据源复用 MultitaskDockManager.runningApps(与 Dock 同一份, 不重复维护)
//   · 卡片按 z 序叠放, 后加入的在最上面, 整体可左右拖动切换
//   · 点卡片 -> bringMultitaskViewToFront(uuid:) 把对应窗口带到前台
//   · 上滑超过阈值 -> 关闭该窗口(DecoratedAppSceneViewController.closeWindow)
//

import Foundation
import SwiftUI
import UIKit
import Combine

@available(iOS 16.0, *)
@objcMembers
public class MultitaskStackManager: NSObject, ObservableObject {
    @Published public var isVisible: Bool = false
    @Published public var selectedIndex: Int = 0

    private weak var hostingController: UIHostingController<AnyView>?
    private var dismissWorkItem: DispatchWorkItem?

    public static let shared = MultitaskStackManager()

    /// 打开堆叠界面. 由宿主在双击辅助触控时调用.
    @objc public func present() {
        DispatchQueue.main.async {
            if self.isVisible {
                self.dismiss()
                return
            }
            self.isVisible = true
            if self.hostingController == nil {
                // dock 也必须注入: 视图里用 @EnvironmentObject 取运行中的窗口列表.
                let view = AnyView(MultitaskStackView()
                    .environmentObject(self)
                    .environmentObject(MultitaskDockManager.shared))
                let host = UIHostingController(rootView: view)
                host.view.backgroundColor = .clear
                host.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
                self.hostingController = host
            }
            guard let host = self.hostingController else { return }
            // 挂到**宿主自己的窗口**上: 访客窗口由 LiveProcess 扩展进程渲染,
            // 宿主进程里没有那些窗口; 宿主窗口在前台 scene 里, 层级足够高.
            // 一个 view 只能有一个父窗口, 所以只挑一个来挂.
            var target: UIWindow?
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                      windowScene.activationState == .foregroundActive else { continue }
                for window in windowScene.windows where !window.isHidden {
                    if target == nil || window.isKeyWindow {
                        target = window
                    }
                    if window.isKeyWindow { break }
                }
                if target?.isKeyWindow == true { break }
            }
            if target == nil { target = self.keyWindow() }
            guard let window = target else { return }
            host.view.frame = window.bounds
            if host.view.superview !== window {
                host.view.removeFromSuperview()
                window.addSubview(host.view)
            }
            window.bringSubviewToFront(host.view)
        }
    }

    @objc public func dismiss() {
        DispatchQueue.main.async {
            self.isVisible = false
            self.hostingController?.view.removeFromSuperview()
        }
    }

    /// 点击卡片: 把对应窗口带到前台并关闭堆叠界面.
    /// 先把其它窗口收起来(iOS 堆叠界面的行为: 只会留下被点开的那个),
    /// 否则目标窗口会被别的窗口盖住, 看起来像"点了没反应".
    @objc public func selectApp(uuid: String) {
        DispatchQueue.main.async {
            let dock = MultitaskDockManager.shared
            var target: DecoratedAppSceneViewController?
            for app in dock.apps where app.appUUID == uuid {
                target = app.view?._viewDelegate() as? DecoratedAppSceneViewController
                break
            }
            dock.minimizeAllWindows(except: target)
            // 等其它窗口收起再带目标上前, 否则动画会互相打架.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                _ = dock.bringMultitaskViewToFront(uuid: uuid, from: nil)
                self.dismiss()
            }
        }
    }

    /// 上滑删除: 结束该访客窗口(与 Dock 上的关闭按钮同一路径).
    @objc public func closeApp(uuid: String) {
        DispatchQueue.main.async {
            let dock = MultitaskDockManager.shared
            for app in dock.apps where app.appUUID == uuid {
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                    vc.closeWindow()
                }
            }
            dock.removeRunningApp(uuid)
        }
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first
    }
}

@available(iOS 16.0, *)
struct MultitaskStackView: View {
    @EnvironmentObject var manager: MultitaskStackManager
    @EnvironmentObject var dock: MultitaskDockManager

    var body: some View {
        ZStack {
            // 背景遮罩: 点空白关闭
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { manager.dismiss() }

            if dock.apps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("没有正在运行的多任务窗口")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else {
                GeometryReader { geo in
                    let count = dock.apps.count
                    ZStack {
                        ForEach(Array(dock.apps.enumerated()), id: \.offset) { index, app in
                            card(for: app, index: index, count: count, size: geo.size)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: dock.apps.count)
    }

    @ViewBuilder
    private func card(for app: DockAppModel, index: Int, count: Int, size: CGSize) -> some View {
        // 越靠后的卡片越"上"一层(像 springboard 的堆叠)
        let depth = CGFloat(count - 1 - index)
        let cardWidth = size.width * 0.62
        let cardHeight = size.height * 0.62
        let offset = depth * 14
        let scale = 1.0 - depth * 0.04

        AppStackCard(app: app,
                     size: CGSize(width: cardWidth, height: cardHeight),
                     onSelect: { manager.selectApp(uuid: app.appUUID) },
                     onClose: { manager.closeApp(uuid: app.appUUID) })
            .scaleEffect(scale)
            .offset(y: -offset)
            .zIndex(Double(index))
            .allowsHitTesting(index == count - 1 || abs(index - manager.selectedIndex) <= 1)
    }
}

/// 单张卡片: 图标 + 名称, 支持上滑删除与点击进入.
@available(iOS 16.0, *)
struct AppStackCard: View {
    let app: DockAppModel
    let size: CGSize
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var icon: UIImage?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(10)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.gray.opacity(0.35))
                        .padding(10)
                        .overlay(ProgressView().tint(.white))
                }
            }
            .frame(width: size.width * 0.55, height: size.width * 0.55)

            Text(app.appName)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .offset(dragOffset)
        .rotationEffect(.degrees(Double(dragOffset.height / 40)))
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    // 上滑超过阈值 -> 删除; 否则弹回
                    if value.translation.height < -110 {
                        onClose()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = .zero
                    }
                }
        )
        .onTapGesture { onSelect() }
        .onAppear { loadIcon() }
    }

    private func loadIcon() {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: UIImage?
            if let info = app.appInfo {
                result = info.iconIsDarkIcon(false)
            } else if let found = AppInfoProvider.shared.findAppInfo(appName: app.appName, dataUUID: app.appUUID) {
                result = found.iconIsDarkIcon(false)
            }
            DispatchQueue.main.async { icon = result }
        }
    }
}
