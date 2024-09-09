#!/usr/bin/env swift

import Foundation
import RegexBuilder

let name = CommandLine.arguments[1]
let fixtureURL = URL(filePath: name).standardizedFileURL
let resourcesURL = fixtureURL.appending(path: "resources.rsrc")
let infoURL = fixtureURL.appending(path: "Info.plist")

let derez = Process()
let stdoutPipe = Pipe()
let stdout = stdoutPipe.fileHandleForReading

derez.executableURL = URL(filePath: "/usr/bin/DeRez")
derez.arguments = ["-useDF", resourcesURL.path]
derez.standardOutput = stdoutPipe

print("Running derez")

try derez.run()

let output = try String(data: stdout.readToEnd()!, encoding: .macOSRoman)!
let regex = try Regex("data\\s*'([^']+)'\\s*\\(([^\\)]+)\\)\\s*{.*")
let dataRegex = try Regex("\\$\"([^\"]*)\"")
let byteRegex = try Regex("[0-9a-fA-F]{2}")
var remainingOutput = output[...]

var resources: [String : [[String : Any]]] = [:]

while let match = try regex.firstMatch(in: remainingOutput) {
    let type = match[1].substring!
    let resInfo = match[2].substring!.components(separatedBy: ", ")
    let id = Int(resInfo.first!)!

    var attributes: Int
    if resInfo.last!.hasPrefix("$") {
        attributes = Int(resInfo.last!.dropFirst(), radix: 16)!
    } else {
        attributes = 0
    }

    if resInfo.contains("preload") {
        attributes |= 0x04
    }
    
    if resInfo.contains("purgeable") {
        attributes |= 0x20
    }

    print("\(type) ID \(id)")

    var data = Data()

    remainingOutput = remainingOutput[match.range.upperBound...]
    while true {
        let lineEnd = remainingOutput.range(of: "\n") ?? remainingOutput.endIndex..<remainingOutput.endIndex
        let line = remainingOutput[..<lineEnd.lowerBound]
        remainingOutput = remainingOutput[lineEnd.upperBound...]

        if line.starts(with: "}") {
            break
        }

        if let dataMatch = try dataRegex.firstMatch(in: line) {
            var hexData = dataMatch[1].substring!
            while let byteMatch = try byteRegex.firstMatch(in: hexData) {
                data.append(UInt8(byteMatch[0].substring!, radix: 16)!)
                hexData = hexData[byteMatch.range.upperBound...]
            }
        }
    }

    var resource: [String : Any] = [
        "Attributes" : attributes,
        "ID": id,
        "Data": data
    ]

    if resInfo.count > 1, resInfo[1].starts(with: "\""), resInfo[1].hasSuffix("\"") {
        resource["Name"] = resInfo[1].dropFirst().dropLast()
    }

    resources[String(type), default: []].append(resource)

    remainingOutput = output[match.range.upperBound...]
}

let info = ["Resources": resources]

try (info as NSDictionary).write(to: infoURL)
