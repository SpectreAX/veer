import Testing
@testable import VeerCore

struct UniquedTests {
    @Test func keepsTheFirstOfEachInOrder() {
        #expect(["b", "a", "b", "c", "a"].uniqued() == ["b", "a", "c"])
        #expect([String]().uniqued().isEmpty)
    }

    @Test func aRepeatedFetchedModelIsListedOnce() {
        var settings = AISettings()
        settings.fetchedModels = ["fetched-model", "fetched-model"]
        let models = settings.models(includingFetched: true)
        #expect(models.filter { $0 == "fetched-model" }.count == 1)
        #expect(Set(models).count == models.count)
    }
}
