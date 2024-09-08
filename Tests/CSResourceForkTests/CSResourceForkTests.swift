import Foundation
import System
import Testing
@testable import CSResourceFork

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
    let forkAttributes: ResourceFork.Attributes
    let expectedResources: [String : [ExpectedResource]]

    init(name: String) {
        let fixtureURL = Self.fixturesURL.appending(path: name)
        let resourcesURL = fixtureURL.appending(path: "resources.rsrc")
        let info = NSDictionary(contentsOf: fixtureURL.appending(path: "Info.plist")) as! [String : Any]

        self.testDescription = name
        self.url = resourcesURL
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

@Test("Read Fixture", arguments: fixtures)
func testReadFixture(fixture: Fixture) throws {
    let resourceFork = try ResourceFork(path: FilePath(fixture.url.path), inResourceFork: false)

    try fixture.compare(to: resourceFork)
}

@Test("Write Fixture", arguments: fixtures)
func testWriteFixture(fixture: Fixture) throws {
    let resourceFork = try ResourceFork(path: FilePath(fixture.url.path), inResourceFork: false)

    let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    try resourceFork.write(to: FilePath(tempURL.path), inResourceFork: false)

    let reloaded = try ResourceFork(path: FilePath(tempURL.path), inResourceFork: false)

    try fixture.compare(to: reloaded)
    #expect(reloaded == resourceFork)
}
