//
//  TweakInjectionTargetPlanner.swift
//  Feather
//

import Foundation

struct TweakInjectionTargetPlanner {
	enum InjectPath: String {
		case executablePath = "@executable_path"
		case rpath = "@rpath"
	}

	enum InjectFolder: String {
		case root = "/"
		case frameworks = "/Frameworks/"
	}

	let injectPath: InjectPath
	let injectFolder: InjectFolder

	func dylibDestination(in bundleURL: URL, dylibName: String) -> URL {
		switch injectFolder {
		case .root:
			bundleURL.appendingPathComponent(dylibName)
		case .frameworks:
			bundleURL
				.appendingPathComponent("Frameworks")
				.appendingPathComponent(dylibName)
		}
	}

	func loadPathForBundleExecutable(dylibName: String) -> String {
		if injectPath == .rpath {
			return "@rpath/\(dylibName)"
		}

		return "\(injectPath.rawValue)\(injectFolder.rawValue)\(dylibName)"
	}

	func loadPathForExtensionExecutable(dylibName: String) -> String {
		if injectPath == .rpath {
			return "@rpath/\(dylibName)"
		}

		switch injectFolder {
		case .root:
			return "@executable_path/../../\(dylibName)"
		case .frameworks:
			return "@executable_path/../../Frameworks/\(dylibName)"
		}
	}

	func directAppExtensions(in bundleURL: URL, fileManager: FileManager = .default) -> [URL] {
		["PlugIns", "Extensions"].flatMap {
			bundleDirectories(
				in: bundleURL.appendingPathComponent($0),
				pathExtension: "appex",
				fileManager: fileManager
			)
		}
	}

	func watchApps(in appURL: URL, fileManager: FileManager = .default) -> [URL] {
		bundleDirectories(
			in: appURL.appendingPathComponent("Watch"),
			pathExtension: "app",
			fileManager: fileManager
		)
	}

	private func bundleDirectories(
		in directory: URL,
		pathExtension: String,
		fileManager: FileManager
	) -> [URL] {
		guard
			let contents = try? fileManager.contentsOfDirectory(
				at: directory,
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)
		else {
			return []
		}

		return contents
			.filter { url in
				guard url.pathExtension.lowercased() == pathExtension else {
					return false
				}

				let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
				return values?.isDirectory == true
			}
			.sorted { $0.path < $1.path }
	}
}
