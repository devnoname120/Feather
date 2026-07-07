//
//  DylibHandler.swift
//  feather
//
//  Created by samara on 8/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import ZsignSwift
import OSLog

class TweakHandler {
	private let _fileManager = FileManager.default
	private var _urlsToInject: [URL] = []
	private var _directoriesToCheck: [URL] = []
	private var _injectedDylibs: [InjectedDylib] = []

	private let _app: URL
	private var _options: Options
	private var _urls: [URL]

	private var _targetPlanner: TweakInjectionTargetPlanner {
		TweakInjectionTargetPlanner(
			injectPath: .init(rawValue: _options.injectPath.rawValue) ?? .executablePath,
			injectFolder: .init(rawValue: _options.injectFolder.rawValue) ?? .frameworks
		)
	}

	init(
		app: URL,
		options: Options = OptionsManager.shared.options
	) {
		self._app = app
		self._options = options
		self._urls = options.injectionFiles
	}
	
	private func _checkEllekit() async throws {
		let frameworksPath = _app.appendingPathComponent("Frameworks").appendingPathComponent("CydiaSubstrate.framework")

		func addEllekit() async throws {
			if let ellekitURL = Bundle.main.url(forResource: "ellekit", withExtension: "deb") {
				self._urls.insert(ellekitURL, at: 0)
			} else {
				Logger.misc.info("ellekit.deb not found in the app bundle")
			}
			
			try _fileManager.createDirectoryIfNeeded(at: _app.appendingPathComponent("Frameworks"))
		}
		// we should check if CydiaSubstrate.framework exists, if it doesn't
		// just add ellekit
		// experiment_replaceSubstrateWithEllekit:
		// 	for this version, we need to replace CydiaSubstrate.framework with
		//	our own version containing ElleKit
		// other:
		// 	just return if it exists, should work fine
		if _fileManager.fileExists(atPath: frameworksPath.path) {
			if _options.experiment_replaceSubstrateWithEllekit {
				Logger.misc.info("Attempting to replace Substrate with ElleKit")
				try _fileManager.removeFileIfNeeded(at: frameworksPath)
				try await addEllekit()
			} else {
				return
			}
		} else {
			guard !_urls.isEmpty else { return }
			try await addEllekit()
		}
	}

	public func getInputFiles() async throws {
		Logger.misc.info("Attempting to inject")
		
		if !_options.experiment_replaceSubstrateWithEllekit {
			guard !_urls.isEmpty else { return }
		}

		try await _checkEllekit()

		let baseTmpDir = _fileManager.temporaryDirectory.appendingPathComponent("FeatherTweak_\(UUID().uuidString)")
		try _fileManager.createDirectoryIfNeeded(at: baseTmpDir)
		
		// check for appropriate files, if theres debs
		// it will extract then add a url, if theres no url, i.e.
		// you haven't added a deb, it will skip
		for url in _urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "deb":
				try await _handleDeb(at: url, baseTmpDir: baseTmpDir)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
		
		// check contents of data.tar's extracted from debs
		if !_directoriesToCheck.isEmpty {
			try await _handleDirectories(at: _directoriesToCheck)
			if !_urlsToInject.isEmpty {
				try await _handleExtractedDirectoryContents(at: _urlsToInject)
			}
		}

		// inject into all extensions if enabled
		if _options.injectIntoExtensions && !_injectedDylibs.isEmpty {
			_injectIntoAllExtensions(dylibs: _injectedDylibs)
		}
	}
	
	// finally, handle extracted contents
	private func _handleExtractedDirectoryContents(at urls: [URL]) async throws {
		for url in urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "framework":
				let destinationURL = _app.appendingPathComponent("Frameworks").appendingPathComponent(url.lastPathComponent)
				try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
				try await _handleDylib(framework: destinationURL)
			case "bundle":
				let destinationURL = _app.appendingPathComponent(url.lastPathComponent)
				try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
	}
	
	// Inject imported dylib file
	private func _handleDylib(at url: URL) async throws {
		let planner = _targetPlanner
		let destinationURL = planner.dylibDestination(in: _app, dylibName: url.lastPathComponent)

		try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
		
		guard let appexe = Bundle(url: _app)?.executableURL else {
			return
		}
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: destinationURL.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		// inject if there's a valid app main executable
		_ = Zsign.injectDyLib(
			appExecutable: appexe.path,
			with: planner.loadPathForBundleExecutable(dylibName: destinationURL.lastPathComponent)
		)

		_injectedDylibs.append(.init(url: destinationURL))
	}
	
	// Inject imported framework dir
	private func _handleDylib(framework: URL) async throws {
		guard
			let fexe = Bundle(url: framework)?.executableURL,
			let appexe = Bundle(url: _app)?.executableURL
		else {
			return
		}
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: fexe.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		// inject if there's a valid app main executable
		_ = Zsign.injectDyLib(
			appExecutable: appexe.path,
			with: "@executable_path/Frameworks/\(framework.lastPathComponent)/\(fexe.lastPathComponent)"
		)
	}
	
	// Extracy imported deb file
	private func _handleDeb(at url: URL, baseTmpDir: URL) async throws {
		let uniqueSubDir = baseTmpDir.appendingPathComponent(UUID().uuidString)
		try _fileManager.createDirectoryIfNeeded(at: uniqueSubDir)
		
		// I don't particularly like this code
		// but it somehow works well enough,
		// do note large lzma's are slow as hell
		
		let handler = AR(with: url)
		let arFiles = try await handler.extract()
		
		for arFile in arFiles {
			let outputPath = uniqueSubDir.appendingPathComponent(arFile.name)
			try arFile.content.write(to: outputPath)
			
			if ["data.tar.lzma", "data.tar.gz", "data.tar.xz", "data.tar.bz2"].contains(arFile.name) {
				var fileToProcess = outputPath
				try extractFile(at: &fileToProcess)
				try extractFile(at: &fileToProcess)
				_directoriesToCheck.append(fileToProcess)
			}
		}
	}
	
	// Read extracted deb file, locate all neccessary contents to copy over to the .app
	private func _handleDirectories(at urls: [URL]) async throws {
		enum DirectoryType: String {
			case frameworks = "Frameworks"
			case dynamicLibraries = "MobileSubstrate/DynamicLibraries"
			case applicationSupport = "Application Support"
		}
		
		let directoryPaths: [DirectoryType: [String]] = [
			.frameworks: ["Library/Frameworks/", "var/jb/Library/Frameworks/"],
			.dynamicLibraries: ["Library/MobileSubstrate/DynamicLibraries/", "var/jb/Library/MobileSubstrate/DynamicLibraries/"],
			.applicationSupport: ["Library/Application Support/", "var/jb/Library/Application Support/"]
		]
				
		for baseURL in urls {
			for (directoryType, paths) in directoryPaths {
				for path in paths {
					let directoryURL = baseURL.appendingPathComponent(path)
					
					guard _fileManager.fileExists(atPath: directoryURL.path) else {
						Logger.misc.warning("Directory does not exist: \(directoryURL.path). Skipping.")
						continue
					}
					
					switch directoryType {
					case .dynamicLibraries:
						let dylibFiles = try await _locateDylibFiles(in: directoryURL)
						_urlsToInject.append(contentsOf: dylibFiles)
						
					case .frameworks:
						let frameworkDirectories = try await _locateFrameworkDirectories(in: directoryURL)
						_urlsToInject.append(contentsOf: frameworkDirectories)
						
					case .applicationSupport:
						try await _searchForBundles(in: directoryURL)
					}
				}
			}
		}
	}

	private func _discoverAppExtensions(in bundleURL: URL) -> [URL] {
		_targetPlanner.directAppExtensions(in: bundleURL, fileManager: _fileManager)
	}

	private func _discoverWatchApps() -> [URL] {
		_targetPlanner.watchApps(in: _app, fileManager: _fileManager)
	}

	@discardableResult
	private func _copyInjectedDylib(_ dylib: InjectedDylib, into bundleURL: URL) -> Bool {
		let destinationURL = _targetPlanner.dylibDestination(
			in: bundleURL,
			dylibName: dylib.name
		)

		if destinationURL.path == dylib.url.path {
			return true
		}

		do {
			try _fileManager.createDirectoryIfNeeded(at: destinationURL.deletingLastPathComponent())

			if !_fileManager.fileExists(atPath: destinationURL.path) {
				try _fileManager.copyItem(at: dylib.url, to: destinationURL)
			}

			return true
		} catch {
			Logger.misc.warning("Failed to copy \(dylib.name) into \(bundleURL.lastPathComponent): \(error.localizedDescription)")
			return false
		}
	}

	private func _injectIntoBundleExecutable(bundleURL: URL, dylibName: String, description: String) {
		guard
			let bundle = Bundle(url: bundleURL),
			let executableURL = bundle.executableURL
		else {
			Logger.misc.warning("Skipping \(bundleURL.lastPathComponent): couldn't read bundle")
			return
		}

		let success = Zsign.injectDyLib(
			appExecutable: executableURL.path,
			with: _targetPlanner.loadPathForBundleExecutable(dylibName: dylibName)
		)

		if success {
			Logger.misc.info("Injected \(dylibName) into \(description): \(bundleURL.lastPathComponent)")
		} else {
			Logger.misc.warning("Failed to inject \(dylibName) into \(description): \(bundleURL.lastPathComponent)")
		}
	}

	private func _injectIntoExtension(extensionURL: URL, dylibName: String) {
		guard
			let extensionBundle = Bundle(url: extensionURL),
			let extensionExecutable = extensionBundle.executableURL
		else {
			Logger.misc.warning("Skipping \(extensionURL.lastPathComponent): couldn't read bundle")
			return
		}

		let success = Zsign.injectDyLib(
			appExecutable: extensionExecutable.path,
			with: _targetPlanner.loadPathForExtensionExecutable(dylibName: dylibName)
		)

		if success {
			Logger.misc.info("Injected \(dylibName) into extension: \(extensionURL.lastPathComponent)")
		} else {
			Logger.misc.warning("Failed to inject into extension: \(extensionURL.lastPathComponent)")
		}
	}

	private func _injectIntoChildExtensions(in bundleURL: URL, dylibs: [InjectedDylib], recursive: Bool) {
		let extensions = _discoverAppExtensions(in: bundleURL)

		for extensionURL in extensions {
			for dylib in dylibs {
				_injectIntoExtension(extensionURL: extensionURL, dylibName: dylib.name)
			}

			guard recursive else {
				continue
			}

			for dylib in dylibs {
				_copyInjectedDylib(dylib, into: extensionURL)
			}

			_injectIntoChildExtensions(in: extensionURL, dylibs: dylibs, recursive: true)
		}
	}

	private func _injectIntoWatchApps(dylibs: [InjectedDylib]) {
		let watchApps = _discoverWatchApps()

		guard !watchApps.isEmpty else {
			Logger.misc.info("No watchOS apps found for injection")
			return
		}

		Logger.misc.info("Found \(watchApps.count) watchOS app(s) for injection")

		for watchApp in watchApps {
			for dylib in dylibs {
				guard _copyInjectedDylib(dylib, into: watchApp) else {
					continue
				}

				_injectIntoBundleExecutable(
					bundleURL: watchApp,
					dylibName: dylib.name,
					description: "watchOS app"
				)
			}

			_injectIntoChildExtensions(in: watchApp, dylibs: dylibs, recursive: true)
		}
	}

	private func _injectIntoAllExtensions(dylibs: [InjectedDylib]) {
		let extensions = _discoverAppExtensions(in: _app)

		if extensions.isEmpty {
			Logger.misc.info("No app extensions found for injection")
		} else {
			Logger.misc.info("Found \(extensions.count) app extension(s) for injection")

			for extensionURL in extensions {
				for dylib in dylibs {
					_injectIntoExtension(extensionURL: extensionURL, dylibName: dylib.name)
				}
			}
		}

		_injectIntoWatchApps(dylibs: dylibs)
	}
}

private struct InjectedDylib {
	let url: URL
	var name: String { url.lastPathComponent }
}

// MARK: - Find correct files in debs
extension TweakHandler {
	private func _searchForBundles(in directory: URL) async throws {
		let fileManager = FileManager.default
		let allFiles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let bundleDirectories = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "bundle" && url.hasDirectoryPath && !isSymlink
		}
		
		for bundleURL in bundleDirectories {
			_urlsToInject.append(bundleURL)
		}
		
		let directoriesToSearch = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.hasDirectoryPath && !bundleDirectories.contains(url) && !isSymlink
		}
		
		for dirURL in directoriesToSearch {
			try await _searchForBundles(in: dirURL)
		}
	}

	private func _locateDylibFiles(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])

		let dylibFiles = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "dylib" && !isSymlink
		}
		
		return dylibFiles
	}

	private func _locateFrameworkDirectories(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let frameworkDirectories = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "framework" && url.hasDirectoryPath && !isSymlink
		}
		
		return frameworkDirectories
	}
}

enum TweakHandlerError: Error {
	case unsupportedFileExtension(String)
	case decompressionFailed(String)
	case missingFile(String)
	case noAccess
}
