//
//  FirebaseStorageManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseStorage

@Godot
class FirebaseStorageManager: RefCounted, @unchecked Sendable {
    
    @Callable
    func upload_file(local_path: String, storage_path: String, callback: Callable) {
        let storage = Storage.storage()
        let storageRef = storage.reference().child(storage_path)
        let localFile = URL(fileURLWithPath: local_path)
        
        storageRef.putFile(from: localFile, metadata: nil) { [weak self] metadata, error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(storage_path), Variant(""), Variant(errorDesc))
                return
            }
            storageRef.downloadURL { [weak self] (url, error) in
                guard let self = self else { return }
                if let error = error {
                    let errorDesc = error.localizedDescription
                    let _ = callback.callDeferred(Variant(false), Variant(storage_path), Variant(""), Variant(errorDesc))
                    return
                }
                if let downloadURL = url {
                    let urlString = downloadURL.absoluteString
                    let _ = callback.callDeferred(Variant(true), Variant(storage_path), Variant(urlString), Variant(""))
                } else {
                    let _ = callback.callDeferred(Variant(false), Variant(storage_path), Variant(""), Variant("Unknown error: missing url"))
                }
            }
        }
    }
    
    @Callable
    func download_file(storage_path: String, local_path: String, callback: Callable) {
        let storage = Storage.storage()
        let storageRef = storage.reference().child(storage_path)
        let localFile = URL(fileURLWithPath: local_path)
        
        storageRef.write(toFile: localFile) { [weak self] url, error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(storage_path), Variant(""), Variant(errorDesc))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(storage_path), Variant(local_path), Variant(""))
            }
        }
    }
    
    @Callable
    func delete_file(storage_path: String, callback: Callable) {
        let storage = Storage.storage()
        let storageRef = storage.reference().child(storage_path)
        
        storageRef.delete { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant(storage_path), Variant(""), Variant(errorDesc))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(storage_path), Variant(""), Variant(""))
            }
        }
    }
}