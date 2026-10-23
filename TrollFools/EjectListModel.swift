//
//  EjectListModel.swift
//  TrollFools
//
//  Created by 82Flex on 2024/10/30.
//

import Combine
import SwiftUI

final class EjectListModel: ObservableObject {
    let app: App
    private(set) var injectedPlugIns: [InjectedPlugIn] = []

    @Published var filter = FilterOptions()
    @Published var filteredPlugIns: [InjectedPlugIn] = []

    @Published var isOkToEnableAll = false
    @Published var isOkToDisableAll = false

    @Published var processingPlugIn: InjectedPlugIn?

    private var cancellables = Set<AnyCancellable>()

    init(_ app: App) {
        self.app = app
        reload()

        $filter
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.performFilter()
            }
            .store(in: &cancellables)
    }

    func reload() {
        var plugIns = [InjectedPlugIn]()
        // TrollStore Lite / 巨魔R 后端：按 app 清单解析真实启用状态，
        // 而不是把所有已注入 dylib 一律标为已启用。
        let entries = TrollStoreLiteBackend.parseManifest(for: app.url)
        var entryEnabledByName: [String: Bool] = [:]
        for entry in entries {
            // 兼容两种 key 形态：绝对路径或纯文件名（helper 内部按 dylib 名匹配）。
            entryEnabledByName[URL(fileURLWithPath: entry.path).lastPathComponent] = entry.enabled
        }

        plugIns += InjectorV3.main.injectedAssetURLsInBundle(app.url)
            .map { InjectedPlugIn(url: $0, isEnabled: entryEnabledByName[$0.lastPathComponent] ?? true) }

        let enabledNames = plugIns.map { $0.url.lastPathComponent }
        plugIns += InjectorV3.main.persistedAssetURLs(bid: app.bid)
            .filter { !enabledNames.contains($0.lastPathComponent) }
            .map { InjectedPlugIn(url: $0, isEnabled: false) }

        injectedPlugIns = plugIns
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

        performFilter()
    }

    func performFilter() {
        var filteredPlugIns = injectedPlugIns

        if !filter.searchKeyword.isEmpty {
            filteredPlugIns = filteredPlugIns.filter {
                $0.url.lastPathComponent.localizedCaseInsensitiveContains(filter.searchKeyword)
            }
        }

        self.filteredPlugIns = filteredPlugIns
        isOkToEnableAll = filteredPlugIns.contains { !$0.isEnabled }
        isOkToDisableAll = filteredPlugIns.contains { $0.isEnabled }
    }

    func togglePlugIn(_ plugIn: InjectedPlugIn, isEnabled: Bool) {
        guard plugIn.isEnabled != isEnabled else {
            return
        }
        processingPlugIn = plugIn
    }
}
