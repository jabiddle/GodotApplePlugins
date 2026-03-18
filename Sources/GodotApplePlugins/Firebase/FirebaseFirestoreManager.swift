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
    @Signal("collection", "document_id") var document_added: SignalWithArguments<String, String>
    @Signal("collection", "documents") var collection_read: SignalWithArguments<String, VariantArray>
    @Signal("collection", "document") var update_completed: SignalWithArguments<String, String>
    @Signal("error") var document_error: SignalWithArguments<String>

    @Callable
    func get_document(collection: String, document: String) {
        let db = Firestore.firestore()
        db.collection(collection).document(document).getDocument { [weak self] (documentSnap, error) in
            guard let self = self else { return }
            if let documentSnap = documentSnap, documentSnap.exists, let data = documentSnap.data() {
                let gDict = VariantDictionary()
                for (key, value) in data {
                    gDict[Variant(key)] = FirebaseVariantConverter.anyToVariant(value)
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
                        gDict[Variant(key)] = FirebaseVariantConverter.anyToVariant(value)
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
            if let val = data[key] { props[k] = FirebaseVariantConverter.variantToAny(val) }
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
            if let val = data[key] { props[k] = FirebaseVariantConverter.variantToAny(val) }
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
            if let val = data[key] { props[k] = FirebaseVariantConverter.variantToAny(val) }
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