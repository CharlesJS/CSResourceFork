import CSErrors
@testable import CSResourceFork
import Foundation
import System
import Testing

struct Fixture: CustomTestStringConvertible {
    struct ExpectedResource {
        let id: Int16
        let attributes: Resource.Attributes
        let name: String?
        let data: Data
    }

    private static let fixturesURL = fixtureBundle.url(forResource: "fixtures", withExtension: "")!

    let testDescription: String
    let url: URL
    let size: Int
    let forkAttributes: ResourceFork.Attributes
    let expectedResources: [String : [ExpectedResource]]

    init(name: String) {
        let fixtureURL = Self.fixturesURL.appending(path: name)
        let resourcesURL = fixtureURL.appending(path: "resources.rsrc")
        let info = NSDictionary(contentsOf: fixtureURL.appending(path: "Info.plist")) as! [String : Any]

        self.testDescription = name
        self.url = resourcesURL
        self.size = try! resourcesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        self.forkAttributes = ResourceFork.Attributes(rawValue: info["Attributes"] as? UInt16 ?? 0)
        self.expectedResources = (info["Resources"] as! [String : [[String : Any]]]).mapValues {
            $0.map {
                ExpectedResource(
                    id: $0["ID"] as! Int16,
                    attributes: Resource.Attributes(rawValue: $0["Attributes"] as? UInt8 ?? 0),
                    name: $0["Name"] as? String,
                    data: ($0["Data"] as? Data ?? ($0["Data"] as? String)?.data(using: .macOSRoman))!
                )
            }
        }
    }

    func compare(to resourceFork: ResourceFork) throws {
        #expect(resourceFork.attributes == self.forkAttributes)

        for (type, resources) in self.expectedResources {
            #expect(resourceFork.resources(withType: type).count == resources.count)

            for spec in resources {
                let resource = try resourceFork.resource(withType: type, resourceID: spec.id)

                #expect(resource.type == type)
                #expect(resource.typeCode == type.hfsTypeCode!)
                #expect(resource.resourceID == spec.id)
                #expect(resource.attributes == spec.attributes)
                #expect(resource.name == spec.name)
                #expect(Data(resource.resourceData) == spec.data)
            }
        }
    }
}

struct Options: OptionSet, CustomTestStringConvertible {
    static let testResourceFork = Options(rawValue: 0x01)
    static let testRawStringPaths = Options(rawValue: 0x02)
    static let testFileDescriptor = Options(rawValue: 0x04)
    static let testRawFileDescriptor = Options(rawValue: 0x08)
    static let testFileAlreadyExists = Options(rawValue: 0x10)

    let rawValue: Int

    var testDescription: String {
        [
            self.contains(.testResourceFork) ? "rsrc" : "data",
            self.contains(.testRawStringPaths) ? "raw" : nil,
            self.contains(.testFileDescriptor) ? "fd" : nil,
            self.contains(.testRawFileDescriptor) ? "raw fd" : nil,
            self.contains(.testFileAlreadyExists) ? "exists" : nil,
        ].compactMap(\.self).joined(separator: ", ")
    }
}

let fixtures = [
    "basic"
].map { Fixture(name: $0) }

private let bundle: Bundle = {
    class BundleResolver: NSObject {}

    return Bundle(for: BundleResolver.self)
}()

private let fixtureBundle = Bundle(
    url: bundle.url(forResource: "CSResourceFork_CSResourceForkTests", withExtension: "bundle")!
)!

@Test("Read Fixture", arguments: fixtures, [
    [],
    .testRawStringPaths,
    .testFileDescriptor,
    [.testFileDescriptor, .testRawFileDescriptor],
    .testResourceFork,
    [.testResourceFork, .testRawStringPaths],
    [.testResourceFork, .testFileDescriptor],
    [.testResourceFork, .testFileDescriptor, .testRawFileDescriptor],
] as [Options])
func testReadFixture(fixture: Fixture, options: Options) throws {
    let resourceFork: ResourceFork

    if options.contains(.testResourceFork) {
        let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try Data().write(to: tempURL, options: .atomic)
        try Data(contentsOf: fixture.url).withUnsafeBytes { buf in
            _ = try callPOSIXFunction(expect: .zero) {
                setxattr(tempURL.path, "com.apple.ResourceFork", buf.baseAddress, buf.count, 0, 0)
            }
        }

        if options.contains(.testRawStringPaths) {
            resourceFork = try ResourceFork(path: tempURL.path, inResourceFork: true)
        } else if options.contains(.testFileDescriptor) {
            let file = try FileDescriptor.open(FilePath(tempURL.path), .readOnly)
            defer { try? file.close() }

            if options.contains(.testRawFileDescriptor) {
                resourceFork = try ResourceFork(fileDescriptor: file.rawValue, inResourceFork: true)
            } else {
                resourceFork = try ResourceFork(file: file, inResourceFork: true)
            }
        } else {
            resourceFork = try ResourceFork(path: FilePath(tempURL.path), inResourceFork: true)
        }
    } else {
        if options.contains(.testRawStringPaths) {
            resourceFork = try ResourceFork(path: fixture.url.path, inResourceFork: false)
        } else if options.contains(.testFileDescriptor) {
            let file = try FileDescriptor.open(FilePath(fixture.url.path), .readOnly)
            defer { try? file.close() }

            if options.contains(.testRawFileDescriptor) {
                resourceFork = try ResourceFork(fileDescriptor: file.rawValue, inResourceFork: false)
            } else {
                resourceFork = try ResourceFork(file: file, inResourceFork: false)
            }
        } else {
            resourceFork = try ResourceFork(path: FilePath(fixture.url.path), inResourceFork: false)
        }
    }

    #expect(try resourceFork.size == fixture.size)
    #expect(try resourceFork.types.sorted() == fixture.expectedResources.keys.sorted())

    try fixture.compare(to: resourceFork)
}

@Test("Write Fixture", arguments: fixtures, [
    [],
    .testFileAlreadyExists,
    .testRawStringPaths,
    [.testRawStringPaths, .testFileAlreadyExists],
    [.testFileDescriptor, .testFileAlreadyExists],
    [.testFileDescriptor, .testRawFileDescriptor, .testFileAlreadyExists],
    .testResourceFork,
    [.testResourceFork, .testFileAlreadyExists],
    [.testResourceFork, .testFileDescriptor, .testFileAlreadyExists],
    [.testResourceFork, .testFileDescriptor, .testRawFileDescriptor, .testFileAlreadyExists],
    [.testResourceFork, .testRawStringPaths],
] as [Options])
func testWriteFixture(fixture: Fixture, options: Options) throws {
    let resourceFork: ResourceFork
    if options.contains(.testRawStringPaths) {
        resourceFork = try ResourceFork(path: fixture.url.path, inResourceFork: false)
    } else if options.contains(.testFileDescriptor) {
        let file = try FileDescriptor.open(FilePath(fixture.url.path), .readOnly)
        defer { try? file.close() }

        if options.contains(.testRawFileDescriptor) {
            resourceFork = try ResourceFork(fileDescriptor: file.rawValue, inResourceFork: false)
        } else {
            resourceFork = try ResourceFork(file: file, inResourceFork: false)
        }
    } else {
        resourceFork = try ResourceFork(path: FilePath(fixture.url.path), inResourceFork: false)
    }

    let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    if options.contains(.testFileAlreadyExists) {
        try Data().write(to: tempURL, options: .atomic)
    }

    if options.contains(.testRawStringPaths) {
        try resourceFork.write(toPath: tempURL.path, inResourceFork: options.contains(.testResourceFork))
    } else if options.contains(.testFileDescriptor) {
        let file = try FileDescriptor.open(FilePath(tempURL.path), .writeOnly)
        defer { try? file.close() }

        if options.contains(.testRawFileDescriptor) {
            try resourceFork.write(toFileDescriptor: file.rawValue, inResourceFork: options.contains(.testResourceFork))
        } else {
            try resourceFork.write(to: file, inResourceFork: options.contains(.testResourceFork))
        }
    } else {
        try resourceFork.write(to: FilePath(tempURL.path), inResourceFork: options.contains(.testResourceFork))
    }

    let reloaded = try ResourceFork(path: FilePath(tempURL.path), inResourceFork: options.contains(.testResourceFork))

    try fixture.compare(to: reloaded)
    #expect(reloaded == resourceFork)
}
