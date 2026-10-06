import SwiftUI
import UIKit

/// Busts and rail logos are reused on every screen; AsyncImage refetches them
/// each time a row scrolls back into view, which hitches scrolling. Load once.
@MainActor
final class ImageCache {
	static let shared = ImageCache()
	private let cache = NSCache<NSURL, UIImage>()
	private var inflight: [URL: Task<UIImage?, Never>] = [:]

	func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

	func load(_ url: URL) async -> UIImage? {
		if let hit = cached(url) { return hit }
		if let task = inflight[url] { return await task.value }
		let task = Task<UIImage?, Never> {
			guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return nil }
			// Decode off the scroll path.
			return await image.byPreparingForDisplay() ?? image
		}
		inflight[url] = task
		let image = await task.value
		inflight[url] = nil
		if let image { cache.setObject(image, forKey: url as NSURL) }
		return image
	}
}

struct CachedImage<Placeholder: View>: View {
	let url: URL
	@ViewBuilder let placeholder: () -> Placeholder
	@State private var image: UIImage?

	init(url: URL, @ViewBuilder placeholder: @escaping () -> Placeholder) {
		self.url = url
		self.placeholder = placeholder
		_image = State(initialValue: ImageCache.shared.cached(url))
	}

	var body: some View {
		Group {
			if let image { Image(uiImage: image).resizable().scaledToFill() } else { placeholder() }
		}
		.task(id: url) { if image == nil { image = await ImageCache.shared.load(url) } }
	}
}
