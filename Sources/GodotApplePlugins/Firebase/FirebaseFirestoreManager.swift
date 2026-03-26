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
    @Signal("collection", "documents") var collection_read: SignalWithArguments<String, VariantDictionary>
    @Signal("collection", "document") var document_written: SignalWithArguments<String, String>
    @Signal("collection", "document") var document_deleted: SignalWithArguments<String, String>
    @Signal("collection", "document", "error") var document_error: SignalWithArguments<String, String, String>
    @Signal("collection", "document", "timestamp") var document_committed: SignalWithArguments<String, String, Int>

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
                let errorDesc = error?.localizedDescription ?? "Unknown Firestore error"
                DispatchQueue.main.async { self.document_error.emit(collection, document, errorDesc) }
            }
        }
    }
    
    @Callable
    func list_documents(collection: String) {
        let db = Firestore.firestore()
        db.collection(collection).getDocuments { [weak self] (querySnapshot, error) in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async { self.document_error.emit(collection, "", errorDesc) }
            } else if let querySnapshot = querySnapshot {
                let results = VariantDictionary()
                for documentSnap in querySnapshot.documents {
                    let gDict = VariantDictionary()
                    for (key, value) in documentSnap.data() {
                        gDict[Variant(key)] = FirebaseVariantConverter.anyToVariant(value)
                    }
                    results[Variant(documentSnap.documentID)] = Variant(gDict)
                }
                DispatchQueue.main.async { self.collection_read.emit(collection, results) }
            }
        }
    }
    
    @Callable
    func add_document(collection: String, data: VariantDictionary) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            if let k = String(key) {
                props[k] = FirebaseVariantConverter.variantToAny(data[key])
            }
        }
        let db = Firestore.firestore()
        var ref: DocumentReference? = nil
        ref = db.collection(collection).addDocument(data: props) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async { self.document_error.emit(collection, "", errorDesc) }
            } else if let docId = ref?.documentID {
                DispatchQueue.main.async { self.document_added.emit(collection, docId) }
            }
        }
    }
    
    @Callable
    func set_document(collection: String, document: String, data: VariantDictionary) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            if let k = String(key) {
                props[k] = FirebaseVariantConverter.variantToAny(data[key])
            }
        }
        let db = Firestore.firestore()
        db.collection(collection).document(document).setData(props, merge: true) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async { self.document_error.emit(collection, document, errorDesc) }
            } else {
                DispatchQueue.main.async { self.document_written.emit(collection, document) }
            }
        }
    }
    
    @Callable
    func update_document(collection: String, document: String, data: VariantDictionary) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            if let k = String(key) {
                props[k] = FirebaseVariantConverter.variantToAny(data[key])
            }
        }
        let db = Firestore.firestore()
        db.collection(collection).document(document).updateData(props) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async { self.document_error.emit(collection, document, errorDesc) }
            } else {
                DispatchQueue.main.async { self.document_written.emit(collection, document) }
            }
        }
    }
    
    @Callable
    func commit_document(collection: String, document: String, data: VariantDictionary, server_timestamp_fields: VariantArray) {
        let db = Firestore.firestore()
        let batch = db.batch()
        let docRef = db.collection(collection).document(document)
        
        var props: [String: Any] = [:]
        for key in data.keys() {
            if let k = String(key) {
                props[k] = FirebaseVariantConverter.variantToAny(data[key])
            }
        }
        
        for i in 0..<Int(server_timestamp_fields.count) {
            if let fieldName = String(server_timestamp_fields[i]) {
                props[fieldName] = FieldValue.serverTimestamp()
            }
        }
        
        batch.setData(props, forDocument: docRef, merge: true)
        batch.commit { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async { self.document_error.emit(collection, document, errorDesc) }
            } else {
                let currentUnix = Int(Date().timeIntervalSince1970)
                DispatchQueue.main.async { self.document_committed.emit(collection, document, currentUnix) }
            }
        }
    }
    
    @Callable
    func delete_document(collection: String, document: String) {
        let db = Firestore.firestore()
        db.collection(collection).document(document).delete() { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async { self.document_error.emit(collection, document, errorDesc) }
            } else {
                DispatchQueue.main.async { self.document_deleted.emit(collection, document) }
            }
        }
    }
}