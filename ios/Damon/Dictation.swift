import AVFoundation
import Speech
import SwiftUI

/// Live dictation into the composer with Apple's speech recognizer. Prefers
/// on-device recognition: audio stays on the phone and there is no one-minute cap.
@MainActor
final class Dictation: ObservableObject {
	@Published private(set) var isRecording = false
	@Published var error: String?

	private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
	private let engine = AVAudioEngine()
	private var request: SFSpeechAudioBufferRecognitionRequest?
	private var task: SFSpeechRecognitionTask?
	// After a pause the recognizer starts a new segment and its transcript
	// restarts from empty. Keep what was said before that so it isn't lost.
	private var committed = ""
	private var current = ""
	private var currentStart: TimeInterval = 0
	// Bumped on cancel so late callbacks from an abandoned recognition are ignored.
	private var generation = 0

	/// Starts listening. `onText` receives the whole transcript so far, each time it changes.
	func start(onText: @escaping (String) -> Void) async {
		guard !isRecording else { return }
		committed = ""
		current = ""
		currentStart = 0
		let speech = await withCheckedContinuation { cont in
			SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
		}
		guard speech == .authorized else { error = "Allow Speech Recognition for Damon in Settings."; return }
		guard await AVAudioApplication.requestRecordPermission() else { error = "Allow the microphone for Damon in Settings."; return }
		guard let recognizer, recognizer.isAvailable else { error = "Dictation isn't available right now."; return }

		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.record, mode: .measurement, options: .duckOthers)
			try session.setActive(true, options: .notifyOthersOnDeactivation)

			let request = SFSpeechAudioBufferRecognitionRequest()
			request.shouldReportPartialResults = true
			request.addsPunctuation = true
			if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
			self.request = request

			let input = engine.inputNode
			input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
				request.append(buffer)
			}
			engine.prepare()
			try engine.start()
			isRecording = true
			UIImpactFeedbackGenerator(style: .medium).impactOccurred()

			generation += 1
			let mine = generation
			task = recognizer.recognitionTask(with: request) { [weak self] result, err in
				Task { @MainActor in
					guard let self, self.generation == mine else { return }
					if let result { onText(self.merge(result)) }
					if err != nil || result?.isFinal == true { self.teardown() }
				}
			}
		} catch {
			self.error = "Couldn't start the mic: \(error.localizedDescription)"
			teardown()
		}
	}

	/// The full dictation so far: earlier segments plus the one in progress.
	private func merge(_ result: SFSpeechRecognitionResult) -> String {
		let text = result.bestTranscription.formattedString
		let start = result.bestTranscription.segments.first?.timestamp ?? 0
		if !current.isEmpty, isNewSegment(text, start: start) {
			committed = join(committed, current)
		}
		current = text
		currentStart = start
		if result.isFinal {
			committed = join(committed, current)
			current = ""
		}
		return join(committed, current)
	}

	private func isNewSegment(_ text: String, start: TimeInterval) -> Bool {
		// Segment timestamps jump forward when a new utterance begins.
		if start > 0, currentStart >= 0, start > currentStart + 0.3 { return true }
		// Partial results can lack timestamps; fall back to the text. Revisions keep
		// the opening words; a restart begins somewhere else and is much shorter.
		let first = text.split(separator: " ").first.map { String($0).lowercased() } ?? ""
		let keepsOpening = !first.isEmpty && current.lowercased().hasPrefix(first)
		return text.count < current.count / 2 && !keepsOpening
	}

	private func join(_ a: String, _ b: String) -> String {
		let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
		return a.isEmpty ? b : b.isEmpty ? a : "\(a) \(b)"
	}

	/// Stops listening; the recognizer delivers its final text before tearing down.
	func stop() {
		guard isRecording else { return }
		engine.stop()
		engine.inputNode.removeTap(onBus: 0)
		request?.endAudio()
		isRecording = false
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
	}

	/// Stops and throws the result away: used when the message is sent, so the
	/// recognizer's late final result can't refill the cleared composer.
	func cancel() {
		generation += 1
		task?.cancel()
		if isRecording { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
		teardown()
	}

	private func teardown() {
		if engine.isRunning {
			engine.stop()
			engine.inputNode.removeTap(onBus: 0)
		}
		request = nil
		task = nil
		isRecording = false
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
	}
}

/// Mic button: pulses red while listening.
struct MicButton: View {
	@ObservedObject var dictation: Dictation
	let action: () -> Void
	@State private var pulse = false

	var body: some View {
		Button(action: action) {
			ZStack {
				if dictation.isRecording {
					Circle().fill(Theme.permission.opacity(0.18))
						.scaleEffect(pulse ? 1.25 : 0.9)
						.animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
				}
				Image(systemName: dictation.isRecording ? "stop.fill" : "mic")
					.font(.system(size: dictation.isRecording ? 13 : 17, weight: .medium))
					.foregroundStyle(dictation.isRecording ? Theme.permission : Theme.muted)
			}
			.frame(width: 36, height: 36)
		}
		.accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
		.onChange(of: dictation.isRecording) { _, on in pulse = on }
	}
}
