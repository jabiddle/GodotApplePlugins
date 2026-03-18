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
    
    @Signal("path", "download_url") var upload_completed: SignalWithArguments<String, String>
    @Signal("path", "error") var upload_failed: SignalWithArguments<String, String>
    @Signal("storage_path", "local_path") var download_completed: SignalWithArguments<String, String>
    @Signal("storage_path", "error") var download_failed: SignalWithArguments<String, String>
    @Signal("storage_path") var delete_completed: SignalWithArguments<String>
    @Signal("storage_path", "error") var delete_failed: SignalWithArguments<String, String>
    
    @Callable
    func upload_file(local_path: String, storage_path: String) {
        let storage = Storage.storage()
        let storageRef = storage.reference().child(storage_path)
        let localFile = URL(fileURLWithPath: local_path)
        
        storageRef.putFile(from: localFile, metadata: nil) { [weak self] metadata, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.upload_failed.emit(storage_path, error.localizedDescription) }
                return
            }
            storageRef.downloadURL { [weak self] (url, error) in
                guard let self = self else { return }
                if let downloadURL = url {
                    DispatchQueue.main.async { self.upload_completed.emit(storage_path, downloadURL.absoluteString) }
                }
            }
        }
    }
    
    @Callable
    func download_file(storage_path: String, local_path: String) {
        let storage = Storage.storage()
        let storageRef = storage.reference().child(storage_path)
        let localFile = URL(fileURLWithPath: local_path)
        
        storageRef.write(toFile: localFile) { [weak self] url, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.download_failed.emit(storage_path, error.localizedDescription) }
            } else {
                DispatchQueue.main.async { self.download_completed.emit(storage_path, local_path) }
            }
        }
    }
    
    @Callable
    func delete_file(storage_path: String) {
        let storage = Storage.storage()
        let storageRef = storage.reference().child(storage_path)
        
        storageRef.delete { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.delete_failed.emit(storage_path, error.localizedDescription) }
            } else {
                DispatchQueue.main.async { self.delete_completed.emit(storage_path) }
            }
        }
    }
}