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
    
    private var activeListeners: [String: ListenerRegistration] = [:]

    @Callable
    func get_document(collection: String, document: String, callback: Callable) {
        let db = Firestore.firestore()
        db.collection(collection).document(document).getDocument { [weak self] (documentSnap, error) in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(document), Variant(VariantDictionary()), Variant(errorDesc))
            } else if let documentSnap = documentSnap, documentSnap.exists {
                let data = documentSnap.data() ?? [:]
                let gDict = VariantDictionary()
                for (key, value) in data {
                    gDict[Variant(key)] = FirebaseVariantConverter.anyToVariant(value)
                }
                let _ = callback.callDeferred(Variant(true), Variant(document), Variant(gDict), Variant(""))
            } else if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(document), Variant(VariantDictionary()), Variant(errorDesc))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(document), Variant(VariantDictionary()), Variant(""))
            }
        }
    }
    
    @Callable
    func list_documents(collection: String, callback: Callable) {
        let db = Firestore.firestore()
        db.collection(collection).getDocuments { [weak self] (querySnapshot, error) in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(""), Variant(VariantDictionary()), Variant(errorDesc))
            } else if let querySnapshot = querySnapshot {
                let results = VariantDictionary()
                for documentSnap in querySnapshot.documents {
                    let gDict = VariantDictionary()
                    for (key, value) in documentSnap.data() {
                        gDict[Variant(key)] = FirebaseVariantConverter.anyToVariant(value)
                    }
                    results[Variant(documentSnap.documentID)] = Variant(gDict)
                }
                let _ = callback.callDeferred(Variant(true), Variant(""), Variant(results), Variant(""))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(""), Variant(VariantDictionary()), Variant(""))
            }
        }
    }
    
    @Callable
    func add_document(collection: String, data: VariantDictionary, callback: Callable) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            let k = FirebaseVariantConverter.stringifyKey(key)
            let val = FirebaseVariantConverter.variantToAny(data[key])
            if let strVal = val as? String, strVal == "FIREBASE_DELETE_FIELD" {
                props[k] = FieldValue.delete()
            } else {
                props[k] = val
            }
        }
        let db = Firestore.firestore()
        var ref: DocumentReference? = nil
        ref = db.collection(collection).addDocument(data: props) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(""), Variant(VariantDictionary()), Variant(errorDesc))
            } else if let docId = ref?.documentID {
                let _ = callback.callDeferred(Variant(true), Variant(docId), Variant(VariantDictionary()), Variant(""))
            } else {
                let _ = callback.callDeferred(Variant(false), Variant(""), Variant(VariantDictionary()), Variant("Failed to get document ID"))
            }
        }
    }
    
    @Callable
    func set_document(collection: String, document: String, data: VariantDictionary, callback: Callable) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            let k = FirebaseVariantConverter.stringifyKey(key)
            let val = FirebaseVariantConverter.variantToAny(data[key])
            if let strVal = val as? String, strVal == "FIREBASE_DELETE_FIELD" {
                props[k] = FieldValue.delete()
            } else {
                props[k] = val
            }
        }
        let db = Firestore.firestore()
        db.collection(collection).document(document).setData(props, merge: true) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(document), Variant(VariantDictionary()), Variant(errorDesc))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(document), Variant(VariantDictionary()), Variant(""))
            }
        }
    }
    
    @Callable
    func update_document(collection: String, document: String, data: VariantDictionary, callback: Callable) {
        var props: [String: Any] = [:]
        for key in data.keys() {
            let k = FirebaseVariantConverter.stringifyKey(key)
            let val = FirebaseVariantConverter.variantToAny(data[key])
            if let strVal = val as? String, strVal == "FIREBASE_DELETE_FIELD" {
                props[k] = FieldValue.delete()
            } else {
                props[k] = val
            }
        }
        let db = Firestore.firestore()
        db.collection(collection).document(document).updateData(props) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(document), Variant(VariantDictionary()), Variant(errorDesc))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(document), Variant(VariantDictionary()), Variant(""))
            }
        }
    }
    
    @Callable
    func commit_document(collection: String, document: String, data: VariantDictionary, server_timestamp_fields: VariantArray, callback: Callable) {
        let db = Firestore.firestore()
        let batch = db.batch()
        let docRef = db.collection(collection).document(document)
        
        var props: [String: Any] = [:]
        for key in data.keys() {
            let k = FirebaseVariantConverter.stringifyKey(key)
            let val = FirebaseVariantConverter.variantToAny(data[key])
            if let strVal = val as? String, strVal == "FIREBASE_DELETE_FIELD" {
                props[k] = FieldValue.delete()
            } else {
                props[k] = val
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
                let _ = callback.callDeferred(Variant(false), Variant(document), Variant(VariantDictionary()), Variant(errorDesc))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(document), Variant(VariantDictionary()), Variant(""))
            }
        }
    }
    
    @Callable
    func delete_document(collection: String, document: String, callback: Callable) {
        let db = Firestore.firestore()
        db.collection(collection).document(document).delete() { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(document), Variant(VariantDictionary()), Variant(errorDesc))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(document), Variant(VariantDictionary()), Variant(""))
            }
        }
    }
    
    @Callable
    func listen_to_document(collection: String, document: String, callback: Callable) -> String {
        let listenerId = UUID().uuidString
        let db = Firestore.firestore()
        let listener = db.collection(collection).document(document).addSnapshotListener { [weak self] (documentSnapshot, error) in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant("error"), Variant(false), Variant(collection), Variant(document), Variant(VariantDictionary()), Variant(errorDesc))
                return
            }
            if let documentSnapshot = documentSnapshot, documentSnapshot.exists, let data = documentSnapshot.data() {
                let gDict = VariantDictionary()
                for (key, value) in data {
                    gDict[Variant(key)] = FirebaseVariantConverter.anyToVariant(value)
                }
                let _ = callback.callDeferred(Variant("snapshot"), Variant(true), Variant(collection), Variant(document), Variant(gDict), Variant(""))
            } else {
                let _ = callback.callDeferred(Variant("snapshot"), Variant(true), Variant(collection), Variant(document), Variant(VariantDictionary()), Variant(""))
            }
        }
        activeListeners[listenerId] = listener
        return listenerId
    }
    
    @Callable
    func listen_to_collection(collection: String, callback: Callable) -> String {
        let listenerId = UUID().uuidString
        let db = Firestore.firestore()
        let listener = db.collection(collection).addSnapshotListener { [weak self] (querySnapshot, error) in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant("error"), Variant(false), Variant(collection), Variant(""), Variant(VariantDictionary()), Variant(errorDesc))
                return
            }
            let results = VariantDictionary()
            if let querySnapshot = querySnapshot {
                for documentSnap in querySnapshot.documents {
                    let gDict = VariantDictionary()
                    for (key, value) in documentSnap.data() {
                        gDict[Variant(key)] = FirebaseVariantConverter.anyToVariant(value)
                    }
                    results[Variant(documentSnap.documentID)] = Variant(gDict)
                }
            }
            let _ = callback.callDeferred(Variant("snapshot"), Variant(true), Variant(collection), Variant(""), Variant(results), Variant(""))
        }
        activeListeners[listenerId] = listener
        return listenerId
    }
    
    @Callable
    func stop_listening(listenerId: String) {
        if let listener = activeListeners[listenerId] {
            listener.remove()
            activeListeners.removeValue(forKey: listenerId)
        }
    }
    
    @Callable
    func stop_all_listeners() {
        for (_, listener) in activeListeners {
            listener.remove()
        }
        activeListeners.removeAll()
    }
}