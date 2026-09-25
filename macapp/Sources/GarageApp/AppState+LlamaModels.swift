import Foundation

/// Which models LlamaXPCService holds, and when: the default embedding model from launch on, so a
/// search can embed its query at once, and the facts model only while `enrich-facts` runs.
/// Models used any other way still load on demand (`LlamaModelLoader`) and stay until unloaded.
extension AppState {
    /// The registered model search embeds with, chosen as the Python side does
    /// (`emb_tables.get_model`): the one flagged default, else `embedding.default_model`.
    var defaultEmbeddingModel: RegisteredModel? {
        if let flagged = registeredModels.first(where: \.isDefault) {
            return flagged
        }
        let configured = GarageConfigLoader.loadDefaultEmbeddingModel()
        return registeredModels.first { $0.slug == configured }
    }

    /// Loads the default embedding model when it runs on llama_xpc. Once per model per launch: a
    /// later refresh leaves it unloaded if the Models page unloaded it, and a new default loads.
    func preloadDefaultEmbeddingModel() async {
        guard let model = defaultEmbeddingModel, model.provider == "llama_xpc" else { return }
        // Python names the model by `model_ref` in its requests, the alias the engine keeps it under.
        let alias = model.modelRef
        guard !alias.isEmpty, preloadedEmbeddingModel != alias else { return }
        preloadedEmbeddingModel = alias
        llama.appendLog("Loading the default embedding model \(alias) for search")
        let loaded = await llama.ensureLoaded(alias: alias)
        if !loaded {
            // Try again at the next refresh (the model may still be downloading, say).
            preloadedEmbeddingModel = nil
        }
    }

    /// Loads the llama_xpc facts model before a distillation run, and notes it for
    /// `unloadFactsModelAfterDistilling`. A model that is also the search model is left alone.
    func loadFactsModelForDistilling(_ runner: OperationRunner) async {
        factsModelHeldForDistilling = nil
        fetchFactsSettings()
        let alias = factsModel
        guard factsProvider == "llama_xpc", !alias.isEmpty, alias != defaultEmbeddingModel?.modelRef else { return }
        factsModelHeldForDistilling = alias
        runner.appendLog("Loading the distillation model \(alias)")
        let loaded = await llama.ensureLoaded(alias: alias)
        if !loaded {
            // The run still goes ahead: Python loads on demand and reports the failure per document.
            runner.appendLog("Could not load \(alias) ahead of the run: \(llama.lastError ?? "unknown error")", stream: .stderr)
        }
    }

    /// Frees the facts model once a distillation run ends, however it ended.
    func unloadFactsModelAfterDistilling() async {
        guard let alias = factsModelHeldForDistilling else { return }
        factsModelHeldForDistilling = nil
        // Python may have loaded it on demand in its own process; ask the service what it holds.
        await llama.refreshStatus()
        guard llama.isModelLoaded(alias: alias) else { return }
        enrichFacts.appendLog("Unloading the distillation model \(alias)")
        await llama.unloadModel(alias: alias)
    }
}
