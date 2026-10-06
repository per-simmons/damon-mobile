import SwiftUI

@main
struct DamonApp: App {
	@StateObject private var store = Store()
	@State private var path: [Route] = []
	@Environment(\.scenePhase) private var scenePhase

	init() {
		TouchIndicator.enableIfRequested()
	}

	var body: some Scene {
		WindowGroup {
			NavigationStack(path: $path) {
				SidebarView(path: $path)
					.navigationDestination(for: Route.self) { route in
						ChatView(route: route, store: store)
					}
			}
			.tint(Theme.accent)
			.environmentObject(store)
			.task {
				await store.loadTree()
				store.connect()
			}
			.onChange(of: scenePhase) { _, phase in
				guard phase == .active else { return }
				// iOS drops sockets in the background; catch up on return.
				store.reconnect()
				Task {
					await store.loadTree()
					if let chat = store.activeChat { await chat.load() }
				}
			}
			.overlay(alignment: .bottom) {
				if let error = store.loadError, !store.rails.isEmpty {
					Text(error)
						.font(.system(size: 14))
						.foregroundStyle(Theme.bg)
						.padding(.horizontal, 16).padding(.vertical, 10)
						.background(Theme.text, in: Capsule())
						.padding(.bottom, 90)
						.onTapGesture { store.loadError = nil }
						.task {
							try? await Task.sleep(for: .seconds(3))
							store.loadError = nil
						}
				}
			}
		}
	}
}
