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
            guard (self.task?.error) != nil else { fatalError() }
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
        guard case .transferInProgress(let ts) = internalState else { fatalError("Received body data, but no transfer in progress.") }
        guard ts.isHeaderComplete else { fatalError("Received body data, but the header is not complete, yet.") }
        notifyDelegate(aboutReceivedData: data)
        internalState = .transferInProgress(ts.byAppending(bodyData: data))
        return .proceed
    }
    fileprivate func notifyDelegate(aboutReceivedData data: Data) {
        guard let t = self.task else { fatalError("Cannot notify") }
        if case .taskDelegate(let delegate) = t.session.behaviour(for: self.task!),
            let dataDelegate = delegate as? URLSessionDataDelegate,
            let task = self.task as? URLSessionDataTask {
            // Forward to the delegate:
            guard let s = self.task?.session as? URLSession else { fatalError() }
            s.delegateQueue.addOperation {
                dataDelegate.urlSession(s, dataTask: task, didReceive: data)
            }
        } else if case .taskDelegate(let delegate) = t.session.behaviour(for: self.task!),
            let downloadDelegate = delegate as? URLSessionDownloadDelegate,
            let task = self.task as? URLSessionDownloadTask {
            guard let s = self.task?.session as? URLSession else { fatalError() }
            let fileHandle = try! FileHandle(forWritingTo: self.tempFileURL)
            _ = fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            self.totalDownloaded += data.count
            
            s.delegateQueue.addOperation {
                downloadDelegate.urlSession(s, downloadTask: task, didWriteData: Int64(data.count), totalBytesWritten: Int64(self.totalDownloaded),
                                            totalBytesExpectedToWrite: Int64(self.easyHandle.fileLength))
            }
            if Int(self.easyHandle.fileLength) == self.totalDownloaded {
                fileHandle.closeFile()
                s.delegateQueue.addOperation {
                    downloadDelegate.urlSession(s, downloadTask: task, didFinishDownloadingTo: self.tempFileURL)
                }
            }
        }
    }
    
    func didReceive(headerData data: Data) -> _EasyHandle._Action {
        
        guard case .transferInProgress(let ts) = internalState else { fatalError("Received body data, but no transfer in progress.") }
        do {
            let newTS = try ts.byAppending(headerLine: data)
            internalState = .transferInProgress(newTS)
            let didCompleteHeader = !ts.isHeaderComplete && newTS.isHeaderComplete
            if didCompleteHeader {
                // The header is now complete, but wasn't before.
               didReceiveResponse()
            }
            return .proceed
        } catch {
            return .abort
        }
    }
    
    func fill(writeBuffer buffer: UnsafeMutableBufferPointer<Int8>) -> _EasyHandle._WriteBufferResult {
        print(" IN FILL ")
        return .bytes(0)
    }
    
    func transferCompleted(withErrorCode errorCode: Int?) {
        print("Transfer Completed")
        // At this point the transfer is complete and we can decide what to do.
        // If everything went well, we will simply forward the resulting data
        // to the delegate. But in case of redirects etc. we might send another
        // request.
        guard case .transferInProgress(let ts) = internalState else { fatalError("Transfer completed, but it wasn't in progress.") }
        guard let request = task?.currentRequest else { fatalError("Transfer completed, but there's no current request.") }
        guard errorCode == nil else {
            internalState = .transferFailed
            failWith(errorCode: errorCode!, request: request)
            return
        }
         print(" TASK RESPONSE \(task?.response)")
        if let response = task?.response as? URLResponse {
            var transferState = ts
            transferState.response = response
        }
        
        guard let response = ts.response else { fatalError("Transfer completed, but there's no response.") }
        internalState = .transferCompleted(response: response, bodyDataDrain: ts.bodyDataDrain)
        let action = completionAction(forCompletedRequest: request, response: response)
        
        switch action {
        case .completeTask:
            completeTask()
        case .failWithError(let errorCode):
            internalState = .transferFailed
            failWith(errorCode: errorCode, request: request)
        }
    }
    
    func seekInputStream(to position: UInt64) throws {
         NSUnimplemented()
    }
    
    func updateProgressMeter(with propgress: _EasyHandle._Progress) {
         //NSUnimplemented()
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
      //  easyHandle.set(passHeadersToDataStream: false)
        //easyHandle.set(progressMeterOff: true)
        easyHandle.set(skipAllSignalHandling: true)
        
        // Error Options:
       //easyHandle.set(errorBuffer: nil)
        // easyHandle.set(failOnHTTPErrorCode: false)
        // Network Options:
        guard let url = request.url else { fatalError("No URL in request.") }
        easyHandle.set(url: url)
        easyHandle.set(preferredReceiveBufferSize: Int.max)
       
        let timeoutHandler = DispatchWorkItem { [weak self] in
            guard let _ = self?.task else { fatalError("Timeout on a task that doesn't exist") } //this guard must always pass
            self?.internalState = .transferFailed
            let urlError = URLError(_nsError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil))
            self?.completeTask(withError: urlError)
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
        
        self.internalState = .transferReady(createTransferState(url: url, workQueue: t.workQueue))
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
extension _FTPURLProtocol {
    
    /// Creates a new transfer state with the given behaviour:
    func createTransferState(url: URL, workQueue: DispatchQueue) -> _FTPTransferState {
        let drain = createTransferBodyDataDrain()
        guard let t = task else { fatalError("Cannot create transfer state") }
        switch t.body {
        case .none:
            return _FTPTransferState(url: url, bodyDataDrain: drain)
        case .data(let data):
            let source = _BodyDataSource(data: data)
            return _FTPTransferState(url: url, bodyDataDrain: drain,bodySource: source)
        case .file(let fileURL):
            let source = _BodyFileSource(fileURL: fileURL, workQueue: workQueue, dataAvailableHandler: { [weak self] in
                // Unpause the easy handle
                self?.easyHandle.unpauseSend()
            })
            return _FTPTransferState(url: url, bodyDataDrain: drain,bodySource: source)
        case .stream:
            NSUnimplemented()
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
/// Response processing
internal extension _FTPURLProtocol {
    /// Whenever we receive a response (i.e. a complete header) from libcurl,
    /// this method gets called.
    func didReceiveResponse() {
        guard let _ = task as? URLSessionDataTask else { return }
        guard case .transferInProgress(let ts) = self.internalState else { fatalError("Transfer not in progress.") }
        guard let response = ts.response else { fatalError("Header complete, but not URL response.") }
        guard let session = task?.session as? URLSession else { fatalError() }
        switch session.behaviour(for: self.task!) {
        case .noDelegate:
            break
        case .taskDelegate(_):
            //TODO: There's a problem with libcurl / with how we're using it.
            // We're currently unable to pause the transfer / the easy handle:
            // https://curl.haxx.se/mail/lib-2016-03/0222.html
            //
            // For now, we'll notify the delegate, but won't pause the transfer,
            // and we'll disregard the completion handler:
            
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            
        case .dataCompletionHandler:
            break
        case .downloadCompletionHandler:
            break
        }
    }
    func failWith(errorCode: Int, request: URLRequest) {
    //TODO: Error handling
    let userInfo: [String : Any]? = request.url.map {
    [
    NSURLErrorFailingURLErrorKey: $0,
    NSURLErrorFailingURLStringErrorKey: $0.absoluteString,
    ]
    }
    let error = URLError(_nsError: NSError(domain: NSURLErrorDomain, code: errorCode, userInfo: userInfo))
    completeTask(withError: error)
    self.client?.urlProtocol(self, didFailWithError: error)
    }
    /// Give the delegate a chance to tell us how to proceed once we have a
    /// response / complete header.
    ///
    /// This will pause the transfer.
    func askDelegateHowToProceedAfterCompleteResponse(_ response: HTTPURLResponse, delegate: URLSessionDataDelegate) {
        // Ask the delegate how to proceed.
        
        // This will pause the easy handle. We need to wait for the
        // delegate before processing any more data.
        guard case .transferInProgress(let ts) = self.internalState else { fatalError("Transfer not in progress.") }
        self.internalState = .waitingForResponseCompletionHandler(ts)
        
        let dt = task as! URLSessionDataTask
        
        // We need this ugly cast in order to be able to support `URLSessionTask.init()`
        guard let s = task?.session as? URLSession else { fatalError() }
        s.delegateQueue.addOperation {
            delegate.urlSession(s, dataTask: dt, didReceive: response, completionHandler: { [weak self] disposition in
                guard let task = self else { return }
                self?.task?.workQueue.async {
                    task.didCompleteResponseCallback(disposition: disposition)
                }
            })
        }
    }
    /// This gets called (indirectly) when the data task delegates lets us know
    /// how we should proceed after receiving a response (i.e. complete header).
    func didCompleteResponseCallback(disposition: URLSession.ResponseDisposition) {
        guard case .waitingForResponseCompletionHandler(let ts) = self.internalState else { fatalError("Received response disposition, but we're not waiting for it.") }
        switch disposition {
        case .cancel:
            let error = URLError(_nsError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            self.completeTask(withError: error)
            self.client?.urlProtocol(self, didFailWithError: error)
        case .allow:
            // Continue the transfer. This will unpause the easy handle.
            self.internalState = .transferInProgress(ts)
        case .becomeDownload:
            /* Turn this request into a download */
            NSUnimplemented()
        case .becomeStream:
            /* Turn this task into a stream task */
            NSUnimplemented()
        }
    }
    
    /// Action to be taken after a transfer completes
    enum _CompletionAction {
        case completeTask
        case failWithError(Int)
    }
    func completeTask(withError error: Error) {
        task?.error = error
        
        guard case .transferFailed = self.internalState else {
            fatalError("Trying to complete the task, but its transfer isn't complete / failed.")
        }
        
        //We don't want a timeout to be triggered after this. The timeout timer needs to be cancelled.
        easyHandle.timeoutTimer = nil
        self.internalState = .taskCompleted
    }
    
    /// What action to take
    func completionAction(forCompletedRequest request: URLRequest, response: URLResponse) -> _CompletionAction {
        return .completeTask
    }
    func completeTask() {
        guard case .transferCompleted(response: let response, bodyDataDrain: let bodyDataDrain) = self.internalState else {
            fatalError("Trying to complete the task, but its transfer isn't complete.")
        }
        print(" completeTask \(response)")
        task?.response = response
        
        //We don't want a timeout to be triggered after this. The timeout timer needs to be cancelled.
        easyHandle.timeoutTimer = nil
        
        //because we deregister the task with the session on internalState being set to taskCompleted
        //we need to do the latter after the delegate/handler was notified/invoked
        if case .inMemory(let bodyData) = bodyDataDrain {
            var data = Data()
            if let body = bodyData {
                data = Data(bytes: body.bytes, count: body.length)
            }
            self.client?.urlProtocol(self, didLoad: data)
            self.internalState = .taskCompleted
        }
        
        if case .toFile(let url, let fileHandle?) = bodyDataDrain {
            self.properties[.temporaryFileURL] = url
            fileHandle.closeFile()
        }
        self.client?.urlProtocolDidFinishLoading(self)
        self.internalState = .taskCompleted
    }

}


