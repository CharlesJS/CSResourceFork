//
//  ResourceFork.swift
//
//  Created by Charles Srstka on 2/19/12.
//

import CSErrors
import System

#if canImport(Darwin)
import Darwin
#endif

public struct ResourceFork: Codable, Hashable, Sendable {
    public struct Attributes: OptionSet, Codable, Hashable, Sendable {
        public static let isChanged                          = Attributes(rawValue: 0x0020)
        public static let shouldCompact                      = Attributes(rawValue: 0x0040)
        public static let isReadOnly                         = Attributes(rawValue: 0x0080)
        public static let printerDriverMultiFinderCompatible = Attributes(rawValue: 0x0100)
        public static let resourcesLocked                    = Attributes(rawValue: 0x8000)

        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
    }
    
    public var types: some Collection<String> {
        self.resourcesByType.keys.sorted().map { String(hfsTypeCode: $0) }
    }

    private var resourcesByType: [UInt32 : [Int16 : Resource]] = [:]

    public var attributes: Attributes

    public var size: Int {
        get throws { try Parser.sizeOfResourceFork(resourcesByType: self.resourcesByType) }
    }
    
    public init() {
        self.resourcesByType = [:]
        self.attributes = []
    }

    @available(macOS 11.0, iOS 14.0, macCatalyst 14.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
    public init(path: FilePath, inResourceFork: Bool = false) throws {
        let file = try FileDescriptor.open(path, .readOnly)
        defer { try? file.close() }

        try self.init(file: file, inResourceFork: inResourceFork)
    }

    public init(path: String, inResourceFork: Bool = false) throws {
        guard #available(macOS 11.0, iOS 14.0, macCatalyst 14.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *) else {
            let fd = try callPOSIXFunction(expect: .nonNegative, path: path) { open(path, O_RDONLY) }
            defer { close(fd) }

            try self.init(fileDescriptor: fd, inResourceFork: inResourceFork)
            return
        }

        try self.init(path: FilePath(path), inResourceFork: inResourceFork)
    }

    @available(macOS 11.0, iOS 14.0, macCatalyst 14.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
    public init(file: FileDescriptor, inResourceFork: Bool = false) throws {
        try self.init(fileDescriptor: file.rawValue, inResourceFork: inResourceFork)
    }

    public init(fileDescriptor: Int32, inResourceFork: Bool = false) throws {
        let parserResult = try Parser.parseResourceFork(fileDescriptor: fileDescriptor, inResourceFork: inResourceFork)

        self.resourcesByType = parserResult.resourcesByType
        self.attributes = parserResult.attributes
    }

    public init(data: some Collection<UInt8>) throws {
        (resourcesByType: self.resourcesByType, attributes: self.attributes) = try Parser.parseResourceFork(data: data)
    }

    @available(macOS 11.0, iOS 14.0, macCatalyst 14.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
    public func write(to path: FilePath, inResourceFork: Bool = false) throws {
        let file = try FileDescriptor.open(
            path, .writeOnly,
            options: .create,
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        )
        defer { try? file.close() }

        try self.write(to: file, inResourceFork: inResourceFork)
    }

    public func write(toPath path: String, inResourceFork: Bool = false) throws {
        guard #available(macOS 11.0, iOS 14.0, macCatalyst 14.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *) else {
            let fd = try callPOSIXFunction(expect: .nonNegative, path: path) { open(path, O_CREAT | O_WRONLY, 0o644) }
            defer { close(fd) }

            try self.write(toFileDescriptor: fd, inResourceFork: inResourceFork)
            return
        }

        try self.write(to: FilePath(path), inResourceFork: inResourceFork)
    }

    @available(macOS 11.0, iOS 14.0, macCatalyst 14.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
    public func write(to file: FileDescriptor, inResourceFork: Bool = false) throws {
        if inResourceFork {
            try self.writeResourceFork(fileDescriptor: file.rawValue)
        } else {
            try self.writeDataFork(file: file)
        }
    }
    
    public func write(toFileDescriptor fileDescriptor: Int32, inResourceFork: Bool = false) throws {
        if inResourceFork {
            try self.writeResourceFork(fileDescriptor: fileDescriptor)
        } else {
            try self.writeDataFork(fileDescriptor: fileDescriptor)
        }
    }

    @available(macOS 11.0, iOS 14.0, macCatalyst 14.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
    private func writeDataFork(file: FileDescriptor) throws {
        let data = try self.forkData()

        try file.seek(offset: 0, from: .start)
        let bytesWritten = try file.writeAll(data)

        if bytesWritten != data.count {
            throw Errno.ioError
        }

        if #available(macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, *) {
            try file.resize(to: Int64(data.count))
        } else {
            try callPOSIXFunction(expect: .zero) { ftruncate(file.rawValue, off_t(data.count)) }
        }
    }

    private func writeDataFork(fileDescriptor: Int32) throws {
        let data = try self.forkData()

        try callPOSIXFunction(expect: .zero) { lseek(fileDescriptor, 0, SEEK_SET) }

        let bytesWritten = try data.withUnsafeBytes { buf in
            try callPOSIXFunction(expect: .nonNegative) { Darwin.write(fileDescriptor, buf.baseAddress, buf.count) }
        }

        if bytesWritten != data.count {
            throw errno(EIO)
        }

        try callPOSIXFunction(expect: .zero) { ftruncate(fileDescriptor, off_t(data.count)) }
    }

    private func writeResourceFork(fileDescriptor: Int32) throws {
        fremovexattr(fileDescriptor, XATTR_RESOURCEFORK_NAME, 0)

        try self.forkData().withUnsafeBytes { buf in
            _ = try callPOSIXFunction(expect: .zero) {
                fsetxattr(fileDescriptor, XATTR_RESOURCEFORK_NAME, buf.baseAddress, buf.count, 0, XATTR_CREATE)
            }
        }
    }

    private func forkData() throws -> ContiguousArray<UInt8> {
        try Parser.generateResourceForkData(resourcesByType: self.resourcesByType, attributes: self.attributes)
    }

    public func resources(withType type: String) -> some Collection<Resource> {
        guard let typeCode = type.hfsTypeCode else { return [] }
        return self.resources(withTypeCode: typeCode) as! [Resource]
    }
    
    public func resources(withTypeCode typeCode: UInt32) -> some Collection<Resource> {
        (self.resourcesByType[typeCode] ?? [:]).values.sorted { $0.resourceID < $1.resourceID }
    }

    public func resource(withType type: String, resourceID: Int16) throws -> Resource {
        guard let typeCode = type.hfsTypeCode else {
            throw Error.resourceNotFound(type: type, id: resourceID)
        }

        return try self.resource(withTypeCode: typeCode, resourceID: resourceID)
    }
    
    public func resource(withTypeCode typeCode: UInt32, resourceID: Int16) throws -> Resource {
        guard let resource = self.resourcesByType[typeCode]?[resourceID] else {
            throw Error.resourceNotFound(type: String(hfsTypeCode: typeCode), id: resourceID)
        }

        return resource
    }
    
    @discardableResult public mutating func addResource(
        withType type: String,
        resourceID: Int16,
        attributes: Resource.Attributes = [],
        name: String? = nil,
        resourceData: some Sequence<UInt8> = EmptyCollection()
    ) throws -> Resource {
        guard let typeCode = type.hfsTypeCode else { throw errno(EINVAL) }

        return try self.addResource(
            withTypeCode: typeCode,
            resourceID: resourceID,
            attributes: attributes,
            name: name,
            resourceData: resourceData
        )
    }
    
    @discardableResult public mutating func addResource(
        withTypeCode type: UInt32,
        resourceID: Int16,
        attributes: Resource.Attributes = [],
        name: String? = nil,
        resourceData: some Sequence<UInt8> = EmptyCollection()
    ) throws -> Resource {
        let resource = try Resource(
            typeCode: type,
            resourceID: resourceID,
            name: name,
            attributes: attributes,
            resourceData: resourceData
        )

        self.resourcesByType[type, default: [:]][resourceID] = resource

        return resource
    }
    
    public mutating func removeResource(withType type: String, resourceID: Int16) throws {
        guard let typeCode = type.hfsTypeCode else {
            throw errno(EINVAL)
        }

        try self.removeResource(withTypeCode: typeCode, resourceID: resourceID)
    }

    public mutating func removeResource(withTypeCode typeCode: UInt32, resourceID: Int16) throws {
        guard self.resourcesByType[typeCode]?[resourceID] != nil else {
            throw Error.resourceNotFound(type: String(hfsTypeCode: typeCode), id: resourceID)
        }

        self.resourcesByType[typeCode]?[resourceID] = nil
    }

    public mutating func changeID(ofResourceWithType type: String, resourceID: Int16, to newID: Int16) throws {
        var resource = try self.resource(withType: type, resourceID: resourceID)
        try self.changeID(ofResource: &resource, to: newID)
    }

    public mutating func changeID(ofResourceWithTypeCode typeCode: UInt32, resourceID: Int16, to newID: Int16) throws {
        var resource = try self.resource(withTypeCode: typeCode, resourceID: resourceID)
        try self.changeID(ofResource: &resource, to: newID)
    }

    private mutating func changeID(ofResource resource: inout Resource, to newID: Int16) throws {
        let oldID = resource.resourceID

        resource.resourceID = newID
        self.resourcesByType[resource.typeCode]![newID] = resource
        self.resourcesByType[resource.typeCode]![oldID] = nil
    }
}
