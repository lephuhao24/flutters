import Foundation
import Observation

@MainActor @Observable final class SDKViewModel {
    private(set) var sdks: [FlutterSDK] = []
    private(set) var loading = false
    private(set) var lastRefreshDate: Date?
    var error: String?
    let service: any FVMService
    init(service: any FVMService) { self.service = service }
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { sdks = try await service.installed(); lastRefreshDate = Date(); error = nil }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
