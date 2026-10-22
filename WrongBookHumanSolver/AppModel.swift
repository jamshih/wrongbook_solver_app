import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    enum QueueTab: String, CaseIterable, Identifiable {
        case queued = "待處理", claimed = "處理中", answered = "已回覆"
        var id: String { rawValue }
        var backendStatus: String { switch self { case .queued: "queued"; case .claimed: "claimed"; case .answered: "answered" } }
    }

    @Published var tab: QueueTab = .queued
    @Published var requests: [SolverRequest] = []
    @Published var unreadCounts: [String: Int] = [:]
    @Published var selectedID: UUID?
    @Published var detail: SolverDetailResponse?

    /// Queue/detail loading are deliberately independent. V174 used one blocking queue spinner,
    /// which made a transient URLSession connection failure look like a frozen application.
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedQueue = false
    @Published private(set) var queueErrorMessage: String?
    @Published private(set) var isDetailLoading = false
    @Published private(set) var detailErrorMessage: String?
    @Published var errorMessage: String?

    let auth: AuthStore
    lazy var api = HumanSolverAdminAPI(auth: auth)

    private var queueGeneration = 0
    private var detailGeneration = 0
    private var queueTask: Task<SolverQueueResponse, Error>?
    private var detailTask: Task<SolverDetailResponse, Error>?

    private var accountSubscription: AnyCancellable?
    init(auth: AuthStore) {
        self.auth = auth
        accountSubscription = auth.$sessionGeneration.dropFirst().sink { [weak self] _ in self?.invalidateAccount() }
    }

    func invalidateAccount() {
        clearSolverImageCaches()
        queueGeneration += 1; detailGeneration += 1
        queueTask?.cancel(); detailTask?.cancel()
        requests = []; unreadCounts = [:]; detail = nil; selectedID = nil
        isLoading = false; isDetailLoading = false; errorMessage = nil
    }

    func reloadQueue() async {
        guard auth.state == .operatorReady else { return }

        queueGeneration += 1
        let generation = queueGeneration
        let requestedTab = tab
        let accountGeneration = auth.sessionGeneration
        isLoading = true
        queueErrorMessage = nil

        defer {
            if generation == queueGeneration {
                isLoading = false
                queueTask = nil
            }
        }

        queueTask?.cancel()
        let task = Task { try await api.queue(status: requestedTab.backendStatus) }
        queueTask = task

        do {
            let loaded = try await task.value
            guard generation == queueGeneration, requestedTab == tab, accountGeneration == auth.sessionGeneration else { return }
            requests = loaded.requests
            unreadCounts = loaded.unreadCounts ?? [:]
            hasLoadedQueue = true
            if let selectedID,
               !loaded.requests.contains(where: { $0.id == selectedID }),
               tab != .answered {
                self.selectedID = nil
                detail = nil
                detailErrorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == queueGeneration, requestedTab == tab, accountGeneration == auth.sessionGeneration else { return }
            hasLoadedQueue = true
            queueErrorMessage = AppError.userFacingMessage(for: error)
        }
    }

    func cancelQueueLoad() {
        queueGeneration += 1
        queueTask?.cancel()
        queueTask = nil
        isLoading = false
        queueErrorMessage = nil
        // Keep any already loaded rows. For a first-load cancellation, return to a neutral
        // "載入佇列" state instead of leaving a spinner on screen.
        if requests.isEmpty { hasLoadedQueue = false }
    }

    func cancelDetailLoad() {
        detailGeneration += 1
        detailTask?.cancel()
        detailTask = nil
        isDetailLoading = false
        detailErrorMessage = nil
    }

    func changeTab() async {
        // Invalidate in-flight responses from the previous tab immediately.
        queueGeneration += 1
        detailGeneration += 1
        queueTask?.cancel()
        queueTask = nil
        detailTask?.cancel()
        detailTask = nil
        selectedID = nil
        detail = nil
        detailErrorMessage = nil
        requests = []
        hasLoadedQueue = false
        queueErrorMessage = nil
        await reloadQueue()
    }

    func select(_ request: SolverRequest) async {
        detailTask?.cancel()
        detailTask = nil
        selectedID = request.id
        detail = nil
        detailErrorMessage = nil
        await reloadDetail()
    }

    func reloadDetail() async {
        guard let selectedID else { return }

        detailGeneration += 1
        let generation = detailGeneration
        let requestID = selectedID
        let accountGeneration = auth.sessionGeneration
        isDetailLoading = true
        detailErrorMessage = nil

        detailTask?.cancel()
        let task = Task { try await api.detail(id: requestID) }
        detailTask = task

        defer {
            if generation == detailGeneration {
                isDetailLoading = false
                detailTask = nil
            }
        }

        do {
            let loaded = try await task.value
            guard generation == detailGeneration, self.selectedID == requestID, accountGeneration == auth.sessionGeneration else { return }
            detail = loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == detailGeneration, self.selectedID == requestID, accountGeneration == auth.sessionGeneration else { return }
            detailErrorMessage = AppError.userFacingMessage(for: error)
        }
    }

    func claimSelected() async {
        guard let selectedID else { return }
        do {
            try await api.claim(id: selectedID)
            tab = .claimed
            await changeTabAfterClaim(selectedID)
        } catch { errorMessage = AppError.userFacingMessage(for: error) }
    }

    private func changeTabAfterClaim(_ requestID: UUID) async {
        queueGeneration += 1
        requests = []
        hasLoadedQueue = false
        queueErrorMessage = nil
        self.selectedID = requestID
        detail = nil
        await reloadQueue()
        // Preserve the selected claimed request even if the queue response happens to arrive first.
        self.selectedID = requestID
        await reloadDetail()
    }

    func sendReply(requestID: UUID, text: String, images: [PendingImage]) async -> Bool {
        guard let selectedID, selectedID == requestID else { return false }
        let generation = auth.sessionGeneration
        do {
            _ = try await api.reply(requestID: selectedID, text: text, images: images)
            guard auth.sessionGeneration == generation else { return false }
            guard self.selectedID == selectedID else { return true }
            // A successful reply moves a queued/claimed request to the answered queue.
            // Reloading the previous queue would otherwise clear the selected thread.
            // Keep the conversation open so operators can send additional messages.
            tab = .answered
            self.selectedID = selectedID
            queueGeneration += 1
            queueTask?.cancel()
            requests = []
            hasLoadedQueue = false
            queueErrorMessage = nil
            await reloadQueue()
            self.selectedID = selectedID
            await reloadDetail()
            return true
        } catch {
            errorMessage = AppError.userFacingMessage(for: error)
            return false
        }
    }

    func closeSelected() async {
        guard let selectedID else { return }
        do {
            try await api.close(id: selectedID)
            self.selectedID = nil
            detail = nil
            detailErrorMessage = nil
            await reloadQueue()
        } catch { errorMessage = AppError.userFacingMessage(for: error) }
    }
}
