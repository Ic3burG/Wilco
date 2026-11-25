import AppKit
import WilcoCore

/// Saved show setups. `document` (autosaved to `Current.wilco`) is the
/// working copy; a configuration only changes when the user saves.
extension AppModel {
    var configurationStatus: ConfigurationRules.Status {
        ConfigurationRules.status(working: document, saved: savedConfiguration)
    }

    var windowTitle: String {
        document.name + ConfigurationRules.titleSuffix(configurationStatus)
    }

    /// Re-reads the folder. If the loaded configuration's file has gone,
    /// the working copy becomes "Not Saved" so it can't be replaced unasked.
    func refreshConfigurations() {
        configurations = configurationStore.list()
        if loadedConfigurationID != nil,
           ConfigurationRules.stillLoaded(loadedConfigurationID, in: configurations) == nil {
            loadedConfigurationID = nil
            savedConfiguration = nil
        }
    }

    /// At launch: the first time, the current show becomes the first
    /// configuration; after that, reconnect to the one last loaded.
    func restoreLoadedConfiguration() {
        do {
            if let id = try configurationStore.migrateIfEmpty(from: document) {
                loadedConfigurationID = id
                savedConfiguration = try configurationStore.document(id)
            } else if let raw = UserDefaults.standard.string(forKey: Self.loadedConfigurationKey),
                      let id = UUID(uuidString: raw), configurationStore.exists(id) {
                loadedConfigurationID = id
                savedConfiguration = try? configurationStore.document(id)
            } else {
                loadedConfigurationID = nil
                savedConfiguration = nil
            }
        } catch {
            lastMessage = "Could not keep the show as a configuration: \(error.localizedDescription)"
        }
        // Once: older saves reset each file's creation date, so recover an
        // estimate from the sessions recorded with each configuration.
        if !UserDefaults.standard.bool(forKey: Self.createdDatesBackfilledKey) {
            configurationStore.backfillCreationDates(fromSessionsIn: DataLocations.transcripts)
            UserDefaults.standard.set(true, forKey: Self.createdDatesBackfilledKey)
        }
        refreshConfigurations()
    }

    // MARK: Loading

    func requestLoadConfiguration(_ id: UUID) {
        refreshConfigurations()
        switch ConfigurationRules.loadDecision(
            target: id, loaded: loadedConfigurationID, status: configurationStatus, isCapturing: isCapturing
        ) {
        case .refuseWhileCapturing:
            lastMessage = "Stop capture before loading a different configuration."
        case .alreadyLoaded:
            break
        case .askToSaveFirst:
            configurationPendingLoad = id
        case .load:
            loadConfiguration(id)
        }
    }

    /// Answers the Save / Don't Save prompt (Cancel just clears the pending load).
    func resolvePendingLoad(saveFirst: Bool) {
        guard let id = configurationPendingLoad else { return }
        configurationPendingLoad = nil
        if saveFirst, !saveConfiguration() { return }
        loadConfiguration(id)
    }

    /// Replaces the whole show and clears the on-screen transcript.
    func loadConfiguration(_ id: UUID) {
        guard !isCapturing else {
            lastMessage = "Stop capture before loading a different configuration."
            return
        }
        do {
            let show = try configurationStore.document(id)
            document = show
            savedConfiguration = show
            loadedConfigurationID = id
            clearLiveViews()
            selection = selection.validated(in: show)
            saveNow()
        } catch {
            lastMessage = "Could not open that configuration: \(error.localizedDescription)"
            refreshConfigurations()
        }
    }

    // MARK: Quitting

    /// Settings › General: ask about unsaved configuration changes on quit.
    static let asksToSaveOnQuitKey = "quit.asksToSaveConfiguration"

    static var asksToSaveOnQuit: Bool {
        UserDefaults.standard.object(forKey: asksToSaveOnQuitKey) as? Bool ?? true
    }

    /// Whether quitting may go ahead now. Asks first when the setting is on
    /// and the configuration has unsaved changes. Saving a working copy with
    /// no file opens the name sheet and cancels the quit, since naming it
    /// can't happen inside the quit.
    func shouldQuit() -> Bool {
        refreshConfigurations()
        guard case .askToSave(let needsName) = ConfigurationRules.quitDecision(
            status: configurationStatus, asksToSave: Self.asksToSaveOnQuit
        ) else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.name)” before quitting?"
        alert.informativeText = needsName
            ? "This show isn't saved as a configuration. If you don't save, Wilco still reopens with it as you left it."
            : "If you don't save, the configuration keeps its saved version. Wilco still reopens with your changes, marked Edited."
        alert.addButton(withTitle: needsName ? "Save As New…" : "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveConfiguration()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Saving

    /// Writes the working copy into the loaded configuration. Returns false
    /// if it couldn't, including when there's no file to save into (the
    /// user is then asked for a name, as for Save As New).
    @discardableResult
    func saveConfiguration() -> Bool {
        refreshConfigurations()
        guard let id = loadedConfigurationID else {
            isNamingNewConfiguration = true
            return false
        }
        if let problem = ConfigurationRules.saveNameCheck(name: document.name, loaded: id, in: configurations) {
            lastMessage = problem.message
            return false
        }
        do {
            try configurationStore.write(document, id: id)
            savedConfiguration = document
            refreshConfigurations()
            return true
        } catch {
            lastMessage = "Could not save “\(document.name)”: \(error.localizedDescription)"
            return false
        }
    }

    func saveConfigurationAsNew(named name: String) {
        var show = document
        show.name = name
        do {
            let id = try configurationStore.create(show)
            let saved = try configurationStore.document(id)
            document.name = saved.name
            savedConfiguration = saved
            loadedConfigurationID = id
            refreshConfigurations()
        } catch {
            lastMessage = "Could not save a new configuration: \(error.localizedDescription)"
        }
    }

    func revertConfiguration() {
        guard !isCapturing else {
            lastMessage = "Stop capture before reverting to the saved configuration."
            return
        }
        guard let savedConfiguration else { return }
        document = savedConfiguration
        selection = selection.validated(in: document)
    }

    // MARK: Managing

    @discardableResult
    func newConfiguration() -> UUID? {
        manage { try configurationStore.create(ShowDocument()) }
    }

    @discardableResult
    func duplicateConfiguration(_ id: UUID) -> UUID? {
        manage { try configurationStore.duplicate(id) }
    }

    /// Renaming the loaded one renames the working copy too, without
    /// marking it Edited.
    func renameConfiguration(_ id: UUID, to name: String) {
        manage {
            let renamed = try configurationStore.rename(id, to: name)
            if id == loadedConfigurationID {
                savedConfiguration?.name = renamed.name
                document.name = renamed.name
            }
        }
    }

    /// The loaded configuration can't be deleted, so something is always loaded.
    func deleteConfiguration(_ id: UUID) {
        guard id != loadedConfigurationID else { return }
        manage { try configurationStore.delete(id) }
    }

    @discardableResult
    func importConfigurations(_ urls: [URL]) -> [UUID] {
        let result = configurationStore.importFiles(urls)
        refreshConfigurations()
        var messages: [String] = []
        if !result.failed.isEmpty {
            let names = result.failed.map(\.lastPathComponent).joined(separator: ", ")
            messages.append("Could not read \(names). Is it a Wilco show file?")
        }
        if !result.turnedOff.isEmpty {
            messages.append(Self.turnedOffMessage(result.turnedOff))
        }
        if !messages.isEmpty { lastMessage = messages.joined(separator: "\n\n") }
        return result.imported
    }

    /// Says which imported rules were turned off and where they would send.
    static func turnedOffMessage(_ turnedOff: [OutboundRules.TurnedOff]) -> String {
        let hosts = turnedOff.flatMap(\.hosts).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let rules = turnedOff.map { "“\($0.rule)”" }.joined(separator: ", ")
        let count = turnedOff.count == 1 ? "1 rule" : "\(turnedOff.count) rules"
        return "\(count) that send what's heard to another machine came in turned off: \(rules), sending to \(hosts.joined(separator: ", ")). "
            + "Turn on the ones you trust in Settings › Rules & Highlights."
    }

    func exportConfiguration(_ id: UUID, to url: URL) {
        manage { try configurationStore.export(id, to: url) }
    }

    /// Runs a store operation, reports a failure, and refreshes the list.
    private func manage<T>(_ operation: () throws -> T) -> T? {
        defer { refreshConfigurations() }
        do {
            return try operation()
        } catch let error as ConfigurationError {
            lastMessage = error.message
        } catch {
            lastMessage = error.localizedDescription
        }
        return nil
    }
}
