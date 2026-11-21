#!/usr/bin/env python3
"""Run the production multitask container/attachment code inside real UIKit."""
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'app.zcontainer.containmentsmoke'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs).stdout.strip()


def block(source, declaration):
    start = source.index(declaration)
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise RuntimeError('Unclosed production block: ' + declaration)


def main():
    dock = (ROOT / 'MultitaskSupport/MultitaskDockView.swift').read_text()
    attachment = block(dock, 'private func attachWindowHostingView()')
    host_owner = block(dock, 'private lazy var windowHostController:') + '()'
    smoke = '''
import UIKit
import SwiftUI

// The probe supplies only window discovery and the host's view. Container
// creation, reattachment and controller ownership use the production bodies.
final class AttachmentProbe {
    let hostView = UIView()
    var keyWindow: UIWindow?
    init(window: UIWindow) { keyWindow = window }
    HOST_OWNER
    ATTACHMENT
    func attach() { attachWindowHostingView() }
    var owner: UIViewController { windowHostController }
}

@main
final class SmokeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let home = UIHostingController(rootView: Text("Home").onLongPressGesture {})
        window.rootViewController = home
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async { self.verify(window: window, home: home) }
        return true
    }

    func verify(window: UIWindow, home: UIViewController) {
        let probe = AttachmentProbe(window: window)
        probe.attach()
        guard let root = window.rootViewController as? MultitaskRootViewController else { fatalError("Missing production root") }
        root.view.layoutIfNeeded()
        precondition(root.homeController === home && home.parent === root)
        precondition(probe.owner.parent === root && root.children.count == 2)
        precondition(home.view.window === window && probe.hostView.window === window)
        precondition(!probe.hostView.isDescendant(of: home.view), "SwiftUI must not be the virtual view's gesture ancestor")
        precondition(root.childForStatusBarStyle === home && root.childForStatusBarHidden === home)
        precondition(root.childForHomeIndicatorAutoHidden === home)

        let first = UIViewController()
        let second = UIViewController()
        for guest in [first, second] {
            probe.owner.addChild(guest)
            probe.hostView.addSubview(guest.view)
            guest.didMove(toParent: probe.owner)
            precondition(guest.view.isDescendant(of: guest.parent!.view))
            precondition(guest.view.window === window)
        }
        probe.attach()
        precondition(window.rootViewController === root && root.children.count == 2)
        precondition(probe.owner.children.count == 2)
        first.willMove(toParent: nil)
        first.view.removeFromSuperview()
        first.removeFromParent()
        precondition(probe.owner.children.count == 1 && second.parent === probe.owner)
        precondition(second.view.window === window)

        let size = CGSize(width: 600, height: 420)
        root.view.frame = CGRect(origin: .zero, size: size)
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        precondition(home.view.bounds.size == size && probe.hostView.bounds.size == size)

        // A replacement root must detach the existing virtual controller from
        // its old parent before attaching it to a new container.
        let replacementHome = UIViewController()
        window.rootViewController = nil
        window.rootViewController = replacementHome
        probe.attach()
        guard let replacement = window.rootViewController as? MultitaskRootViewController else { fatalError("Missing replacement root") }
        replacement.view.layoutIfNeeded()
        precondition(replacement.homeController === replacementHome)
        precondition(probe.owner.parent === replacement && root.children.count == 1)
        precondition(second.view.isDescendant(of: probe.owner.view) && second.view.window === window)

        let report: [String: Any] = [
            "passed": true,
            "checks": ["UIKit child/view ancestry", "SwiftUI gesture isolation", "Home system-UI forwarding", "idempotent attachment", "target-only removal", "resize", "root replacement"],
            "runtime": UIDevice.current.systemVersion
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! data.write(to: documents.appendingPathComponent("containment-result.json"))
        print("CONTAINMENT_SMOKE_PASS")
        exit(0)
    }
}
'''.replace('HOST_OWNER', host_owner).replace('ATTACHMENT', attachment)
    sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    candidates = [device for runtime, group in devices.items() if '.iOS-' in runtime
                  for device in group if 'iPhone' in device['name']]
    if not candidates:
        raise RuntimeError('No available iOS Simulator: UIKit containment proof cannot run')
    device = next((item for item in candidates if item['state'] == 'Booted'), candidates[0])
    udid = device['udid']
    booted_here = device['state'] != 'Booted'
    try:
        if booted_here:
            run('xcrun', 'simctl', 'boot', udid)
        run('xcrun', 'simctl', 'bootstatus', udid, '-b', timeout=180)
        with tempfile.TemporaryDirectory(prefix='zcontainer-containment-') as directory:
            work = Path(directory)
            source = work / 'Smoke.swift'
            source.write_text(smoke)
            app = work / 'ContainmentSmoke.app'
            app.mkdir()
            info = {'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': 'ContainmentSmoke',
                    'CFBundleName': 'ContainmentSmoke', 'CFBundlePackageType': 'APPL',
                    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
                    'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1],
                    'UILaunchScreen': {}, 'MinimumOSVersion': '18.0'}
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
            run('xcrun', 'swiftc', '-parse-as-library', '-sdk', sdk,
                '-target', arch + '-apple-ios18.0-simulator',
                str(ROOT / 'LiveContainerSwiftUI/Home/Routing/MainWindow.swift'),
                str(source), '-o', str(app / 'ContainmentSmoke'), timeout=120)
            run('codesign', '--force', '--sign', '-', str(app))
            run('xcrun', 'simctl', 'install', udid, str(app))
            print(run('xcrun', 'simctl', 'launch', '--console', udid, BUNDLE_ID, timeout=90))
            container = Path(run('xcrun', 'simctl', 'get_app_container', udid, BUNDLE_ID, 'data'))
            result = json.loads((container / 'Documents/containment-result.json').read_text())
            if result.get('passed') is not True:
                raise RuntimeError('UIKit containment smoke did not pass: ' + str(result))
            print(json.dumps(result, ensure_ascii=False))
    finally:
        subprocess.run(['xcrun', 'simctl', 'uninstall', udid, BUNDLE_ID], capture_output=True)
        if booted_here:
            subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)


if __name__ == '__main__':
    main()
