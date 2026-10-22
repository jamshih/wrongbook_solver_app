import Foundation
import PhotosUI
import SwiftUI
import UIKit
import ImageIO



/// Keeps expensive camera/photo decoding, resizing, and JPEG compression off the main actor.
/// The operator UI stores a small preview separately so SwiftUI does not repeatedly decode a
/// multi-megabyte original every time the composer body is recomputed.
private enum SolverImageProcessor {
    private static let queue = DispatchQueue(label: "com.wrongbook.humansolver.image-processor", qos: .userInitiated, attributes: .concurrent)

    static func prepare(data: Data, filename: String) async -> PendingImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                let result: PendingImage? = autoreleasepool {
                    guard let upload = downsampledJPEG(from: data, maxPixel: 2560, quality: 0.84) else { return nil }
                    let preview = downsampledJPEG(from: data, maxPixel: 360, quality: 0.72)
                    return PendingImage(data: upload, previewData: preview, filename: normalizedJPEGName(filename), mimeType: "image/jpeg")
                }
                continuation.resume(returning: result)
            }
        }
    }

    static func prepare(image: UIImage, filename: String) async -> PendingImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                let result: PendingImage? = autoreleasepool {
                    guard let sourceData = image.jpegData(compressionQuality: 0.92),
                          let upload = downsampledJPEG(from: sourceData, maxPixel: 2560, quality: 0.84) else { return nil }
                    let preview = downsampledJPEG(from: sourceData, maxPixel: 360, quality: 0.72)
                    return PendingImage(data: upload, previewData: preview, filename: normalizedJPEGName(filename), mimeType: "image/jpeg")
                }
                continuation.resume(returning: result)
            }
        }
    }

    static func preview(data: Data, maxPixel: Int = 1400) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = autoreleasepool {
                    downsampledJPEG(from: data, maxPixel: maxPixel, quality: 0.80)
                }
                continuation.resume(returning: result)
            }
        }
    }

    private static func normalizedJPEGName(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return (base.isEmpty ? "reply_\(UUID().uuidString)" : base) + ".jpg"
    }

    private static func downsampledJPEG(from data: Data, maxPixel: Int, quality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}


private final class SolverRemoteImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private init() {}
}

private final class SolverPendingPreviewCache {
    static let shared: NSCache<NSUUID, UIImage> = {
        let cache = NSCache<NSUUID, UIImage>()
        cache.countLimit = 20
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
    private init() {}
}

private struct PendingImageThumbnail: View {
    let item: PendingImage
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.08))
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: item.id) {
            let key = item.id as NSUUID
            if let cached = SolverPendingPreviewCache.shared.object(forKey: key) {
                image = cached
                return
            }
            let data = item.previewData ?? item.data
            // The preview has already been downsampled to ~360 px off-main; decode it once and
            // cache the UIImage instead of repeating UIImage(data:) on every keystroke.
            guard !Task.isCancelled, let decoded = UIImage(data: data) else { return }
            SolverPendingPreviewCache.shared.setObject(decoded, forKey: key, cost: data.count)
            image = decoded
        }
    }
}

private struct SolverRemoteImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                ContentUnavailableView("圖片載入失敗", systemImage: "photo")
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            failed = false
            let key = url as NSURL
            if let cached = SolverRemoteImageCache.shared.object(forKey: key) {
                image = cached
                return
            }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.cachePolicy = .returnCacheDataElseLoad
                let (raw, response) = try await NetworkTransport.data(for: request, timeout: 15)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let preview = await SolverImageProcessor.preview(data: raw) else {
                    failed = true
                    return
                }
                // The expensive network/downsample work is already off-main. Decode this
                // bounded preview once, then cache the UIImage for subsequent view updates.
                guard !Task.isCancelled, let decoded = UIImage(data: preview) else { return }
                SolverRemoteImageCache.shared.setObject(decoded, forKey: key, cost: preview.count)
                image = decoded
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var auth: AuthStore
    @StateObject private var model: AppModel

    init(auth: AuthStore) {
        self.auth = auth
        _model = StateObject(wrappedValue: AppModel(auth: auth))
    }

    var body: some View {
        Group {
            switch auth.state {
            case .operatorReady: AdminHomeView(model: model)
            case .signedIn: OperatorUnlockView(auth: auth)
            case .signedOut: LoginView(auth: auth)
            case .busy(let text):
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text(text)
                        .font(.headline)
                    Text("連線不會無限等待；也可以立即取消並返回。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("取消", role: .cancel) { auth.cancelBusyOperation() }
                        .buttonStyle(.bordered)
                }
                .padding(32)
            case .error(let text):
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                    Text(text).multilineTextAlignment(.center)
                    Button("返回") { auth.restore() }.buttonStyle(.borderedProminent)
                }.padding(32)
            }
        }
    }
}

struct LoginView: View {
    @ObservedObject var auth: AuthStore
    var body: some View {
        NavigationStack {
            Form {
                Section("WrongBook 真人解題後台") {
                    Text("這是一個獨立的原生 Swift 管理 App。必須先登入你的 WrongBook 帳號，再通過 Operator Key。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("登入") {
                    TextField("Email", text: $auth.email).textInputAutocapitalization(.never).keyboardType(.emailAddress).textContentType(.emailAddress)
                    SecureField("Password", text: $auth.password).textContentType(.password)
                    Button("Email 登入") { Task { await auth.signInPassword() } }.buttonStyle(.borderedProminent)
                    Button { Task { await auth.signInGoogle() } } label: { Label("使用 Google 登入", systemImage: "person.crop.circle.badge.checkmark") }
                }
            }.navigationTitle("Human Solver")
        }
    }
}

struct OperatorUnlockView: View {
    @ObservedObject var auth: AuthStore
    var body: some View {
        NavigationStack {
            Form {
                Section("第二道驗證") {
                    SecureField("Operator Key", text: $auth.operatorKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("解鎖真人後台") { Task { await auth.unlockOperator() } }.buttonStyle(.borderedProminent)
                }
                Section { Button("登出 WrongBook 帳號", role: .destructive) { auth.signOut() } }
            }.navigationTitle("擁有者驗證")
        }
    }
}

struct AdminHomeView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Queue", selection: $model.tab) {
                    ForEach(AppModel.QueueTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding()
                ZStack {
                    List(model.requests, selection: $model.selectedID) { request in
                        Button { Task { await model.select(request) } } label: { RequestRow(request: request) }.buttonStyle(.plain)
                    }
                    .refreshable { await model.reloadQueue() }
                    .scrollDismissesKeyboard(.interactively)
                    .opacity(model.requests.isEmpty ? 0 : 1)

                    if model.requests.isEmpty {
                        QueueStateView(
                            isLoading: model.isLoading,
                            hasLoaded: model.hasLoadedQueue,
                            errorMessage: model.queueErrorMessage,
                            retry: { Task { await model.reloadQueue() } },
                            cancel: { model.cancelQueueLoad() }
                        )
                    }
                }
            }
            .navigationTitle("真人解題")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { model.auth.lockOperator() } label: { Image(systemName: "lock") } }
                ToolbarItem(placement: .topBarTrailing) { Button { Task { await model.reloadQueue() } } label: { Image(systemName: "arrow.clockwise") } }
                ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            }
        } detail: {
            if model.selectedID != nil { RequestDetailView(model: model) }
            else { ContentUnavailableView("選擇一題", systemImage: "text.bubble", description: Text("從左側待處理清單選擇學生送來的題目。")) }
        }
        .task { await model.reloadQueue() }
        .sheet(isPresented: $showSettings) { OperatorSettingsView(model: model) }
        .onChange(of: model.tab) { _, _ in Task { await model.changeTab() } }
        .alert("錯誤", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(model.errorMessage ?? "") }
    }
}



private struct QueueStateView: View {
    let isLoading: Bool
    let hasLoaded: Bool
    let errorMessage: String?
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                Text("正在同步真人解題佇列…")
                    .font(.headline)
                Text("最多等待約 10 秒；也可以立即取消同步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("取消同步", role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
            } else if let errorMessage {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34, weight: .semibold))
                Text("目前無法取得佇列")
                    .font(.headline)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重新整理", action: retry)
                    .buttonStyle(.borderedProminent)
            } else if hasLoaded {
                ContentUnavailableView("目前沒有題目", systemImage: "checkmark.circle", description: Text("這個佇列目前是空的。"))
            } else {
                Button("載入佇列", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
    }
}

private struct DetailStateView: View {
    let isLoading: Bool
    let errorMessage: String?
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                Text("正在載入題目…")
                    .font(.headline)
                Text("最多等待約 10 秒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("取消載入", role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
            } else if let errorMessage {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 34, weight: .semibold))
                Text("題目載入失敗")
                    .font(.headline)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重試", action: retry)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("載入題目", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }
}

struct RequestRow: View {
    let request: SolverRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(request.subject.isEmpty ? "未分類" : request.subject).font(.caption.bold()); Spacer(); statusBadge }
            Text(request.stem).lineLimit(3).font(.body)
            HStack(spacing: 12) {
                if !request.optionLines.isEmpty { Label("\(request.optionLines.count) 選項", systemImage: "list.bullet") }
                if !request.displayMedia.isEmpty { Label("\(request.displayMedia.count) 圖", systemImage: "photo") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
    private var statusBadge: some View {
        Text(request.status == "queued" ? "待處理" : request.status == "claimed" ? "處理中" : "已回覆")
            .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(.thinMaterial, in: Capsule())
    }
}

struct RequestDetailView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false
    @State private var questionExpanded = false

    var body: some View {
        Group {
            if let detail = model.detail {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("學生的解題對話")
                                .font(.headline)
                            Text(detail.request.subject.isEmpty ? "真人解題" : detail.request.subject)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(detail.request.status == "closed" ? "已關閉" :
                             detail.request.status == "answered" ? "已回覆" :
                             detail.request.status == "claimed" ? "處理中" : "待處理")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    Divider()

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                DisclosureGroup(isExpanded: $questionExpanded) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        HeaderBlock(request: detail.request)
                                        if let shared = detail.request.sharedPassage {
                                            GroupBox("題組文章 / 共用題幹") {
                                                Text(shared).frame(maxWidth: .infinity, alignment: .leading)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        if !detail.request.optionLines.isEmpty {
                                            GroupBox("選項") {
                                                VStack(alignment: .leading, spacing: 10) {
                                                    ForEach(detail.request.optionLines, id: \.self) {
                                                        Text($0).textSelection(.enabled)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        FigureGallery(figures: detail.request.displayMedia)
                                    }
                                    .padding(.top, 12)
                                } label: {
                                    Label("查看題目、原始裁切圖與圖表", systemImage: "doc.text.image")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .padding(14)
                                .background(Color(uiColor: .secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 16))

                                HStack {
                                    Spacer()
                                    Text("真人解題對話")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }

                                if detail.messages.isEmpty {
                                    HStack {
                                        Spacer()
                                        Text("學生已送出題目。你可以傳送文字、照片，或兩者一起回覆。")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(18)
                                        Spacer()
                                    }
                                } else {
                                    MessageHistory(messages: detail.messages)
                                }
                                Color.clear.frame(height: 1).id("last-message")
                            }
                            .padding(20)
                            .frame(maxWidth: 900)
                            .frame(maxWidth: .infinity)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: detail.messages.count) { _, _ in
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("last-message", anchor: .bottom)
                            }
                        }
                        .task(id: detail.request.id) {
                            proxy.scrollTo("last-message", anchor: .bottom)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if detail.request.status != "closed" {
                        ReplyComposer { text, images in
                            await model.sendReply(text: text, images: images)
                        }
                    } else {
                        Text("此對話已關閉")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(.regularMaterial)
                    }
                }
                .navigationTitle("真人解題")
                .toolbar {
                    if detail.request.status == "queued" {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("開始處理") { Task { await model.claimSelected() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await model.reloadDetail() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) { OperatorSettingsView(model: model) }
            } else {
                DetailStateView(
                    isLoading: model.isDetailLoading,
                    errorMessage: model.detailErrorMessage,
                    retry: { Task { await model.reloadDetail() } },
                    cancel: { model.cancelDetailLoad() }
                )
                .task {
                    if !model.isDetailLoading && model.detailErrorMessage == nil {
                        await model.reloadDetail()
                    }
                }
            }
        }
    }
}

struct HeaderBlock: View {
    let request: SolverRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(request.subject.isEmpty ? "未分類" : request.subject).font(.headline); Spacer(); Text(request.status).font(.caption.monospaced()).foregroundStyle(.secondary) }
            Text(request.stem).font(.title3.weight(.medium)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FigureGallery: View {
    let figures: [SolverFigure]

    private var orderedMedia: [SolverFigure] {
        // The backend orders media explicitly; older payloads keep their array order.
        figures.enumerated()
            .sorted { lhs, rhs in
                let leftOrder = lhs.element.displayOrder ?? lhs.offset
                let rightOrder = rhs.element.displayOrder ?? rhs.offset
                return leftOrder == rightOrder ? lhs.offset < rhs.offset : leftOrder < rightOrder
            }
            .map(\.element)
    }

    private var originalCrops: [SolverFigure] { orderedMedia.filter(\.isOriginalCrop) }
    private var extractedFigures: [SolverFigure] { orderedMedia.filter(\.isExtractedFigure) }
    private var legacyMedia: [SolverFigure] {
        orderedMedia.filter { !$0.isOriginalCrop && !$0.isExtractedFigure }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !originalCrops.isEmpty {
                SolverMediaStrip(title: "學生選取的原始題目裁切圖", figures: originalCrops)
            } else {
                Label(
                    "尚未收到獨立的原始裁切圖；舊格式圖片可能包含整頁，請勿視為學生選取的範圍。",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !extractedFigures.isEmpty {
                SolverMediaStrip(title: "擷取的圖形 / 圖表", figures: extractedFigures)
            }
            if !legacyMedia.isEmpty {
                SolverMediaStrip(title: "其他來源圖片（舊格式）", figures: legacyMedia)
            }
        }
    }
}

private struct SolverMediaStrip: View {
    let title: String
    let figures: [SolverFigure]

    var body: some View {
        GroupBox(title) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(figures.indices, id: \.self) { index in
                        let figure = figures[index]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(figure.label.flatMap { $0.isEmpty ? nil : $0 } ?? "圖片 \(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let raw = figure.signedURL,
                               let url = URL(string: raw),
                               url.scheme?.lowercased() == "https" {
                                SolverRemoteImage(url: url)
                                    .frame(width: 300, height: 260)
                                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            } else {
                                ContentUnavailableView(
                                    "圖片目前無法載入",
                                    systemImage: "photo.badge.exclamationmark",
                                    description: Text("請重新整理題目，以取得有效的圖片連結。")
                                )
                                .frame(width: 300, height: 260)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct MessageHistory: View {
    let messages: [SolverMessage]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(messages) { message in
                SolverMessageBubble(message: message)
            }
        }
    }
}

private struct SolverMessageBubble: View {
    let message: SolverMessage
    private var fromOperator: Bool { message.authorKind == "operator" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if fromOperator { Spacer(minLength: 48) }
            else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: fromOperator ? .trailing : .leading, spacing: 6) {
                if let body = message.body, !body.isEmpty {
                    Text(body)
                        .foregroundStyle(fromOperator ? Color.white : Color.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background {
                            if fromOperator {
                                RoundedRectangle(cornerRadius: 19)
                                    .fill(LinearGradient(
                                        colors: [Color(red: 0.33, green: 0.37, blue: 0.92),
                                                 Color(red: 0.55, green: 0.34, blue: 0.86)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                            } else {
                                RoundedRectangle(cornerRadius: 19)
                                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                            }
                        }
                }
                ForEach((message.attachments ?? []).sorted { $0.displayOrder < $1.displayOrder }) { attachment in
                    if let raw = attachment.signedURL,
                       let url = URL(string: raw),
                       url.scheme?.lowercased() == "https" {
                        SolverRemoteImage(url: url)
                            .frame(maxWidth: 280, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 15))
                    } else {
                        Label("圖片無法載入，請重新整理", systemImage: "photo.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let date = message.createdAt {
                    Text(date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 440, alignment: fromOperator ? .trailing : .leading)
            if !fromOperator { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ReplyComposer: View {
    // Keep transient typing/photo state inside the composer. In v182 the parent detail view owned
    // these values, so each keystroke invalidated the full question, figure gallery and message
    // history. Local state keeps keyboard typing updates inside this small subtree.
    @State private var text = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var images: [PendingImage] = []
    @State private var showCamera = false
    @State private var sending = false

    let send: (String, [PendingImage]) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 9) {
                        ForEach(images) { item in
                            ZStack(alignment: .topTrailing) {
                                PendingImageThumbnail(item: item)
                                    .frame(width: 76, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Button {
                                    images.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.75))
                                }
                                .accessibilityLabel("移除圖片")
                                .disabled(sending)
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.top, 4)
                }
            }

            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    Button {
                        showCamera = true
                    } label: {
                        Label("拍照", systemImage: "camera")
                    }
                    Button {
                        pasteImage()
                    } label: {
                        Label("貼上圖片", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 38)
                }
                .accessibilityLabel("更多圖片選項")
                .disabled(sending || images.count >= 10)

                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: max(1, 10 - images.count),
                    matching: .images
                ) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 38)
                }
                .accessibilityLabel("從相簿選擇圖片")
                .disabled(sending || images.count >= 10)

                TextField("傳送訊息…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 21))
                    .submitLabel(.send)

                Button {
                    Task { await submit() }
                } label: {
                    Group {
                        if sending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        (sending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty))
                            ? Color.gray : Color(red: 0.37, green: 0.39, blue: 0.94),
                        in: Circle()
                    )
                }
                .accessibilityLabel("傳送訊息")
                .disabled(
                    sending ||
                    (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                )
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                Task { @MainActor in
                    guard images.count < 10 else { return }
                    if let pending = await SolverImageProcessor.prepare(
                        image: image, filename: "camera_\(UUID().uuidString).jpg"
                    ), images.count < 10 {
                        images.append(pending)
                    }
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            Task { await load(items) }
        }
    }

    private func pasteImage() {
        guard images.count < 10, !sending,
              let image = UIPasteboard.general.image else { return }
        Task { @MainActor in
            if let pending = await SolverImageProcessor.prepare(
                image: image, filename: "paste_\(UUID().uuidString).jpg"
            ), images.count < 10 {
                images.append(pending)
            }
        }
    }

    @MainActor
    private func load(_ items: [PhotosPickerItem]) async {
        for item in items.prefix(max(0, 10 - images.count)) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  data.count <= 24 * 1024 * 1024 else { continue }
            if let pending = await SolverImageProcessor.prepare(
                data: data,
                filename: "photo_\(UUID().uuidString).jpg"
            ) {
                images.append(pending)
            }
        }
        pickerItems = []
    }

    @MainActor
    private func submit() async {
        guard !sending else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        sending = true
        defer { sending = false }
        if await send(trimmed, images) {
            text = ""
            images = []
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController(); c.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary; c.delegate = context.coordinator; return c
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker; init(parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) { if let image = info[.originalImage] as? UIImage { parent.onImage(image) }; parent.dismiss() }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}


struct OperatorSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""
    @State private var confirmKey = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("安全性") {
                    Button("撤銷所有 Operator Sessions", role: .destructive) {
                        Task {
                            busy = true; defer { busy = false }
                            do { let count = try await model.api.revokeOtherSessions(); message = "已撤銷 \(count) 個 session。請重新輸入 Operator Key。"; model.auth.lockOperator() }
                            catch { message = error.localizedDescription }
                        }
                    }
                }
                Section("更換 Operator Key") {
                    SecureField("新 Key（至少 30 字元）", text: $newKey)
                    SecureField("再輸入一次", text: $confirmKey)
                    Button("Rotate Key") {
                        Task {
                            guard newKey.count >= 30, newKey == confirmKey else { message = "兩次 Key 必須相同，且至少 30 字元。"; return }
                            busy = true; defer { busy = false }
                            do { let version = try await model.api.rotateOperatorKey(to: newKey); message = "Operator Key 已更新到 v\(version)。舊 sessions 已失效。"; newKey = ""; confirmKey = ""; model.auth.lockOperator() }
                            catch { message = error.localizedDescription }
                        }
                    }.disabled(busy)
                }
                Section {
                    Button("登出 WrongBook 帳號", role: .destructive) { model.auth.signOut(); dismiss() }
                }
            }
            .navigationTitle("後台設定")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .alert("狀態", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
        }
    }
}
