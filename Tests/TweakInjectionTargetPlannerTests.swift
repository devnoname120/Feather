import Foundation

@main
struct TweakInjectionTargetPlannerTests {
	static func main() throws {
		try testDiscoversWatchAppsAndDirectExtensions()
		try testBuildsExecutableAndExtensionLoadPaths()
	}

	private static func testDiscoversWatchAppsAndDirectExtensions() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("TweakInjectionTargetPlannerTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }

		let app = root.appendingPathComponent("Host.app")
		let watchApp = app.appendingPathComponent("Watch/WatchApp.app")
		let rootPlugin = app.appendingPathComponent("PlugIns/RootExtension.appex")
		let rootExtension = app.appendingPathComponent("Extensions/OtherExtension.appex")
		let watchPlugin = watchApp.appendingPathComponent("PlugIns/WatchExtension.appex")

		for url in [watchApp, rootPlugin, rootExtension, watchPlugin] {
			try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		}

		let planner = TweakInjectionTargetPlanner(
			injectPath: .executablePath,
			injectFolder: .frameworks
		)

		let watchApps = planner.watchApps(in: app).map(\.lastPathComponent)
		try assertEqual(watchApps, ["WatchApp.app"], "discovers embedded watch apps")

		let directExtensions = planner.directAppExtensions(in: app).map(\.lastPathComponent).sorted()
		try assertEqual(
			directExtensions,
			["OtherExtension.appex", "RootExtension.appex"],
			"discovers direct PlugIns and Extensions"
		)

		let watchExtensions = planner.directAppExtensions(in: watchApp).map(\.lastPathComponent)
		try assertEqual(watchExtensions, ["WatchExtension.appex"], "discovers watch app extensions")
	}

	private static func testBuildsExecutableAndExtensionLoadPaths() throws {
		let executablePathPlanner = TweakInjectionTargetPlanner(
			injectPath: .executablePath,
			injectFolder: .frameworks
		)

		try assertEqual(
			executablePathPlanner.loadPathForBundleExecutable(dylibName: "Hook.dylib"),
			"@executable_path/Frameworks/Hook.dylib",
			"host bundle executable loads from its own Frameworks directory"
		)
		try assertEqual(
			executablePathPlanner.loadPathForExtensionExecutable(dylibName: "Hook.dylib"),
			"@executable_path/../../Frameworks/Hook.dylib",
			"extension executable loads from its containing bundle Frameworks directory"
		)

		let rpathPlanner = TweakInjectionTargetPlanner(
			injectPath: .rpath,
			injectFolder: .frameworks
		)
		try assertEqual(
			rpathPlanner.loadPathForBundleExecutable(dylibName: "Hook.dylib"),
			"@rpath/Hook.dylib",
			"rpath host load path ignores install folder"
		)
		try assertEqual(
			rpathPlanner.loadPathForExtensionExecutable(dylibName: "Hook.dylib"),
			"@rpath/Hook.dylib",
			"rpath extension load path ignores install folder"
		)
	}
}

private func assertEqual<T: Equatable>(
	_ actual: T,
	_ expected: T,
	_ message: String,
) throws {
	if actual != expected {
		throw TestFailure(message: "\(message): expected \(expected), got \(actual)")
	}
}

private struct TestFailure: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}
