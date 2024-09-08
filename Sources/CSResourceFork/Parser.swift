//
//  Parser.swift
//  CSResourceFork
//
//  Created by Charles Srstka on 5/22/17.
//
//

import CSErrors
import DataParser
import HFSTypeConversion
import System

#if canImport(Darwin)
import Darwin
let resForkName = XATTR_RESOURCEFORK_NAME
#elseif canImport(Glibc)
import Glibc
let resForkName = "com.apple.ResourceFork"
#endif

extension ResourceFork {
    internal static let maxSize = Int(Int32.max)

    internal struct Parser {
        private static let reservedHeaderSize = 0x100

        private class Backing {
            private let fileDescriptor: Int32
            private let inResourceFork: Bool
            
            init(fileDescriptor: Int32, inResourceFork: Bool) {
                self.fileDescriptor = fileDescriptor
                self.inResourceFork = inResourceFork
            }
            
            func data(in range: Range<Int>) throws -> ContiguousArray<UInt8> {
                try ContiguousArray<UInt8>(unsafeUninitializedCapacity: range.count) { buf, count in
                    do {
                        if self.inResourceFork {
                            if range.lowerBound > UInt32.max { throw errno(EINVAL) }

                            count = try callPOSIXFunction(expect: .nonNegative) {
                                fgetxattr(
                                    self.fileDescriptor,
                                    resForkName,
                                    buf.baseAddress,
                                    buf.count,
                                    UInt32(range.lowerBound),
                                    0
                                )
                            }
                        } else {
                            let offset = try callPOSIXFunction(expect: .nonNegative) {
                                lseek(self.fileDescriptor, off_t(range.lowerBound), SEEK_SET)
                            }

                            if offset != range.lowerBound {
                                throw Error.corruptResourceFork
                            }

                            count = try callPOSIXFunction(expect: .nonNegative) {
                                read(self.fileDescriptor, buf.baseAddress, buf.count)
                            }
                        }
                    } catch {
                        count = 0
                        throw error
                    }
                }
            }
        }
        
        internal static func sizeOfResourceFork(resourcesByType: [UInt32 : [Int16 : Resource]]) throws -> Int {
            let reservedHeaderSize = self.reservedHeaderSize
            let mapSize =
                16 /* reserved for copy of resource header */ +
                4 /* reserved for handle to next resource map */ +
                2 /* reserved for file reference number */ +
                2 /* resource fork attributes */ +
                2 /* offset from beginning of map to resource type list */ +
                2 /* offset from beginning of map to resource name list */ +
                2 /* number of types in the map minus 1 */

            return resourcesByType.values.reduce(reservedHeaderSize + mapSize) {
                let typeListSize =
                    4 /* resource type */ +
                    2 /* number of resources of this type in map minus 1 */ +
                    2 /* offset from beginning of resource type list to reference list for this type */

                return $0 + $1.values.reduce(typeListSize) { totalSize, resource in
                    let resDataSize =
                        4 /* length of following resource data */ +
                        resource.size /* resource data for this resource */

                    let mapEntrySize =
                        2 /* resource ID */ +
                        2 /* offset from beginning of resource name list to resource name */ +
                        1 /* resource attributes */ +
                        3 /* offset from beginning of resource data to data for this resource */ +
                        4 /* reserved for handle to resource */

                    let nameSize = if let name = resource.name,
                                      let cName = name.macOSRomanCString(allowLossyConversion: true),
                                      !cName.isEmpty {
                        1 /* length of following resource name */ +
                        cName.count /* name data in Mac OS Roman encoding */
                    } else {
                        0
                    }

                    return totalSize + resDataSize + mapEntrySize + nameSize
                }
            }
        }
        
        internal static func parseResourceFork(fileDescriptor: Int32, inResourceFork: Bool) throws -> (
            resourcesByType: [UInt32 : [Int16 : Resource]],
            attributes: ResourceFork.Attributes
        ) {
            let backing = Backing(fileDescriptor: fileDescriptor, inResourceFork: inResourceFork)
            let header = try backing.data(in: 0..<16)
            
            if header.count < 16 {
                throw Error.corruptResourceFork
            }

            var parser = DataParser(header)

            let dataOffset = try parser.readUInt32(byteOrder: .big)
            let mapOffset = try parser.readUInt32(byteOrder: .big)
            let dataLength = try parser.readUInt32(byteOrder: .big)
            let mapLength = try parser.readUInt32(byteOrder: .big)

            if mapLength < 28 {
                throw Error.corruptResourceFork
            }
            
            return try self.parseResourceMap(
                from: backing,
                in: Int(mapOffset)..<Int(mapOffset + mapLength),
                resourceDataRange: Int(dataOffset)..<Int(dataOffset + dataLength)
            )
        }
        
        private static func parseResourceMap(
            from backing: Backing,
            in mapRange: Range<Int>,
            resourceDataRange: Range<Int>
        ) throws -> (resourcesByType: [UInt32 : [Int16 : Resource]], attributes: ResourceFork.Attributes) {
            let mapData = try backing.data(in: mapRange)
            var parser = DataParser(mapData)

            let dataOffset = try parser.readUInt32(byteOrder: .big)
            let mapOffset = try parser.readUInt32(byteOrder: .big)
            let dataLength = try parser.readUInt32(byteOrder: .big)
            let mapLength = try parser.readUInt32(byteOrder: .big)

            guard dataOffset == resourceDataRange.lowerBound,
                  mapOffset == mapRange.lowerBound,
                  dataLength == resourceDataRange.count,
                  mapLength == mapRange.count else {
                throw Error.corruptResourceFork
            }

            try parser.skipBytes(6)

            let attributes = try ResourceFork.Attributes(rawValue: parser.readUInt16(byteOrder: .big))

            let typeListOffsetInMap = try parser.readUInt16(byteOrder: .big)
            let nameListOffsetInMap = try parser.readUInt16(byteOrder: .big)

            guard typeListOffsetInMap < mapRange.count, nameListOffsetInMap <= mapRange.count else {
                throw Error.corruptResourceFork
            }
            
            let resourcesByType = try self.parseTypeList(
                from: backing,
                at: Int(typeListOffsetInMap),
                in: mapData,
                nameListOffset: Int(nameListOffsetInMap),
                resourceDataRange: resourceDataRange
            )

            return (resourcesByType: resourcesByType, attributes: attributes)
        }
        
        private static func parseTypeList(
            from backing: Backing,
            at offset: Int,
            in mapData: ContiguousArray<UInt8>,
            nameListOffset: Int,
            resourceDataRange: Range<Int>
        ) throws -> [UInt32 : [Int16 : Resource]] {
            var parser = DataParser(mapData)

            try parser.skipBytes(offset)
            let typeCount = try parser.readUInt16(byteOrder: .big) &+ 1

            return try (0..<typeCount).reduce(into: [:]) { resources, _ in
                let resType = try parser.readUInt32(byteOrder: .big)
                let resCount = try parser.readUInt16(byteOrder: .big) &+ 1
                let typeOffset = try parser.readInt16(byteOrder: .big)

                if resources[resType] != nil {
                    throw Error.corruptResourceFork
                }

                resources[resType] = try self.parseResources(
                    from: backing,
                    typeCode: resType,
                    mapData: mapData,
                    count: resCount,
                    offset: offset + Int(typeOffset),
                    nameListOffset: nameListOffset,
                    resourceDataRange: resourceDataRange
                )
            }
        }

        private static func parseResources(
            from backing: Backing,
            typeCode: UInt32,
            mapData: ContiguousArray<UInt8>,
            count: UInt16,
            offset: Int,
            nameListOffset: Int,
            resourceDataRange: Range<Int>
        ) throws -> [Int16 : Resource] {
            var parser = DataParser(mapData)
            try parser.skipBytes(offset)

            return try (0..<count).reduce(into: [:]) { resources, _ in
                let id = try parser.readInt16(byteOrder: .big)
                let nameOffset = try parser.readUInt16(byteOrder: .big)

                let resAttrs = try parser.readByte()
                let resDataOffset = try parser.readInt(ofType: Int.self, size: 3, byteOrder: .big)

                try parser.skipBytes(4)

                let resName: String? = if nameOffset == 0xffff {
                    nil
                } else {
                    try self.readResourceName(mapData: mapData, offset: Int(nameOffset), nameListOffset: nameListOffset)
                }

                let absResDataOffset = resourceDataRange.lowerBound + resDataOffset
                if absResDataOffset + 4 > resourceDataRange.upperBound {
                    throw Error.corruptResourceFork
                }

                let resData = try self.readResourceData(from: backing, in: absResDataOffset..<resourceDataRange.upperBound)

                resources[id] = try Resource(
                    typeCode: typeCode,
                    resourceID: id,
                    name: resName,
                    attributes: resAttrs,
                    resourceData: resData
                )
            }
        }

        private static func readResourceName(
            mapData: ContiguousArray<UInt8>,
            offset: Int,
            nameListOffset: Int
        ) throws -> String? {
            var nameParser = DataParser(mapData)
            try nameParser.skipBytes(nameListOffset + offset)

            let nameLength = try nameParser.readByte()
            if nameLength == 0 {
                return nil
            }

            return try String(macOSRomanData: nameParser.readBytes(count: nameLength))
        }

        private static func readResourceData(from backing: Backing, in range: Range<Int>) throws -> ContiguousArray<UInt8> {
            let resLengthData = try backing.data(in: range.prefix(4))
            let resLength = resLengthData.withUnsafeBytes {
                $0.withMemoryRebound(to: UInt32.self) {
                    Int(UInt32(bigEndian: $0[0]))
                }
            }

            let dataRange = range.dropFirst(4).prefix(resLength)
            if dataRange.count != resLength {
                throw Error.corruptResourceFork
            }

            return try backing.data(in: dataRange)
        }

        internal static func generateResourceForkData(
            resourcesByType: [UInt32 : [Int16 : Resource]],
            attributes: ResourceFork.Attributes
        ) throws -> ContiguousArray<UInt8> {
            let types = resourcesByType.keys.sorted()

            let resDataOffset = self.reservedHeaderSize
            let (resourceData: resourceData, offsets: resDataOffsets) = try self.generateResourceData(
                resources: types.flatMap { resourcesByType[$0]!.values }
            )

            let resDataLength = resourceData.count
            
            let mapOffset = resDataOffset + resDataLength
            var mapData = try self.generateResourceMapData(
                resourcesByType: resourcesByType,
                attributes: attributes,
                resourceDataOffsets: resDataOffsets
            )

            let mapLength = mapData.count

            mapData.withUnsafeMutableBytes {
                $0.withMemoryRebound(to: UInt32.self) {
                    $0[0] = UInt32(resDataOffset).bigEndian // Offset from beginning of resource fork to resource data
                    $0[1] = UInt32(mapOffset).bigEndian     // Offset from beginning of resource fork to resource map
                    $0[2] = UInt32(resDataLength).bigEndian // Length of resource data
                    $0[3] = UInt32(mapLength).bigEndian     // Length of resource map
                }
            }

            let forkSize = resDataOffset + resourceData.count + mapData.count
            guard forkSize <= ResourceFork.maxSize else {
                throw Error.resourceForkTooLarge
            }

            return ContiguousArray<UInt8>(unsafeUninitializedCapacity: forkSize) { buf, count in
                // both start of fork and start of resource map have to begin with the same 16-byte header
                _ = buf.prefix(16).initialize(from: mapData.prefix(16))
                buf[16..<resDataOffset].initialize(repeating: 0)
                _ = buf[resDataOffset..<(resDataOffset + resourceData.count)].initialize(from: resourceData)
                _ = buf[mapOffset..<forkSize].initialize(from: mapData)

                count = forkSize
            }
        }
        
        private static func generateResourceData(resources: some Sequence<Resource>) throws -> (
            resourceData: ContiguousArray<UInt8>,
            offsets: [UInt32 : [Int16 : UInt32]]
        ) {
            var resourceData: ContiguousArray<UInt8> = []
            var offsets: [UInt32 : [Int16 : UInt32]] = [:]
            var totalSize = 0
            
            for eachResource in resources {
                let resData = eachResource.resourceData
                let resSize = resData.count
                
                if resSize > Resource.maxSize {
                    throw Error.resourceTooLarge(type: eachResource.type, id: eachResource.resourceID, size: resSize)
                }

                offsets[eachResource.typeCode, default: [:]][eachResource.resourceID] = UInt32(totalSize)

                var bigLength = UInt32(resSize).bigEndian
                
                withUnsafeBytes(of: &bigLength) { resourceData.append(contentsOf: $0) }
                totalSize += MemoryLayout.size(ofValue: bigLength)
                
                resourceData += resData
                totalSize += resSize

                guard totalSize <= ResourceFork.maxSize else {
                    throw Error.resourceForkTooLarge
                }
            }
            
            return (resourceData: resourceData, offsets: offsets)
        }
        
        private static func generateResourceMapData(
            resourcesByType: [UInt32 : [Int16 : Resource]],
            attributes: ResourceFork.Attributes,
            resourceDataOffsets offsets: [UInt32 : [Int16: UInt32]]
        ) throws -> ContiguousArray<UInt8> {
            let (
                typeListData: typeListData,
                refListData: refListData,
                nameListData: nameListData
            ) = try self.generateResourceTypeListData(resourcesByType: resourcesByType, resourceDataOffsets: offsets)

            let typeCount = Int(resourcesByType.count)

            let reservedHeaderSpace =
                16 /* reserved for copy of resource header, to be filled in later */ +
                4 /* reserved for handle to next resource map */ +
                2 /* reserved for file reference number */
            
            let mapHeaderLength =
                2 /* resource fork attributes */ +
                2 /* offset from beginning of map to resource type list */ +
                2 /* offset from beginning of map to resource name list */ +
                2 /* number of types in the map minus 1 */
            
            let typeListOffset = mapHeaderLength
            let nameListOffset = typeListOffset + typeListData.count + refListData.count
            
            guard nameListOffset <= Int(Int16.max) else {
                throw Error.typeListTooLong
            }

            guard typeCount <= Int(Int16.max) + 1 else {
                throw Error.tooManyTypes
            }

            let zeroFill = repeatElement(0 as UInt8, count: reservedHeaderSpace)

            let mapHeader = ContiguousArray<UInt8>(unsafeUninitializedCapacity: mapHeaderLength) { buf, count in
                buf.withMemoryRebound(to: UInt16.self) {
                    $0[0] = attributes.subtracting(.isChanged).rawValue.bigEndian
                    $0[1] = UInt16(typeListOffset).bigEndian
                    $0[2] = UInt16(nameListOffset).bigEndian
                    $0[3] = resourcesByType.isEmpty ? 0xffff : UInt16(typeCount - 1).bigEndian
                }

                count = mapHeaderLength
            }

            return zeroFill + mapHeader + typeListData + refListData + nameListData
        }
        
        private static func generateResourceTypeListData(
            resourcesByType: [UInt32 : [Int16 : Resource]],
            resourceDataOffsets: [UInt32 : [Int16 : UInt32]]
        ) throws -> (
            typeListData: ContiguousArray<UInt8>,
            refListData: ContiguousArray<UInt8>,
            nameListData: ContiguousArray<UInt8>
        ) {
            var typeListData: ContiguousArray<UInt8> = []
            var refListData: ContiguousArray<UInt8> = []
            var nameListData: ContiguousArray<UInt8> = []

            let refListOffset = Int(resourcesByType.count) * 8

            typeListData.reserveCapacity(refListOffset)
            refListData.reserveCapacity(12 * resourcesByType.values.reduce(0) { $0 + $1.count })
            nameListData.reserveCapacity(
                resourcesByType.values.reduce(0) { $1.reduce($0) { $0 + ($1.value.nameData?.count ?? 0) } }
            )

            for (key: typeCode, value: resources) in resourcesByType {
                let resCount = resources.count
                let refOffset = refListData.count + refListOffset
                
                if refOffset > Int(Int16.max) {
                    throw Error.resourceForkTooLarge
                }
                
                var bigResType = typeCode.bigEndian              // resource type
                var bigResCount = UInt16(resCount - 1).bigEndian // number of resources of this type in map minus 1
                var bigRefOffset = UInt16(refOffset).bigEndian   // offset from start of type list to reflist for this type

                withUnsafeBytes(of: &bigResType) { typeListData.append(contentsOf: $0) }
                withUnsafeBytes(of: &bigResCount) { typeListData.append(contentsOf: $0) }
                withUnsafeBytes(of: &bigRefOffset) { typeListData.append(contentsOf: $0) }

                try self.generateReferenceListData(
                    refListData: &refListData,
                    nameListData: &nameListData,
                    resources: resources,
                    resourceDataOffsets: resourceDataOffsets[typeCode]!
                )
            }
            
            return (typeListData: typeListData, refListData: refListData, nameListData: nameListData)
        }
        
        private static func generateReferenceListData(
            refListData: inout ContiguousArray<UInt8>,
            nameListData: inout ContiguousArray<UInt8>,
            resources: [Int16 : Resource],
            resourceDataOffsets: [Int16 : UInt32]
        ) throws {
            for (id, resource) in resources {
                let nameListOffset = try self.addNameToNameList(resource: resource, data: &nameListData)

                // the offset should always be present, since we set it earlier
                let resDataOffset = resourceDataOffsets[id]!
                if resDataOffset > 0xffffff {
                    throw Error.resourceForkTooLarge
                }

                let attrs = (UInt32((resource.attributes.subtracting(.isChanged)).rawValue) << 24) | UInt32(resDataOffset)

                var bigResID = resource.resourceID.bigEndian     // Resource ID
                var bigNameListOffset = nameListOffset.bigEndian // Offset from beginning of resource name list to name
                var bigAttrs = attrs.bigEndian                   // Resource attributes

                withUnsafeBytes(of: &bigResID) { refListData.append(contentsOf: $0) }
                withUnsafeBytes(of: &bigNameListOffset) { refListData.append(contentsOf: $0) }
                withUnsafeBytes(of: &bigAttrs) { refListData.append(contentsOf: $0) }

                refListData.append(contentsOf: repeatElement(0, count: 4)) // Reserved for handle to resource
            }
        }

        private static func addNameToNameList(resource: Resource, data: inout ContiguousArray<UInt8>) throws -> Int16 {
            guard let name = resource.name,
                  let nameData = name.macOSRomanCString(allowLossyConversion: true)?.prefix(Int(UInt8.max)),
                  !nameData.isEmpty else {
                return -1
            }

            guard let offset = Int16(exactly: data.count) else {
                throw Error.nameListTooLong
            }

            data.append(contentsOf: CollectionOfOne(UInt8(nameData.count)))
            data.append(contentsOf: nameData)

            return offset
        }
    }
}
