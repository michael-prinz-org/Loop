//
//  TherapyOptimizerDataCollector.swift
//  Loop
//
//  Feeds the TherapyOptimizer engine from Loop's stores and persists its state.
//

import Foundation
import Combine
import HealthKit
import LoopKit

final class TherapyOptimizer: ObservableObject {
    static let shared = TherapyOptimizer()

    @Published private(set) var state: TherapyOptimizerState?
    @Published private(set) var isProcessing = false
    @Published private(set) var lastError: String?
    /// Days of stored input that a recalculation can replay.
    @Published private(set) var storedDays = 0

    private let queue = DispatchQueue(label: "com.loopkit.Loop.TherapyOptimizer", qos: .utility)
    private let log = DiagnosticLog(category: "TherapyOptimizer")

    // Confined to queue
    private var doseStore: DoseStoreProtocol?
    private var glucoseStore: GlucoseStoreProtocol?
    private var carbStore: CarbStoreProtocol?
    private var workingState: TherapyOptimizerState?
    private var lastProcessingAttempt: Date = .distantPast
    private var settingsObserver: NSObjectProtocol?

    /// Data younger than this is not processed yet: meals and late CGM backfill need time to settle.
    private static let processingDelay: TimeInterval = 3 * 3600
    private static let processingInterval: TimeInterval = 3600
    private static let lookback: TimeInterval = 8 * 3600
    /// Raw history Loop keeps locally is 7 days; start a little later so insulin effects are complete.
    private static let backfillDays = 6

    private init() {
        queue.async {
            self.workingState = self.loadState()
            self.publish()
            self.publishStoredDays()
        }
        // Posted after every settings change (and often otherwise); comparing start values is cheap.
        settingsObserver = NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.restartIfSettingsChanged()
            }
        }
    }

    func configure(doseStore: DoseStoreProtocol, glucoseStore: GlucoseStoreProtocol, carbStore: CarbStoreProtocol) {
        queue.async {
            self.doseStore = doseStore
            self.glucoseStore = glucoseStore
            self.carbStore = carbStore
        }
    }

    // MARK: - Triggers

    /// Called after every successful loop; does real work at most once an hour.
    func loopDidComplete(overrides: [TemporaryScheduleOverride]) {
        queue.async {
            guard var state = self.workingState else { return }
            self.record(overrides, in: &state)
            self.workingState = state

            let now = Date()
            guard now.timeIntervalSince(self.lastProcessingAttempt) >= Self.processingInterval else { return }
            self.lastProcessingAttempt = now
            self.runProcessing(now: now, replay: false)
        }
    }

    func enable() {
        queue.async {
            // Turning calculation off keeps everything collected so far.
            let previous = self.loadState(from: Self.disabledStateURL)
            guard var state = self.makeState(keepingSummariesOf: previous) else { return }
            let backfillStart = self.backfillStart(for: state, now: Date())
            if state.lastProcessedDate < backfillStart {
                state.lastProcessedDate = backfillStart
                state.mealCutoffDate = backfillStart
                state.resetIntervalContext()
            }
            try? FileManager.default.removeItem(at: Self.disabledStateURL)
            self.workingState = state
            self.publish()
            self.log.default("Enabled; processing from %{public}@", String(describing: state.lastProcessedDate))
            self.runProcessing(now: Date(), replay: true)
        }
    }

    /// The active profile is the reference: when its values change, everything is recalculated from them.
    private func restartIfSettingsChanged() {
        guard let state = workingState,
              let current = stateFromCurrentSettings(now: Date()),
              !current.hasSameStartValues(as: state),
              let restarted = makeState(keepingSummariesOf: state) else { return }
        log.default("Active therapy settings changed; recalculating against them")
        workingState = restarted
        publish()
        lastProcessingAttempt = Date()
        runProcessing(now: Date(), replay: true)
    }

    /// Re-reads Loop's local history (last days) and replays all stored input.
    func recalculate() {
        queue.async {
            guard var state = self.workingState else { return }
            let backfillStart = self.backfillStart(for: state, now: Date())
            state.summaries.removeAll { $0.day >= backfillStart }
            state.lastProcessedDate = backfillStart
            state.mealCutoffDate = backfillStart
            state.resetIntervalContext()
            self.workingState = state
            self.runProcessing(now: Date(), replay: true)
        }
    }

    func setWindowDays(_ days: Int) {
        queue.async {
            guard var state = self.workingState, TherapyOptimizerState.windowOptions.contains(days) else { return }
            state.windowDays = days
            TherapyOptimizerEngine.replay(&state, rawDays: self.loadRawDays(calendar: state.calendar), through: state.lastProcessedDate)
            self.workingState = state
            self.saveState()
            self.publish()
        }
    }

    /// Stops calculating; collected data stays and is used again when turned back on.
    func disable() {
        queue.async {
            if let state = self.workingState {
                self.save(state, to: Self.disabledStateURL)
            }
            self.workingState = nil
            try? FileManager.default.removeItem(at: Self.stateURL)
            self.log.default("Disabled")
            self.publish()
        }
    }

    /// Deletes all collected data; a running calculation starts over from Loop's local history.
    func deleteCollectedData() {
        queue.async {
            let wasEnabled = self.workingState != nil
            self.workingState = nil
            for url in [Self.stateURL, Self.disabledStateURL, Self.rawDirectoryURL] {
                try? FileManager.default.removeItem(at: url)
            }
            self.log.default("Collected data deleted")
            self.publish()
            self.publishStoredDays()
            if wasEnabled {
                self.enable()
            }
        }
    }

    // MARK: - Processing (on queue)

    private func makeState(keepingSummariesOf previous: TherapyOptimizerState?) -> TherapyOptimizerState? {
        let now = Date()
        guard var state = stateFromCurrentSettings(now: now) else {
            publishError(NSLocalizedString("Basal rates, insulin sensitivities and carb ratios must be set up first.", comment: "Error when the therapy optimizer cannot read the current therapy settings"))
            return nil
        }
        if let previous = previous {
            state.windowDays = previous.windowDays
            state.summaries = previous.summaries
            state.overrideIntervals = previous.overrideIntervals
            state.lastProcessedDate = previous.lastProcessedDate
            state.mealCutoffDate = previous.mealCutoffDate
            state.hypoHoldUntil = previous.hypoHoldUntil
            state.unexplainedRiseSince = previous.unexplainedRiseSince
            state.recentCounteraction = previous.recentCounteraction
            state.recentGlucoseChange = previous.recentGlucoseChange
            state.openSensitivityEpisode = previous.openSensitivityEpisode
            state.openSensitivityEpisodesByGlucose = previous.openSensitivityEpisodesByGlucose
        } else {
            let start = backfillStart(for: state, now: now)
            state.lastProcessedDate = start
            state.mealCutoffDate = start
        }
        return state
    }

    /// A fresh state whose start values are the active therapy settings in U100.
    private func stateFromCurrentSettings(now: Date) -> TherapyOptimizerState? {
        guard let basal = doseStore?.basalProfile,
              let sensitivity = doseStore?.insulinSensitivitySchedule,
              let carbRatio = carbStore?.carbRatioSchedule else {
            return nil
        }
        let scale = InsulinConcentrationHistory.current.unitsPerPumpUnit
        let sensitivityMilligrams = sensitivity.items.map { item in
            RepeatingScheduleValue(startTime: item.startTime, value: HKQuantity(unit: sensitivity.unit, doubleValue: item.value).doubleValue(for: .milligramsPerDeciliter) / scale)
        }
        return TherapyOptimizerState(
            timeZone: basal.timeZone,
            basal: TherapyOptimizerMath.hourlyValues(basal.items).map { $0 * scale },
            sensitivity: TherapyOptimizerMath.hourlyValues(sensitivityMilligrams),
            carbRatio: TherapyOptimizerMath.hourlyValues(carbRatio.items).map { $0 / scale },
            sensitivityUnit: sensitivity.unit,
            processingStart: now
        )
    }

    private func backfillStart(for state: TherapyOptimizerState, now: Date) -> Date {
        let calendar = state.calendar
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -Self.backfillDays, to: now) ?? now)
    }

    private func runProcessing(now: Date, replay: Bool) {
        guard var state = workingState else { return }
        DispatchQueue.main.async {
            self.isProcessing = true
            self.lastError = nil
        }

        let end = now.addingTimeInterval(-Self.processingDelay)
        let calendar = state.calendar
        applyDueDailyUpdate(to: &state)
        while state.lastProcessedDate < end {
            let chunkStart = state.lastProcessedDate
            // Chunks end at midnight, so each daily update sees exactly the days before it, as in replay.
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: chunkStart)) ?? end
            let chunkEnd = min(end, nextDay)
            guard processChunk(from: chunkStart, to: chunkEnd, state: &state) else {
                break
            }
            state.lastProcessedDate = chunkEnd
            applyDueDailyUpdate(to: &state)
        }

        if replay {
            let rawDays = loadRawDays(calendar: state.calendar)
            TherapyOptimizerEngine.replay(&state, rawDays: rawDays, through: state.lastProcessedDate)
            log.default("Replayed %d stored days", rawDays.count)
        }
        TherapyOptimizerEngine.compactAndPrune(&state, now: now)
        if let pruneBefore = state.calendar.date(byAdding: .day, value: -TherapyOptimizerState.retainedDays, to: state.calendar.startOfDay(for: now)) {
            deleteStoredDays(before: pruneBefore, calendar: state.calendar)
        }

        workingState = state
        saveState()
        publish()
        publishStoredDays()
        DispatchQueue.main.async {
            self.isProcessing = false
        }
    }

    /// The update for a day runs once processing reaches that day.
    private func applyDueDailyUpdate(to state: inout TherapyOptimizerState) {
        let day = state.calendar.startOfDay(for: state.lastProcessedDate)
        guard (state.lastDailyUpdate ?? .distantPast) < day else { return }
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day)
        log.default("Daily update applied (window %d days)", state.windowDays)
    }

    private func record(_ overrides: [TemporaryScheduleOverride], in state: inout TherapyOptimizerState) {
        let now = Date()
        for override in overrides where override.actualEnd != .deleted {
            let interval = DateInterval(start: override.startDate, end: max(override.startDate, min(override.actualEndDate, now)))
            if let index = state.overrideIntervals.firstIndex(where: { $0.start == interval.start }) {
                state.overrideIntervals[index] = interval
            } else {
                state.overrideIntervals.append(interval)
            }
        }
    }

    private func processChunk(from start: Date, to end: Date, state: inout TherapyOptimizerState) -> Bool {
        guard let doseStore = doseStore, let glucoseStore = glucoseStore, let carbStore = carbStore,
              let basalSchedule = doseStore.basalProfile,
              let sensitivitySchedule = doseStore.insulinSensitivitySchedule else {
            log.error("Stores or schedules not available")
            return false
        }
        let lookbackStart = start.addingTimeInterval(-Self.lookback)
        let group = DispatchGroup()
        let failure = Locked<Error?>(nil)
        var samples: [StoredGlucoseSample] = []
        var insulinEffects: [GlucoseEffect] = []
        var doses: [DoseEntry] = []
        var netInsulinOnBoard: [InsulinValue] = []

        group.enter()
        glucoseStore.getGlucoseSamples(start: lookbackStart, end: end) { result in
            switch result {
            case .success(let values): samples = values
            case .failure(let error): failure.value = error
            }
            group.leave()
        }
        group.enter()
        doseStore.getGlucoseEffects(start: lookbackStart, end: end, basalDosingEnd: Date()) { result in
            switch result {
            case .success(let values): insulinEffects = values
            case .failure(let error): failure.value = error
            }
            group.leave()
        }
        group.enter()
        doseStore.getNormalizedDoseEntries(start: lookbackStart.addingTimeInterval(-doseStore.longestEffectDuration), end: end) { result in
            switch result {
            case .success(let values): doses = values
            case .failure(let error): failure.value = error
            }
            group.leave()
        }
        group.enter()
        doseStore.getInsulinOnBoardValues(start: lookbackStart, end: end, basalDosingEnd: Date()) { result in
            switch result {
            case .success(let values): netInsulinOnBoard = values
            case .failure(let error): failure.value = error
            }
            group.leave()
        }
        group.wait()

        let counteraction = glucoseStore.counteractionEffects(for: samples, to: insulinEffects)

        var carbsOnBoard: [CarbValue] = []
        var carbEntries: [(start: Date, grams: Double)] = []
        var storedCarbEntries: [StoredCarbEntry] = []
        group.enter()
        carbStore.getCarbsOnBoardValues(start: lookbackStart, end: end, effectVelocities: counteraction) { result in
            switch result {
            case .success(let values): carbsOnBoard = values
            case .failure(let error): failure.value = error
            }
            group.leave()
        }
        group.enter()
        carbStore.getCarbStatus(start: lookbackStart, end: end, effectVelocities: counteraction) { result in
            switch result {
            case .success(let statuses):
                carbEntries = statuses.map { (start: $0.startDate, grams: $0.quantity.doubleValue(for: .gram())) }
                storedCarbEntries = statuses.map { $0.entry }
            case .failure(let error): failure.value = error
            }
            group.leave()
        }
        group.wait()

        if let failure = failure.value {
            log.error("Fetching data for %{public}@ failed: %{public}@", String(describing: start), String(describing: failure))
            return false
        }

        let overrides = state.overrideIntervals
        // DoseStore reports all doses in the pump units of the insulin in use now, like the schedules.
        let scale = InsulinConcentrationHistory.current.unitsPerPumpUnit
        // Insulin effects are net of the basal each dose was annotated with, which can differ from today's schedule
        // after a profile or insulin change; the current schedule only fills gaps.
        let basalSegments = doses.compactMap { dose -> TherapyOptimizerBasalSegment? in
            guard dose.type != .bolus, dose.endDate > dose.startDate else { return nil }
            // Scheduled basal doses count as zero net insulin, so their own rate is the baseline.
            let annotatedRate: Double? = dose.type == .basal ? dose.unitsPerHour : dose.scheduledBasalRate?.doubleValue(for: DoseEntry.unitsPerHour)
            guard let rate = annotatedRate else { return nil }
            return TherapyOptimizerBasalSegment(start: dose.startDate, end: dose.endDate, rate: rate * scale)
        }
        let scheduledBasal: (Date) -> Double = { date in
            TherapyOptimizerBasalSegment.rate(at: date, in: basalSegments) ?? basalSchedule.value(at: date) * scale
        }

        let mgdl = HKUnit.milligramsPerDeciliter
        let velocityUnit = mgdl.unitDivided(by: .minute())
        let insulinEffectPoints = insulinEffects.map { ($0.startDate, $0.quantity.doubleValue(for: mgdl)) }

        let intervals: [TherapyOptimizerInterval] = counteraction.compactMap { (velocity: GlucoseEffectVelocity) -> TherapyOptimizerInterval? in
            guard velocity.startDate >= start, velocity.startDate < end,
                  let glucose = samples.last(where: { $0.startDate <= velocity.endDate })?.quantity.doubleValue(for: mgdl),
                  let effectStart = Self.interpolate(insulinEffectPoints, at: velocity.startDate),
                  let effectEnd = Self.interpolate(insulinEffectPoints, at: velocity.endDate) else {
                return nil
            }
            let minutes = velocity.endDate.timeIntervalSince(velocity.startDate) / 60
            guard minutes > 0 else { return nil }
            return TherapyOptimizerInterval(
                start: velocity.startDate,
                end: velocity.endDate,
                glucose: glucose,
                counteraction: velocity.quantity.doubleValue(for: velocityUnit),
                insulinVelocity: (effectEnd - effectStart) / minutes,
                carbsOnBoard: carbsOnBoard.last(where: { $0.startDate <= velocity.startDate })?.quantity.doubleValue(for: .gram()) ?? 0,
                sensitivity: HKQuantity(unit: sensitivitySchedule.unit, doubleValue: sensitivitySchedule.value(at: velocity.startDate)).doubleValue(for: mgdl) / scale,
                isSuspended: doses.contains { $0.type == .suspend && $0.startDate < velocity.endDate && $0.endDate > velocity.startDate },
                isOverrideActive: overrides.contains { $0.start < velocity.endDate && $0.end > velocity.startDate }
            )
        }
        TherapyOptimizerEngine.ingest(intervals, scheduledBasal: scheduledBasal, overrides: overrides, into: &state)

        let mealCutoff = state.mealCutoffDate
        let built = Self.buildMeals(
            entries: carbEntries.filter { $0.start >= mealCutoff && $0.start < end }.sorted { $0.start < $1.start },
            end: end,
            carbsOnBoard: carbsOnBoard.map { (date: $0.startDate, grams: $0.quantity.doubleValue(for: .gram())) },
            glucose: samples.map { (date: $0.startDate, value: $0.quantity.doubleValue(for: mgdl)) },
            doses: doses,
            netInsulinOnBoard: netInsulinOnBoard.map { (date: $0.startDate, units: $0.value) },
            scheduledBasal: scheduledBasal,
            unitScale: scale,
            overrides: overrides
        )
        let meals = built.meals
        state.mealCutoffDate = built.cutoff
        TherapyOptimizerEngine.ingest(meals, into: &state)

        let range = start..<end
        var source = TherapyOptimizerSourceDay(
            day: start,
            basalSchedule: basalSchedule.items.map { TherapyOptimizerScheduleItem(startTime: $0.startTime, value: $0.value * scale) },
            sensitivitySchedule: sensitivitySchedule.items.map { TherapyOptimizerScheduleItem(startTime: $0.startTime, value: HKQuantity(unit: sensitivitySchedule.unit, doubleValue: $0.value).doubleValue(for: mgdl) / scale) },
            carbRatioSchedule: (carbStore.carbRatioSchedule?.items ?? []).map { TherapyOptimizerScheduleItem(startTime: $0.startTime, value: $0.value / scale) }
        )
        source.glucose = samples.filter { range.contains($0.startDate) }
        // DoseStore reports history in current pump units; store U100 so later insulin changes can't mix units.
        source.doses = doses.filter { range.contains($0.startDate) }.map { $0.scaled(by: scale, includingScheduledBasalRate: true) }
        source.carbEntries = storedCarbEntries.filter { range.contains($0.startDate) }
        source.overrides = overrides
        storeDays(range, intervals: intervals, meals: meals, basalSegments: basalSegments, source: source, calendar: state.calendar)

        log.default("Processed %{public}@ – %{public}@: %d intervals, %d meals", String(describing: start), String(describing: end), intervals.count, meals.count)
        return true
    }

    static let mealMinimumDuration: TimeInterval = 3 * 3600
    static let mealMaximumDuration: TimeInterval = 10 * 3600
    static let mealEndMaximumCarbs = 0.5
    /// mg/dL within 15 minutes
    static let mealEndMaximumGlucoseChange = 10.0
    /// U100 units, either sign
    static let mealEndMaximumInsulinOnBoard = 1.0

    /// Groups carb entries into meal windows of at least 3 h that end once carbs are absorbed, glucose is stable and
    /// little insulin is left; meals that don't settle within 10 h are skipped. `cutoff` is where the next call resumes.
    static func buildMeals(
        entries: [(start: Date, grams: Double)],
        end: Date,
        carbsOnBoard: [(date: Date, grams: Double)],
        glucose: [(date: Date, value: Double)],
        doses: [DoseEntry],
        netInsulinOnBoard: [(date: Date, units: Double)],
        scheduledBasal: (Date) -> Double,
        unitScale: Double,
        overrides: [DateInterval]
    ) -> (meals: [TherapyOptimizerMeal], cutoff: Date) {
        let reading = { (date: Date) -> Double? in
            glucose.last { $0.date <= date && $0.date > date.addingTimeInterval(-10 * 60) }?.value
        }
        let averageGlucose = { (date: Date) -> Double? in
            let values = glucose.filter { $0.date <= date && $0.date > date.addingTimeInterval(-15 * 60) }.suffix(3).map { $0.value }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        // Strictly before the date, so a bolus at that date is counted once, as delivered.
        let insulinOnBoard = { (date: Date) -> Double in
            (netInsulinOnBoard.last { $0.date < date }?.units ?? 0) * unitScale
        }
        let isSettled = { (date: Date) -> Bool in
            let carbs = (carbsOnBoard.last?.date ?? .distantPast) < date ? 0 : (carbsOnBoard.last { $0.date <= date }?.grams ?? 0)
            guard carbs <= mealEndMaximumCarbs, abs(insulinOnBoard(date)) <= mealEndMaximumInsulinOnBoard,
                  let now = reading(date), let before = reading(date.addingTimeInterval(-15 * 60)) else {
                return false
            }
            return abs(now - before) <= mealEndMaximumGlucoseChange
        }

        var meals: [TherapyOptimizerMeal] = []
        var index = 0
        while index < entries.count {
            let mealStart = entries[index].start
            let latestEnd = mealStart.addingTimeInterval(mealMaximumDuration)
            var candidate = mealStart.addingTimeInterval(mealMinimumDuration)
            var settledAt: Date?
            while settledAt == nil, candidate <= min(end, latestEnd) {
                if isSettled(candidate) {
                    settledAt = candidate
                }
                candidate = candidate.addingTimeInterval(5 * 60)
            }
            guard let mealEnd = settledAt else {
                if end < latestEnd {
                    return (meals, mealStart)
                }
                index += entries[index...].prefix(while: { $0.start < latestEnd }).count
                continue
            }

            let grouped = entries[index...].prefix(while: { $0.start < mealEnd })
            index += grouped.count
            guard let glucoseStart = averageGlucose(mealStart), let glucoseEnd = averageGlucose(mealEnd) else {
                continue
            }

            let boluses = doses
                .filter { $0.type == .bolus && $0.startDate >= mealStart && $0.startDate < mealEnd }
                .reduce(0) { $0 + ($1.deliveredUnits ?? $1.programmedUnits) }
            let netBasal = netBasalUnits(doses, from: mealStart, to: mealEnd)
            let windowGlucose = glucose.filter { $0.date >= mealStart && $0.date <= mealEnd }.map { $0.value }

            meals.append(TherapyOptimizerMeal(
                start: mealStart,
                end: mealEnd,
                carbs: grouped.reduce(0) { $0 + $1.grams },
                netInsulin: (boluses + netBasal) * unitScale + insulinOnBoard(mealStart) - insulinOnBoard(mealEnd),
                scheduledBasalUnits: TherapyOptimizerMath.units(from: mealStart, to: mealEnd, rate: scheduledBasal),
                glucoseStart: glucoseStart,
                glucoseEnd: glucoseEnd,
                minimumGlucose: windowGlucose.min() ?? glucoseStart,
                isOverrideActive: TherapyOptimizerEngine.isAffected(by: overrides, from: mealStart, to: mealEnd),
                entryCount: grouped.count
            ))
        }
        return (meals, end)
    }

    /// Units delivered relative to the scheduled basal by temp basals and suspends in the range.
    private static func netBasalUnits(_ doses: [DoseEntry], from start: Date, to end: Date) -> Double {
        var units = 0.0
        for dose in doses where dose.type == .tempBasal || dose.type == .suspend {
            let overlap = min(dose.endDate, end).timeIntervalSince(max(dose.startDate, start))
            if overlap > 0 {
                units += dose.netBasalUnitsPerHour * overlap / 3600
            }
        }
        return units
    }

    private static func interpolate(_ points: [(Date, Double)], at date: Date) -> Double? {
        guard let upperIndex = points.firstIndex(where: { $0.0 >= date }) else { return nil }
        let upper = points[upperIndex]
        guard upperIndex > 0, upper.0 > date else { return upper.0 == date ? upper.1 : nil }
        let lower = points[upperIndex - 1]
        let fraction = date.timeIntervalSince(lower.0) / upper.0.timeIntervalSince(lower.0)
        return lower.1 + (upper.1 - lower.1) * fraction
    }

    // MARK: - Persistence & publishing

    private static var stateURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("TherapyOptimizer.json")
    }

    private static var disabledStateURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("TherapyOptimizer-off.json")
    }

    private func loadState(from url: URL = TherapyOptimizer.stateURL) -> TherapyOptimizerState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(TherapyOptimizerState.self, from: data)
        } catch {
            log.error("Discarding unreadable state: %{public}@", String(describing: error))
            return nil
        }
    }

    private func saveState() {
        guard let state = workingState else { return }
        save(state, to: Self.stateURL)
    }

    private func save(_ state: TherapyOptimizerState, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            log.error("Saving state failed: %{public}@", String(describing: error))
        }
    }

    private func publish() {
        let snapshot = workingState
        dosingState.value = snapshot
        DispatchQueue.main.async {
            self.state = snapshot
        }
    }

    // MARK: - Dosing

    /// Read from Loop's dosing queue, so kept apart from the main-thread `state`.
    let dosingState = Locked<TherapyOptimizerState?>(nil)

    /// Factor for the insulin sensitivity used in correction dosing at this glucose; nil without trustworthy data.
    func dosingSensitivityFactor(forGlucose milligramsPerDeciliter: Double, now: Date = Date()) -> Double? {
        dosingState.value.flatMap { TherapyOptimizerEngine.dosingSensitivityFactor(forGlucose: milligramsPerDeciliter, in: $0, now: now) }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.lastError = message
        }
    }

    // MARK: - Stored days: yyyy-MM-dd.json (derived input) and yyyy-MM-dd.source.json (Loop's records)

    private static var rawDirectoryURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("TherapyOptimizerDays", isDirectory: true)
    }

    private static let sourceSuffix = ".source.json"

    private func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func dayURL(_ day: Date, calendar: Calendar, source: Bool) -> URL {
        Self.rawDirectoryURL.appendingPathComponent(dayFormatter(calendar).string(from: day) + (source ? Self.sourceSuffix : ".json"))
    }

    private func storedFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.rawDirectoryURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private func load<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            log.error("Unreadable day %{public}@: %{public}@", url.lastPathComponent, String(describing: error))
            return nil
        }
    }

    private func loadRawDays(calendar: Calendar) -> [TherapyOptimizerRawDay] {
        storedFiles()
            .filter { !$0.lastPathComponent.hasSuffix(Self.sourceSuffix) }
            .compactMap { load(TherapyOptimizerRawDay.self, at: $0) }
            .sorted { $0.day < $1.day }
    }

    /// Records inside `range` are replaced, so reprocessing a range never duplicates and drops records deleted in Loop.
    private func storeDays(_ range: Range<Date>, intervals: [TherapyOptimizerInterval], meals: [TherapyOptimizerMeal], basalSegments: [TherapyOptimizerBasalSegment], source chunk: TherapyOptimizerSourceDay, calendar: Calendar) {
        var chunkDays: [Date] = []
        var day = calendar.startOfDay(for: range.lowerBound)
        while day < range.upperBound, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            chunkDays.append(day)
            day = next
        }
        // Meals can complete after the chunk their start belongs to.
        let mealOnlyDays = Set(meals.map { calendar.startOfDay(for: $0.start) }).subtracting(chunkDays)

        do {
            try FileManager.default.createDirectory(at: Self.rawDirectoryURL, withIntermediateDirectories: true)
            for day in chunkDays + mealOnlyDays.sorted() {
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
                let isInChunk = chunkDays.contains(day)
                let belongs = { (date: Date) in date >= day && date < dayEnd }

                let rawURL = dayURL(day, calendar: calendar, source: false)
                var raw = load(TherapyOptimizerRawDay.self, at: rawURL) ?? TherapyOptimizerRawDay(day: day, basalSchedule: chunk.basalSchedule)
                if isInChunk {
                    raw.basalSchedule = chunk.basalSchedule
                    // Back-attribution looks up to 3 h before the day.
                    let segmentStart = day.addingTimeInterval(-3 * 3600)
                    let segments = (raw.basalSegments ?? []) + basalSegments.filter { $0.end > segmentStart && $0.start < dayEnd }
                    raw.basalSegments = Dictionary(segments.map { ($0.start, $0) }, uniquingKeysWith: { $1 }).values.sorted { $0.start < $1.start }
                    raw.intervals = Self.replacing(raw.intervals, in: range, with: intervals.filter { belongs($0.start) }, date: \.start)
                    raw.meals = raw.meals.filter { !range.contains($0.start) }
                    let overrides = (raw.overrides ?? []) + chunk.overrides.filter { TherapyOptimizerEngine.isAffected(by: [$0], from: day, to: dayEnd) }
                    raw.overrides = Dictionary(overrides.map { ($0.start, $0) }, uniquingKeysWith: { $1 }).values.sorted { $0.start < $1.start }
                }
                let mealStarts = Set(meals.map { $0.start })
                raw.meals = (raw.meals.filter { !mealStarts.contains($0.start) } + meals.filter { belongs($0.start) }).sorted { $0.start < $1.start }
                try JSONEncoder().encode(raw).write(to: rawURL, options: .atomic)

                guard isInChunk else { continue }
                let sourceURL = dayURL(day, calendar: calendar, source: true)
                var source = load(TherapyOptimizerSourceDay.self, at: sourceURL) ?? TherapyOptimizerSourceDay(day: day, basalSchedule: [], sensitivitySchedule: [], carbRatioSchedule: [])
                source.basalSchedule = chunk.basalSchedule
                source.sensitivitySchedule = chunk.sensitivitySchedule
                source.carbRatioSchedule = chunk.carbRatioSchedule
                source.glucose = Self.replacing(source.glucose, in: range, with: chunk.glucose.filter { belongs($0.startDate) }, date: \.startDate)
                source.doses = Self.replacing(source.doses, in: range, with: chunk.doses.filter { belongs($0.startDate) }, date: \.startDate)
                source.carbEntries = Self.replacing(source.carbEntries, in: range, with: chunk.carbEntries.filter { belongs($0.startDate) }, date: \.startDate)
                // An override still running when first stored ends later; keep the latest version per start.
                source.overrides = Dictionary((source.overrides + chunk.overrides.filter { $0.start < dayEnd && $0.end > day }).map { ($0.start, $0) }, uniquingKeysWith: { $1 })
                    .values.sorted { $0.start < $1.start }
                try JSONEncoder().encode(source).write(to: sourceURL, options: .atomic)
            }
        } catch {
            log.error("Storing days failed: %{public}@", String(describing: error))
        }
    }

    private static func replacing<T>(_ existing: [T], in range: Range<Date>, with new: [T], date: KeyPath<T, Date>) -> [T] {
        (existing.filter { !range.contains($0[keyPath: date]) } + new).sorted { $0[keyPath: date] < $1[keyPath: date] }
    }

    private func deleteStoredDays(before day: Date, calendar: Calendar) {
        let cutoff = dayFormatter(calendar).string(from: day)
        // yyyy-MM-dd sorts like the date it names.
        for url in storedFiles() where String(url.lastPathComponent.prefix(10)) < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func publishStoredDays() {
        let count = Set(storedFiles().map { $0.lastPathComponent.prefix(10) }).count
        DispatchQueue.main.async {
            self.storedDays = count
        }
    }
}
