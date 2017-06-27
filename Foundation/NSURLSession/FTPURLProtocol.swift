//
//  FTPURLProtocol.swift
//  Foundation
//
//  Created by sai hema on 6/27/17.
//  Copyright © 2017 Apple. All rights reserved.
//

import CoreFoundation
import Dispatch

internal class _FTPURLProtocol: URLProtocol {
    
    fileprivate var easyHandle: _EasyHandle!
    fileprivate var totalDownloaded = 0
    fileprivate var tempFileURL: URL
    public required init(task: URLSessionTask, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        self.internalState = _InternalState.initial
        let fileName = NSTemporaryDirectory() + NSUUID().uuidString + ".tmp"
        _ = FileManager.default.createFile(atPath: fileName, contents: nil)
        self.tempFileURL = URL(fileURLWithPath: fileName)
        super.init(request: task.originalRequest!, cachedResponse: cachedResponse, client: client)
        self.task = task
        self.easyHandle = _EasyHandle(delegate: self)
    }
    
    public required init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        self.internalState = _InternalState.initial
        let fileName = NSTemporaryDirectory() + NSUUID().uuidString + ".tmp"
        _ = FileManager.default.createFile(atPath: fileName, contents: nil)
        self.tempFileURL = URL(fileURLWithPath: fileName)
        super.init(request: request, cachedResponse: cachedResponse, client: client)
        self.easyHandle = _EasyHandle(delegate: self)
    }
    
    override class func canInit(with request: URLRequest) -> Bool {
        guard request.url?.scheme == "ftp" || request.url?.scheme == "ftps" || request.url?.scheme == "sftp" else { return false }
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        resume()
    }
    
    override func stopLoading() {
        if task?.state == .suspended {
            suspend()
        } else {
            self.internalState = .transferFailed
            //guard (self.task?.error) != nil else { fatalError() }
            //completeTask(withError: error)
        }
    }
    fileprivate var internalState: _InternalState {
        // We manage adding / removing the easy handle and pausing / unpausing
        // here at a centralized place to make sure the internal state always
        // matches up with the state of the easy handle being added and paused.
        willSet {
            if !internalState.isEasyHandlePaused && newValue.isEasyHandlePaused {
                fatalError("Need to solve pausing receive.")
            }
            if internalState.isEasyHandleAddedToMultiHandle && !newValue.isEasyHandleAddedToMultiHandle {
                task?.session.remove(handle: easyHandle)
            }
        }
        didSet {
            if !oldValue.isEasyHandleAddedToMultiHandle && internalState.isEasyHandleAddedToMultiHandle {
                task?.session.add(handle: easyHandle)
            }
            if oldValue.isEasyHandlePaused && !internalState.isEasyHandlePaused {
                fatalError("Need to solve pausing receive.")
            }
        }
    }


}

extension _FTPURLProtocol: _EasyHandleDelegate {
    func didReceive(data: Data) -> _EasyHandle._Action {
        NSUnimplemented()
    }
    
    func didReceive(headerData data: Data) -> _EasyHandle._Action {
         NSUnimplemented()
    }
    
    func fill(writeBuffer buffer: UnsafeMutableBufferPointer<Int8>) -> _EasyHandle._WriteBufferResult {
         NSUnimplemented()
    }
    
    func transferCompleted(withErrorCode errorCode: Int?) {
         NSUnimplemented()
    }
    
    func seekInputStream(to position: UInt64) throws {
         NSUnimplemented()
    }
    
    func updateProgressMeter(with propgress: _EasyHandle._Progress) {
         NSUnimplemented()
    }

}

extension _FTPURLProtocol {
    /// The is independent of the public `state: URLSessionTask.State`.
    enum _InternalState {
        /// Task has been created, but nothing has been done, yet
        case initial
        /// The easy handle has been fully configured. But it is not added to
        /// the multi handle.
        case transferReady(_FTPTransferState)
        /// The easy handle is currently added to the multi handle
        case transferInProgress(_FTPTransferState)
        /// The transfer completed.
        ///
        /// The easy handle has been removed from the multi handle. This does
        /// not (necessarily mean the task completed. A task that gets
        /// redirected will do multiple transfers.
        case transferCompleted(response: URLResponse, bodyDataDrain: _DataDrain)
        /// The transfer failed.
        ///
        /// Same as `.transferCompleted`, but without response / body data
        case transferFailed
        /// Waiting for the completion handler of the HTTP redirect callback.
        ///
        /// When we tell the delegate that we're about to perform an HTTP
        /// redirect, we need to wait for the delegate to let us know what
        /// action to take.
        case waitingForRedirectCompletionHandler(response: URLResponse, bodyDataDrain: _DataDrain)
        /// Waiting for the completion handler of the 'did receive response' callback.
        ///
        /// When we tell the delegate that we received a response (i.e. when
        /// we received a complete header), we need to wait for the delegate to
        /// let us know what action to take. In this state the easy handle is
        /// paused in order to suspend delegate callbacks.
        case waitingForResponseCompletionHandler(_FTPTransferState)
        /// The task is completed
        ///
        /// Contrast this with `.transferCompleted`.
        case taskCompleted
    }
}

extension _FTPURLProtocol._InternalState {
    var isEasyHandleAddedToMultiHandle: Bool {
        switch self {
        case .initial:                             return false
        case .transferReady:                       return false
        case .transferInProgress:                  return true
        case .transferCompleted:                   return false
        case .transferFailed:                      return false
        case .waitingForRedirectCompletionHandler: return false
        case .waitingForResponseCompletionHandler: return true
        case .taskCompleted:                       return false
        }
    }
    var isEasyHandlePaused: Bool {
        switch self {
        case .initial:                             return false
        case .transferReady:                       return false
        case .transferInProgress:                  return false
        case .transferCompleted:                   return false
        case .transferFailed:                      return false
        case .waitingForRedirectCompletionHandler: return false
        case .waitingForResponseCompletionHandler: return true
        case .taskCompleted:                       return false
        }
    }
}
fileprivate let enableLibcurlDebugOutput: Bool = {
    return (ProcessInfo.processInfo.environment["URLSessionDebugLibcurl"] != nil)
}()
fileprivate let enableDebugOutput: Bool = {
    return (ProcessInfo.processInfo.environment["URLSessionDebug"] != nil)
}()

fileprivate extension _FTPURLProtocol {
    
    /// Set options on the easy handle to match the given request.
    ///
    /// This performs a series of `curl_easy_setopt()` calls.
    fileprivate func configureEasyHandle(for request: URLRequest) {
        easyHandle.set(verboseModeOn: enableLibcurlDebugOutput)
        easyHandle.set(debugOutputOn: enableLibcurlDebugOutput, task: task!)
        easyHandle.set(passHeadersToDataStream: false)
        easyHandle.set(progressMeterOff: true)
        easyHandle.set(skipAllSignalHandling: true)
        
        // Error Options:
        easyHandle.set(errorBuffer: nil)
        easyHandle.set(failOnHTTPErrorCode: false)
        // Network Options:
        guard let url = request.url else { fatalError("No URL in request.") }
        easyHandle.set(url: url)
        easyHandle.set(preferredReceiveBufferSize: Int.max)
        easyHandle.set(followLocation: false)
        let timeoutHandler = DispatchWorkItem { [weak self] in
            guard let _ = self?.task else { fatalError("Timeout on a task that doesn't exist") } //this guard must always pass
            self?.internalState = .transferFailed
            let urlError = URLError(_nsError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil))
           // self?.completeTask(withError: urlError)
            self?.client?.urlProtocol(self!, didFailWithError: urlError)
        }
        guard let task = self.task else { fatalError() }
        easyHandle.timeoutTimer = _TimeoutSource(queue: task.workQueue, milliseconds: Int(request.timeoutInterval) * 1000, handler: timeoutHandler)
        
        easyHandle.set(automaticBodyDecompression: true)

        
        
     /*   C settings
         
         if(curl) {
            /*
             * You better replace the URL with one that works!
             */
            curl_easy_setopt(curl, CURLOPT_URL,
                             "ftp://ftp.example.com/curl/curl-7.9.2.tar.gz");
            /* Define our callback to get called when there's data to be written */
            curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, my_fwrite);
            /* Set a pointer to our struct to pass to the callback */
            curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ftpfile);
            
            /* Switch on full protocol/debug output */
            curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
            
            res = curl_easy_perform(curl);
            
            /* always cleanup */
            curl_easy_cleanup(curl);
            
            if(CURLE_OK != res) {
                /* we failed */ 
                fprintf(stderr, "curl told us %d\n", res);
            }
        }*/
        
    }
}
internal extension _FTPURLProtocol {
    /// Start a new transfer
    func startNewTransfer(with request: URLRequest) {
        guard let t = task else { fatalError() }
        t.currentRequest = request
        guard let url = request.url else { fatalError("No URL in request.") }
        
      //  self.internalState = .transferReady(_FTPTransferState(url: urlbodyDataDrainaDrain: t.workQueue))
        configureEasyHandle(for: request)
        if (t.suspendCount) < 1 {
            resume()
        }
    }
    
    func resume() {
        if case .initial = self.internalState {
            guard let r = task?.originalRequest else { fatalError("Task has no original request.") }
            startNewTransfer(with: r)
        }
        
        if case .transferReady(let transferState) = self.internalState {
            self.internalState = .transferInProgress(transferState)
        }
    }
    
    func suspend() {
        if case .transferInProgress(let transferState) =  self.internalState {
            self.internalState = .transferReady(transferState)
        }
    }
}

internal extension _FTPURLProtocol {
    /// The data drain.
    ///
    /// This depends on what the delegate / completion handler need.
    fileprivate func createTransferBodyDataDrain() -> _DataDrain {
        guard let task = task else { fatalError() }
        let s = task.session as! URLSession
        switch s.behaviour(for: task) {
        case .noDelegate:
            return .ignore
        case .taskDelegate:
            // Data will be forwarded to the delegate as we receive it, we don't
            // need to do anything about it.
            return .ignore
        case .dataCompletionHandler:
            // Data needs to be concatenated in-memory such that we can pass it
            // to the completion handler upon completion.
            return .inMemory(nil)
        case .downloadCompletionHandler:
            // Data needs to be written to a file (i.e. a download task).
            let fileHandle = try! FileHandle(forWritingTo: self.tempFileURL)
            return .toFile(self.tempFileURL, fileHandle)
        }
    }
}

