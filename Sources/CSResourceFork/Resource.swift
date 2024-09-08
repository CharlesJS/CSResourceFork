//
//  Resource.swift
//
//  Created by Charles Srstka on 2/19/12.
//

import HFSTypeConversion

public struct Resource: Codable, Hashable, Sendable {
    internal static let maxSize = Int(Int32.max)

    public struct Attributes: OptionSet, Codable, Hashable, Sendable {
        static public let isCompressed   = Attributes(rawValue: 0x01)
        static public let isChanged      = Attributes(rawValue: 0x02)
        static public let shouldPreload  = Attributes(rawValue: 0x04)
        static public let isProtected    = Attributes(rawValue: 0x08)
        static public let isLocked       = Attributes(rawValue: 0x10)
        static public let isPurgeable    = Attributes(rawValue: 0x20)
        static public let isOnSystemHeap = Attributes(rawValue: 0x40)

        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
    }
    
    public let typeCode: UInt32
    public var type: String { String(hfsTypeCode: self.typeCode) }

    public internal(set) var resourceID: Int16

    public var size: Int { self.resourceData.count }
    
    public var name: String? {
        get { self.nameData.map { String(macOSRomanData: $0) } }
        set { self.nameData = newValue?.macOSRomanCString(allowLossyConversion: true) }
    }

    internal var nameData: ContiguousArray<UInt8>?
    public var resourceData: ContiguousArray<UInt8>

    public var attributes: Attributes

    internal init(
        typeCode: UInt32,
        resourceID: Int16,
        name: String?,
        attributes: Attributes = [],
        resourceData: some Sequence<UInt8>
    ) throws {
        self.typeCode = typeCode
        self.resourceID = resourceID
        self.nameData = name?.macOSRomanCString(allowLossyConversion: true)
        self.attributes = attributes
        self.resourceData = ContiguousArray(resourceData)
    }
}
