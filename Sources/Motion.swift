import SwiftUI
import UIKit

// All tunable motion values live here. Navigation, sheet transitions and native
// scroll rubber-banding use UIKit's system timing; no guessed push duration.
enum MotionCurve: String, Codable, CaseIterable, Identifiable {
    case easeOut, easeInOut, linear
    var id: String { rawValue }
    var title: String {
        switch self { case .easeOut: "減速"; case .easeInOut: "加速・減速"; case .linear: "等速" }
    }
    func animation(seconds: Double) -> Animation {
        switch self {
        case .easeOut: .easeOut(duration: seconds)
        case .easeInOut: .easeInOut(duration: seconds)
        case .linear: .linear(duration: seconds)
        }
    }
}

// How much of the screen the drawer covers once it has slid in. The stored
// name stays `drawerHeight` so a phone that already has a preference keeps it;
// the drawer used to be a sheet, and the sheet's height is now a panel's width.
// The web drawer is 85% of the screen and never wider than 320 px; a panel
// past that reads as a second screen rather than a drawer, so the phone caps
// its width the same way.
enum DrawerHeight: String, Codable, CaseIterable, Identifiable {
    case medium, large
    var id: String { rawValue }
    var title: String { self == .large ? "広い" : "狭い" }
    var widthFraction: Double { self == .large ? 0.85 : 0.72 }
    var maxWidth: Double { self == .large ? 320 : 272 }
    func width(for screen: CGFloat) -> CGFloat {
        min(screen * widthFraction, maxWidth).rounded()
    }
}

enum Motion {
    static let rowSeconds = 0.25
    static let rowCurve = MotionCurve.easeOut
    static let refreshThreshold = 72.0
    static let refreshReturnSeconds = 0.25
    static let refreshReturnCurve = MotionCurve.easeOut
    static let waitingImpactIntensity = 0.6
    static let waitingImpactStyle = UIImpactFeedbackGenerator.FeedbackStyle.light
    static let rowSelectionEnabled = true
    static let waitingImpactEnabled = true
    static let drawerHeight = DrawerHeight.large
    // The strip along the left edge that answers a pull, matching the web's 24 px.
    static let drawerEdge = 24.0
    static let drawerScrim = 0.45
    // How far the app moves aside for the drawer, as a share of the drawer's
    // width. The web leaves the app still; Slack pushes it the whole way. A
    // quarter keeps the depth cue without the whole screen travelling.
    static let drawerPush = 0.25
    // The drawer's own slide; the web settles in 180 ms with an ease-out.
    static let drawerSeconds = 0.22
    static let secondsRange = 0.0...1.0
    static let secondsStep = 0.05
    static let thresholdRange = 48.0...160.0
    static let thresholdStep = 8.0
    static let intensityRange = 0.0...1.0
    static let intensityStep = 0.1
    static let pullDeadZone = 1.0
    static let indicatorTravel = 24.0
    static let indicatorInset = 8.0
    static let indicatorSize = 32.0
    static let talkEventSeconds = 0.18
    static let talkEventRise = 8.0
    static let talkToolSeconds = 0.25
    static let talkFollowSeconds = 0.30
    static let talkThinkingPeriod = 1.2
    static let talkSendHaptic = true
    static let talkDeliveredHaptic = true
    static let talkFailureHaptic = true
    static let talkQuestionHaptic = true
    static let talkReplyHaptic = true
    static let talkThinkingRange = 0.2...3.0
    static let talkRiseRange = 0.0...24.0
    static let defaultsKey = "pocket.motion.v1"
}

struct MotionValues: Codable, Equatable {
    var rowSeconds = Motion.rowSeconds
    var rowCurve = Motion.rowCurve
    var refreshThreshold = Motion.refreshThreshold
    var refreshReturnSeconds = Motion.refreshReturnSeconds
    var refreshReturnCurve = Motion.refreshReturnCurve
    var rowSelectionEnabled = Motion.rowSelectionEnabled
    var waitingImpactEnabled = Motion.waitingImpactEnabled
    var waitingImpactIntensity = Motion.waitingImpactIntensity
    var drawerHeight = Motion.drawerHeight

    var talkEventSeconds = Motion.talkEventSeconds
    var talkEventRise = Motion.talkEventRise
    var talkToolSeconds = Motion.talkToolSeconds
    var talkFollowSeconds = Motion.talkFollowSeconds
    var talkThinkingPeriod = Motion.talkThinkingPeriod
    var talkSendHaptic = Motion.talkSendHaptic
    var talkDeliveredHaptic = Motion.talkDeliveredHaptic
    var talkFailureHaptic = Motion.talkFailureHaptic
    var talkQuestionHaptic = Motion.talkQuestionHaptic
    var talkReplyHaptic = Motion.talkReplyHaptic

    init() {}
    // Missing shipment 6 keys retain their defaults; shipment 3 preferences survive.
    private enum CodingKeys: String, CodingKey {
        case rowSeconds, rowCurve, refreshThreshold, refreshReturnSeconds, refreshReturnCurve, rowSelectionEnabled, waitingImpactEnabled, waitingImpactIntensity, drawerHeight, talkEventSeconds, talkEventRise, talkToolSeconds, talkFollowSeconds, talkThinkingPeriod, talkSendHaptic, talkDeliveredHaptic, talkFailureHaptic, talkQuestionHaptic, talkReplyHaptic
    }
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        rowSeconds = try saved.decodeIfPresent(Double.self, forKey: .rowSeconds) ?? Motion.rowSeconds
        rowCurve = try saved.decodeIfPresent(MotionCurve.self, forKey: .rowCurve) ?? Motion.rowCurve
        refreshThreshold = try saved.decodeIfPresent(Double.self, forKey: .refreshThreshold) ?? Motion.refreshThreshold
        refreshReturnSeconds = try saved.decodeIfPresent(Double.self, forKey: .refreshReturnSeconds) ?? Motion.refreshReturnSeconds
        refreshReturnCurve = try saved.decodeIfPresent(MotionCurve.self, forKey: .refreshReturnCurve) ?? Motion.refreshReturnCurve
        rowSelectionEnabled = try saved.decodeIfPresent(Bool.self, forKey: .rowSelectionEnabled) ?? Motion.rowSelectionEnabled
        waitingImpactEnabled = try saved.decodeIfPresent(Bool.self, forKey: .waitingImpactEnabled) ?? Motion.waitingImpactEnabled
        waitingImpactIntensity = try saved.decodeIfPresent(Double.self, forKey: .waitingImpactIntensity) ?? Motion.waitingImpactIntensity
        drawerHeight = try saved.decodeIfPresent(DrawerHeight.self, forKey: .drawerHeight) ?? Motion.drawerHeight
        talkEventSeconds = try saved.decodeIfPresent(Double.self, forKey: .talkEventSeconds) ?? Motion.talkEventSeconds
        talkEventRise = try saved.decodeIfPresent(Double.self, forKey: .talkEventRise) ?? Motion.talkEventRise
        talkToolSeconds = try saved.decodeIfPresent(Double.self, forKey: .talkToolSeconds) ?? Motion.talkToolSeconds
        talkFollowSeconds = try saved.decodeIfPresent(Double.self, forKey: .talkFollowSeconds) ?? Motion.talkFollowSeconds
        talkThinkingPeriod = try saved.decodeIfPresent(Double.self, forKey: .talkThinkingPeriod) ?? Motion.talkThinkingPeriod
        talkSendHaptic = try saved.decodeIfPresent(Bool.self, forKey: .talkSendHaptic) ?? Motion.talkSendHaptic
        talkDeliveredHaptic = try saved.decodeIfPresent(Bool.self, forKey: .talkDeliveredHaptic) ?? Motion.talkDeliveredHaptic
        talkFailureHaptic = try saved.decodeIfPresent(Bool.self, forKey: .talkFailureHaptic) ?? Motion.talkFailureHaptic
        talkQuestionHaptic = try saved.decodeIfPresent(Bool.self, forKey: .talkQuestionHaptic) ?? Motion.talkQuestionHaptic
        talkReplyHaptic = try saved.decodeIfPresent(Bool.self, forKey: .talkReplyHaptic) ?? Motion.talkReplyHaptic
    }

    mutating func clamp() {
        talkEventSeconds = min(max(talkEventSeconds.isFinite ? talkEventSeconds : Motion.talkEventSeconds, Motion.secondsRange.lowerBound), Motion.secondsRange.upperBound)
        talkToolSeconds = min(max(talkToolSeconds.isFinite ? talkToolSeconds : Motion.talkToolSeconds, Motion.secondsRange.lowerBound), Motion.secondsRange.upperBound)
        talkFollowSeconds = min(max(talkFollowSeconds.isFinite ? talkFollowSeconds : Motion.talkFollowSeconds, Motion.secondsRange.lowerBound), Motion.secondsRange.upperBound)
        talkThinkingPeriod = min(max(talkThinkingPeriod.isFinite ? talkThinkingPeriod : Motion.talkThinkingPeriod, Motion.talkThinkingRange.lowerBound), Motion.talkThinkingRange.upperBound)
        talkEventRise = min(max(talkEventRise.isFinite ? talkEventRise : Motion.talkEventRise, Motion.talkRiseRange.lowerBound), Motion.talkRiseRange.upperBound)
        rowSeconds = min(max(rowSeconds.isFinite ? rowSeconds : Motion.rowSeconds, Motion.secondsRange.lowerBound), Motion.secondsRange.upperBound)
        refreshReturnSeconds = min(max(refreshReturnSeconds.isFinite ? refreshReturnSeconds : Motion.refreshReturnSeconds, Motion.secondsRange.lowerBound), Motion.secondsRange.upperBound)
        refreshThreshold = min(max(refreshThreshold.isFinite ? refreshThreshold : Motion.refreshThreshold, Motion.thresholdRange.lowerBound), Motion.thresholdRange.upperBound)
        waitingImpactIntensity = min(max(waitingImpactIntensity.isFinite ? waitingImpactIntensity : Motion.waitingImpactIntensity, Motion.intensityRange.lowerBound), Motion.intensityRange.upperBound)
    }
}

@MainActor @Observable final class MotionSettings {
    var values: MotionValues { didSet { persist() } }
    var reduceMotion = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var saved = defaults.data(forKey: Motion.defaultsKey)
            .flatMap { try? JSONDecoder().decode(MotionValues.self, from: $0) } ?? MotionValues()
        saved.clamp()
        values = saved
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Motion.defaultsKey) }
    }
    func reset() { values = MotionValues() }
    var rowAnimation: Animation? {
        reduceMotion || values.rowSeconds == 0 ? nil : values.rowCurve.animation(seconds: values.rowSeconds)
    }
    var refreshReturnAnimation: Animation? {
        reduceMotion || values.refreshReturnSeconds == 0 ? nil : values.refreshReturnCurve.animation(seconds: values.refreshReturnSeconds)
    }
    // The drawer's slide is not the row toggle; it has its own, fixed timing.
    var drawerAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: Motion.drawerSeconds) }
    func openRow() {
        guard !reduceMotion, values.rowSelectionEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func waitingIncreased() {
        guard !reduceMotion, values.waitingImpactEnabled else { return }
        UIImpactFeedbackGenerator(style: Motion.waitingImpactStyle)
            .impactOccurred(intensity: values.waitingImpactIntensity)
    }
    var talkEventAnimation: Animation? { reduceMotion || values.talkEventSeconds == 0 ? nil : .easeOut(duration: values.talkEventSeconds) }
    var talkToolAnimation: Animation? { reduceMotion || values.talkToolSeconds == 0 ? nil : .easeInOut(duration: values.talkToolSeconds) }
    var talkFollowAnimation: Animation? { reduceMotion || values.talkFollowSeconds == 0 ? nil : .easeOut(duration: values.talkFollowSeconds) }
    var talkInsertion: AnyTransition {
        reduceMotion || values.talkEventSeconds == 0 ? .identity : .opacity.combined(with: .offset(y: values.talkEventRise))
    }
    func talkSend() { if !reduceMotion && values.talkSendHaptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    func talkDelivered() { if !reduceMotion && values.talkDeliveredHaptic { UISelectionFeedbackGenerator().selectionChanged() } }
    func talkFailed() { if !reduceMotion && values.talkFailureHaptic { UINotificationFeedbackGenerator().notificationOccurred(.error) } }
    func talkQuestion() { if !reduceMotion && values.talkQuestionHaptic { UINotificationFeedbackGenerator().notificationOccurred(.warning) } }
    // CC Pocket taps three ways on what arrives: approval heavy, question
    // medium, turn finished light. The first two are the question haptic above;
    // this is the light one, for the answer landing while the phone is pocketed.
    func talkReplied() { if !reduceMotion && values.talkReplyHaptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    // Refresh completion intentionally has no haptic.
}

struct MotionSection: View {
    @Bindable var motion: MotionSettings
    var body: some View {
        Section {
            LabeledContent("画面の移動", value: "iOS 標準")
            Picker("引き出しの幅", selection: $motion.values.drawerHeight) {
                ForEach(DrawerHeight.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("motion.drawerWidth")
            Stepper(value: $motion.values.rowSeconds, in: Motion.secondsRange, step: Motion.secondsStep) {
                LabeledContent("行・件数の切替", value: seconds(motion.values.rowSeconds))
            }.accessibilityIdentifier("motion.rowSeconds")
            Picker("行・件数の曲線", selection: $motion.values.rowCurve) {
                ForEach(MotionCurve.allCases) { Text($0.title).tag($0) }
            }
            Stepper(value: $motion.values.refreshThreshold, in: Motion.thresholdRange, step: Motion.thresholdStep) {
                LabeledContent("引っ張る距離", value: "\(Int(motion.values.refreshThreshold)) pt")
            }.accessibilityIdentifier("motion.threshold")
            Stepper(value: $motion.values.refreshReturnSeconds, in: Motion.secondsRange, step: Motion.secondsStep) {
                LabeledContent("更新表示の戻り", value: seconds(motion.values.refreshReturnSeconds))
            }
            Picker("更新表示の曲線", selection: $motion.values.refreshReturnCurve) {
                ForEach(MotionCurve.allCases) { Text($0.title).tag($0) }
            }
            Toggle("行を開く振動", isOn: $motion.values.rowSelectionEnabled)
            Toggle("返事待ちが増えたときの振動", isOn: $motion.values.waitingImpactEnabled)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("軽い振動の強さ", value: String(format: "%.1f", motion.values.waitingImpactIntensity))
                Slider(value: $motion.values.waitingImpactIntensity, in: Motion.intensityRange, step: Motion.intensityStep)
                    .accessibilityLabel("軽い振動の強さ")
            }
            Text("トーク").font(.subheadline.weight(.semibold)).accessibilityIdentifier("motion.talk.heading")
            Stepper(value: $motion.values.talkEventSeconds, in: Motion.secondsRange, step: 0.01) {
                LabeledContent("出来事の追加", value: seconds(motion.values.talkEventSeconds))
            }.accessibilityIdentifier("motion.talkEventSeconds")
            Stepper(value: $motion.values.talkToolSeconds, in: Motion.secondsRange, step: 0.05) {
                LabeledContent("ツール開閉", value: seconds(motion.values.talkToolSeconds))
            }.accessibilityIdentifier("motion.talkToolSeconds")
            Stepper(value: $motion.values.talkFollowSeconds, in: Motion.secondsRange, step: 0.05) {
                LabeledContent("追従", value: seconds(motion.values.talkFollowSeconds))
            }.accessibilityIdentifier("motion.talkFollowSeconds")
            Stepper(value: $motion.values.talkThinkingPeriod, in: Motion.talkThinkingRange, step: 0.1) {
                LabeledContent("考え中", value: seconds(motion.values.talkThinkingPeriod))
            }.accessibilityIdentifier("motion.talkThinkingPeriod")
            Stepper(value: $motion.values.talkEventRise, in: Motion.talkRiseRange, step: 1) {
                LabeledContent("出来事の移動量", value: "\(Int(motion.values.talkEventRise)) pt")
            }.accessibilityIdentifier("motion.talkEventRise")
            Toggle("送信時の振動", isOn: $motion.values.talkSendHaptic)
            Toggle("送達時の振動", isOn: $motion.values.talkDeliveredHaptic)
            Toggle("失敗時の振動", isOn: $motion.values.talkFailureHaptic)
            Toggle("質問時の振動", isOn: $motion.values.talkQuestionHaptic)
            Toggle("返事が来た時の振動", isOn: $motion.values.talkReplyHaptic)
            Button("既定に戻す") { motion.reset() }.accessibilityIdentifier("motion.reset")
            if motion.reduceMotion {
                Text("視差効果を減らす：オン。動きと振動を省略します。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("動き").accessibilityIdentifier("motion.heading")
        } footer: {
            Text("画面の移動・シートの出入り・スクロールの反動は iOS 標準です。更新完了の振動はありません。")
        }
        .font(.subheadline)
    }
    private func seconds(_ value: Double) -> String { String(format: "%.2f 秒", value) }
}

// Public SwiftUI scroll observations keep List's delegate and native scrolling
// intact. The threshold and the indicator's return are tunable; rubber-banding
// remains native. No list identity, scrollTo, or content offset is reset.
struct PocketPullRefresh: ViewModifier {
    let motion: MotionSettings
    let refresh: () async -> Void
    @State private var distance = 0.0
    @State private var pulling = false
    @State private var armed = false
    @State private var refreshing = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Double.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, value in
                distance = value
                if pulling && !refreshing {
                    armed = value >= motion.values.refreshThreshold
                    visible = value > Motion.pullDeadZone
                }
            }
            .onScrollPhaseChange { old, new in
                pulling = new == .tracking || new == .interacting
                if (old == .interacting || old == .tracking) && new != .interacting && new != .tracking {
                    if armed && !refreshing {
                        refreshing = true
                        Task {
                            await refresh()
                            refreshing = false
                            armed = false
                            withAnimation(motion.refreshReturnAnimation) { visible = false }
                        }
                    } else {
                        withAnimation(motion.refreshReturnAnimation) { visible = false }
                    }
                }
            }
            .overlay(alignment: .top) {
                if visible || refreshing {
                    Group {
                        if refreshing { ProgressView() }
                        else {
                            Image(systemName: armed ? "arrow.clockwise" : "arrow.down")
                                .font(.subheadline)
                        }
                    }
                    .frame(width: Motion.indicatorSize, height: Motion.indicatorSize)
                    .background(.regularMaterial, in: Circle())
                    .padding(.top, Motion.indicatorInset)
                    .offset(y: motion.reduceMotion ? 0 : min(distance, Motion.indicatorTravel))
                    .transition(motion.reduceMotion ? .identity : .opacity)
                    .accessibilityLabel(refreshing ? "更新中" : armed ? "離して更新" : "引っ張って更新")
                    .allowsHitTesting(false)
                }
            }
    }
}
