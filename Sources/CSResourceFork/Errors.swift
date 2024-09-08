//
//  Errors.swift
//  CSResourceFork
//
//  Created by Charles Srstka on 9/6/24.
//

extension ResourceFork {
    public enum Error: Swift.Error, Hashable {
        case resourceNotFound(type: String, id: Int16)
        case corruptResourceFork
        case resourceTooLarge(type: String, id: Int16, size: Int)
        case resourceForkTooLarge
        case typeListTooLong
        case nameListTooLong
        case tooManyTypes
    }
}
