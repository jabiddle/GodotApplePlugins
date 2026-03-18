//
//  FirebaseFirestoreManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseFirestore

@Godot
class FirebaseFirestoreManager: RefCounted, @unchecked Sendable {
    
    @Signal("collection", "document", "data") var document_read: SignalWithArguments<String, String, VariantDictionary>
    @Signal("error") var document_error: SignalWithArguments<String>
    @Signal("collection", "document_id") var document_added: SignalWithArguments<String, String>
    @Signal("collection", "documents") var collection_read: SignalWithArguments<String, VariantArray>
    @Signal("collection", "document") var update_completed: SignalWithArguments<String, String>
    
    private func variantToAny(_ variant: Variant) -> Any {
        switch variant.gtype {
        case .`nil`: return NSNull()
        case .int: return Int(variant) ?? 0
        case .float: return Double(variant) ?? 0.0
        case .bool: return Bool(variant) ?? false
        case .string: return String(variant) ?? ""
        case .dictionary:
            let gDict = VariantDictionary(variant)
            var swiftDict: [String: Any] = [:]
            for key in gDict.keys() {
                if let val = gDict[key] {
                    swiftDict[String(key)] = variantToAny(val)
                }
            }
            return swiftDict
        case .array:
            let gArray = VariantArray(variant)
            var swiftArray: [Any] = []
            for i in 0..<Int(gArray.count) {
                swiftArray.append(variantToAny(gArray[Int64(i)]))
            }
            return swiftArray
        case .packedByteArray:
            return PackedByteArray(variant).asData() ?? Data()
        default: return variant.description
        }
    }
    
    private func anyToVariant(_ value: Any) -> Variant {
        if value is NSNull { return Variant() }
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
                gArray.append(value: anyToVariant(v))
            }
            return Variant(gArray)
        }
        return Variant(String(describing: value))
    }
    
    @Callable
    func get_document(collection: String, document: String) {
        let db = Firestore.firestore()
        db.collection(collection).document(document).getDocument { [weak self] (documentSnap, error) in
            guard let self = self else { return }
            if let documentSnap = documentSnap, documentSnap.exists, let data = documentSnap.data() {
                let gDict = VariantDictionary()
                for (key, value) in data {
                    gDict[Variant(key)] = self.anyToVariant(value)
                }
                DispatchQueue.main.async { self.document_read.emit(collection, document, gDict) }
            } else {
                DispatchQueue.main.async { self.document_error.emit(error?.localizedDescription ?? "Unknown Firestore error") }
            }
        }
    }
    
    @Callable
    func get_collection(collection: String) {
        let db = Firestore.firestore()
        db.collection(collection).getDocuments { [weak self] (querySnapshot, error) in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.document_error.emit(error.localizedDescription) }
            } else if let querySnapshot = querySnapshot {
                let results = VariantArray()
                for documentSnap in querySnapshot.documents {
                    let gDict = VariantDictionary()
                    gDict[Variant("id")] = Variant(documentSnap.documentID)
                    for (key, value) in documentSnap.data() {
                        gDict[Variant(key)] = self.anyToVariant(value)
                    }
                    results.append(value: Variant(gDict))
                }
                DispatchQueue.main.async { self.collection_read.emit(collection, results) }
            }
        }
    }
    
    @Callable
    func add_document(collection: String, data: VariantDictionary) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            let k = String(key)
            if let val = data[key] { props[k] = variantToAny(val) }
        }
        let db = Firestore.firestore()
        var ref: DocumentReference? = nil
        ref = db.collection(collection).addDocument(data: props) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.document_error.emit(error.localizedDescription) }
            } else if let docId = ref?.documentID {
                DispatchQueue.main.async { self.document_added.emit(collection, docId) }
            }
        }
    }
    
    @Callable
    func set_document(collection: String, document: String, data: VariantDictionary) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            let k = String(key)
            if let val = data[key] { props[k] = variantToAny(val) }
        }
        let db = Firestore.firestore()
        db.collection(collection).document(document).setData(props) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.document_error.emit(error.localizedDescription) }
            } else {
                DispatchQueue.main.async { self.update_completed.emit(collection, document) }
            }
        }
    }
    
    @Callable
    func update_document(collection: String, document: String, data: VariantDictionary) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            let k = String(key)
            if let val = data[key] { props[k] = variantToAny(val) }
        }
        let db = Firestore.firestore()
        db.collection(collection).document(document).updateData(props) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.document_error.emit(error.localizedDescription) }
            } else {
                DispatchQueue.main.async { self.update_completed.emit(collection, document) }
            }
        }
    }
}