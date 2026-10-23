//
//  InjectorV3+TrollStoreLite.swift
//  TrollFools
//
//  TrollStore Lite / 巨魔R（Relaxin / RootHide 兼容版）后端兼容层。
//
//  背景：TrollFools 原版注入器直接修改目标 App 的 Mach-O，插入
//  @rpath/Frameworks/CydiaSubstrate.framework 与插件 dylib 并重新签名。
//  在 iOS 17+（尤其 RootHide / ElleKit 环境）下，直接改签的二进制会
//  触发 AMFI / CoreTrust 校验失败，注入后的应用启动即闪退。
//
//  TrollStore Lite（com.opa334.trollstorelite，含“巨魔R”变体）内置注入：
//  trollstorehelper 提供 inject-dylib / inject-deb / remove-injected-dylibs
//  / set-injected-dylib-enabled / eject-injected-dylib 子命令，对加密
//  App Store 应用走 ElleKit 运行时注入（不改原签名），对解密/巨魔应用走
//  tsinsertdylib 轻量 Mach-O 注入，由宿主环境正确加载，不会闪退。
//
//  本扩展把 InjectorV3 的注入/卸载/查询桥接到该 helper，使 TrollFools
//  在 TrollStore Lite（iOS 17+）上使用与巨魔R 一致的后端。

import CocoaLumberjackSwift
import Foundation

// MARK: - 清单模型

struct TrollStoreLiteInjectionEntry {
    let path: String
    let enabled: Bool
    let injectionTool: String?
}

// MARK: - 后端

final class TrollStoreLiteBackend {
    static let appIdentifier = "com.opa334.trollstorelite"

    static let helperName = "trollstorehelper"
    static let injectionToolName = "tsinsertdylib"

    /// 巨魔R 注入元数据目录（相对用户主目录）。
    static let gmliteRootRelative = "Library/GMLiteInjection"
    static let manifestFileName = "InjectedDylibs.plist"
    static let markerFileName = ".GMLiteInjection"

    /// 是否处于 TrollStore Lite / 巨魔R 环境：helper 与其配
    /// 套的 tsinsertdylib 必须同时存在（原版 TrollStore 的 helper
    /// 不支持 inject-* 子命令，且不带 tsinsertdylib）。
    static var isAvailable: Bool {
        guard let helper = resolveHelperURL() else { return false }
        // 同 bundle 内必须存在 tsinsertdylib（巨魔R 的标志性工具）。
        let tool = helper.deletingLastPathComponent()
            .appendingPathComponent(injectionToolName)
        if FileManager.default.isExecutableFile(atPath: tool.path) {
            return true
        }
        // 或已存在巨魔R 注入元数据目录。
        return manifestURL() != nil
    }

    // MARK: - 路径

    static func candidateHelperURLs() -> [URL] {
        var urls: [URL] = []

        if let bundled = Bundle.main.url(forResource: helperName, withExtension: nil) {
            urls.append(bundled)
        }

        if let proxy = LSApplicationProxy(forIdentifier: appIdentifier),
           let bundleURL = proxy.bundleURL()
        {
            urls.append(bundleURL.appendingPathComponent(helperName))
        }

        let knownPaths = [
            "/var/jb/Applications/TrollStoreLite.app/trollstorehelper",
            "/Applications/TrollStoreLite.app/trollstorehelper",
            "/var/jb/Applications/TrollStoreLite.app/tsinsertdylib",
            "/Applications/TrollStoreLite.app/tsinsertdylib",
        ]
        urls.append(contentsOf: knownPaths.map { URL(fileURLWithPath: $0) })

        return urls
    }

    static func resolveHelperURL() -> URL? {
        for url in candidateHelperURLs() {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func helperURLForBundle(_ bundleURL: URL) -> URL? {
        let direct = bundleURL.appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: direct.path) {
            return direct
        }
        let sibling = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("TrollStoreLite.app")
            .appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return resolveHelperURL()
    }

    // MARK: - 清单

    /// 巨魔R：/var/mobile/Library/GMLiteInjection/InjectedDylibs.plist
    static func manifestURL() -> URL? {
        URL(fileURLWithPath: "/var/mobile")
            .appendingPathComponent(gmliteRootRelative)
            .appendingPathComponent(manifestFileName)
    }

    static func parseManifest() -> [TrollStoreLiteInjectionEntry] {
        guard let manifestURL = manifestURL(),
              let data = try? Data(contentsOf: manifestURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any]
        else {
            return []
        }

        var entries: [TrollStoreLiteInjectionEntry] = []
        for (key, value) in dict {
            var enabled = true
            var tool: String?
            if let boolValue = value as? Bool {
                enabled = boolValue
            } else if let dictValue = value as? [String: Any] {
                if let on = dictValue["Enabled"] as? Bool {
                    enabled = on
                }
                tool = dictValue["InjectionTool"] as? String
            }
            guard !key.isEmpty else { continue }
            entries.append(TrollStoreLiteInjectionEntry(
                path: key,
                enabled: enabled,
                injectionTool: tool
            ))
        }
        return entries
    }

    /// App 相关的已注入 dylib（清单 + app 内 Frameworks 中复制的 dylib）。
    static func injectedPlugInsForApp(_ bundleURL: URL) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        for entry in parseManifest() where entry.path.hasPrefix("/") {
            let url = URL(fileURLWithPath: entry.path)
            if seen.insert(url.path).inserted {
                result.append(url)
            }
        }

        let frameworksURL = bundleURL.appendingPathComponent("Frameworks")
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: frameworksURL,
            includingPropertiesForKeys: nil
        ) {
            for url in contents where url.pathExtension.lowercased() == "dylib" {
                if seen.insert(url.path).inserted {
                    result.append(url)
                }
            }
        }

        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - 运行

    @discardableResult
    static func spawn(
        _ binary: URL,
        arguments: [String]
    ) throws -> Int32 {
        let receipt = try Execute.rootSpawnWithOutputs(
            binary: binary.path,
            arguments: arguments,
            environment: ["DISABLE_TWEAKS": "1"]
        )
        if case let .exit(code) = receipt.terminationReason {
            return code
        }
        throw TrollStoreLiteError.spawnFailed(binary.lastPathComponent)
    }
}

// MARK: - 错误

enum TrollStoreLiteError: LocalizedError {
    case helperUnavailable
    case injectionFailed(Int32, String)
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return NSLocalizedString(
                "TrollStore Lite helper is not available on this device.\n\nPlease install TrollStore Lite (or 巨魔R) first, then re-open TrollFools.",
                comment: ""
            )
        case let .injectionFailed(code, command):
            return String(
                format: NSLocalizedString("TrollStore Lite helper %@ failed with code %d.", comment: ""),
                command, code
            )
        case let .spawnFailed(name):
            return String(
                format: NSLocalizedString("TrollStore Lite helper %@ failed to start.", comment: ""),
                name
            )
        }
    }
}