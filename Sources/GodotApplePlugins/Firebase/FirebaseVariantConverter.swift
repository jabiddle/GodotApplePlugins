//
//  FirebaseVariantConverter.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseFirestore

enum FirebaseVariantConverter {
    static func variantToAny(_ variant: Variant) -> Any {
        switch variant.gtype {
        case .`nil`: return NSNull()
        case .int: return Int(variant) ?? 0
        case .float: return Double(variant) ?? 0.0
        case .bool: return Bool(variant) ?? false
        case .string: return String(variant) ?? ""
        case .dictionary:
            guard let gDict = VariantDictionary(variant) else { return [:] }
            var swiftDict: [String: Any] = [:]
            for key in gDict.keys() {
                if let k = String(key), let val = gDict[key] {
                    swiftDict[k] = variantToAny(val)
                }
            }
            return swiftDict
        case .array:
            guard let gArray = VariantArray(variant) else { return [] }
            var swiftArray: [Any] = []
            for i in 0..<Int(gArray.count) {
                if let val = gArray[Int64(i)] {
                    swiftArray.append(variantToAny(val))
                }
            }
            return swiftArray
        case .packedByteArray:
            return PackedByteArray(variant)?.asData() ?? Data()
        default: return variant.description
        }
    }
    
    static func anyToVariant(_ value: Any) -> Variant {
        if value is NSNull { return Variant(Int?.none) }
        if let intVal = value as? Int { return Variant(intVal) }
        if let doubleVal = value as? Double { return Variant(doubleVal) }
        if let boolVal = value as? Bool { return Variant(boolVal) }
        if let stringVal = value as? String { return Variant(stringVal) }
        if let timestamp = value as? Timestamp { return Variant(timestamp.dateValue().timeIntervalSince1970) }
        if let geoPoint = value as? GeoPoint {
            let gDict = VariantDictionary()
            gDict[Variant("latitude")] = Variant(geoPoint.latitude)
            gDict[Variant("longitude")] = Variant(geoPoint.longitude)
            return Variant(gDict)
        }
        if let docRef = value as? DocumentReference { return Variant(docRef.path) }
        if let dateVal = value as? Date { return Variant(dateVal.timeIntervalSince1970) }
        if let dataVal = value as? Data { return Variant(dataVal.toPackedByteArray()) }
        if let dictVal = value as? [String: Any] {
            let gDict = VariantDictionary()
            for (k, v) in dictVal {
                gDict[Variant(k)] = anyToVariant(v)
            }
            return Variant(gDict)
        }
        if let arrayVal = value as? [Any] {
            let gArray = VariantArray()
            for v in arrayVal {
                gArray.append(anyToVariant(v))
            }
            return Variant(gArray)
        }
        return Variant(String(describing: value))
    }
}